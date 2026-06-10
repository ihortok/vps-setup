#!/bin/bash
################################################################################
# File Permissions Security Audit Script
# Run this on your VPS to verify secure file permissions
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "========================================================================"
echo "File Permissions Security Audit"
echo "========================================================================"
echo ""

# Function to check permissions and ownership
check_path() {
    local path="$1"
    local expected_perms="$2"
    local description="$3"

    if [ ! -e "$path" ]; then
        echo -e "${YELLOW}⚠ SKIP${NC} $description"
        echo "   Path: $path"
        echo "   Status: Does not exist"
        echo ""
        return
    fi

    local actual_perms=$(stat -c "%a" "$path" 2>/dev/null)
    local owner=$(stat -c "%U:%G" "$path" 2>/dev/null)

    echo -e "${BLUE}▶ $description${NC}"
    echo "   Path: $path"
    echo "   Owner: $owner"
    echo "   Permissions: $actual_perms"

    if [ -n "$expected_perms" ]; then
        if [ "$actual_perms" = "$expected_perms" ]; then
            echo -e "   Status: ${GREEN}✓ Correct ($expected_perms)${NC}"
        else
            echo -e "   Status: ${YELLOW}⚠ Expected: $expected_perms, Got: $actual_perms${NC}"
        fi
    fi

    # Show symbolic permissions for clarity
    local symbolic=$(ls -ld "$path" | awk '{print $1}')
    echo "   Symbolic: $symbolic"
    echo ""
}

echo "1. HOME DIRECTORY"
echo "----------------------------------------"
check_path "/home/deploy" "710" "Deploy user home directory"

echo "2. SSH CONFIGURATION"
echo "----------------------------------------"
check_path "/home/deploy/.ssh" "700" "SSH directory"
check_path "/home/deploy/.ssh/authorized_keys" "600" "SSH authorized keys"

if [ -f /home/deploy/.ssh/id_rsa ]; then
    check_path "/home/deploy/.ssh/id_rsa" "600" "SSH private key"
fi

if [ -f /home/deploy/.ssh/id_ed25519 ]; then
    check_path "/home/deploy/.ssh/id_ed25519" "600" "SSH private key (ed25519)"
fi

echo "3. SHELL CONFIGURATION FILES"
echo "----------------------------------------"
check_path "/home/deploy/.bashrc" "600" "Bash configuration"
check_path "/home/deploy/.profile" "600" "Profile configuration"
check_path "/home/deploy/.bash_history" "" "Bash history"

echo "4. RBENV CONFIGURATION"
echo "----------------------------------------"
check_path "/home/deploy/.rbenv" "" "rbenv directory"
if [ -d /home/deploy/.rbenv ]; then
    rbenv_perms=$(stat -c "%a" /home/deploy/.rbenv)
    echo "   rbenv directory permissions: $rbenv_perms"
    echo "   (Should allow user read/write/execute, group/others may vary)"
    echo ""
fi

echo "5. APPLICATION DIRECTORIES"
echo "----------------------------------------"
if [ -d /home/deploy/apps ]; then
    check_path "/home/deploy/apps" "" "Apps root directory"

    # Check each application
    for app_dir in /home/deploy/apps/*/; do
        if [ -d "$app_dir" ]; then
            app_name=$(basename "$app_dir")
            echo -e "${BLUE}Application: $app_name${NC}"
            check_path "$app_dir" "" "  App root"

            if [ -d "${app_dir}current/public" ]; then
                check_path "${app_dir}current/public" "" "  Public directory"
                echo "     ${YELLOW}Note: Should be group-readable (g+rX) for Nginx${NC}"
                echo ""
            fi

            if [ -d "${app_dir}shared" ]; then
                check_path "${app_dir}shared" "" "  Shared directory"
            fi

            if [ -d "${app_dir}shared/log" ]; then
                check_path "${app_dir}shared/log" "" "  Log directory"
                echo "     ${YELLOW}Note: Should be group-writable (g+rwX) for Passenger${NC}"
                echo ""
            fi

            if [ -d "${app_dir}shared/tmp" ]; then
                check_path "${app_dir}shared/tmp" "" "  Tmp directory"
                echo "     ${YELLOW}Note: Should be group-writable (g+rwX) for Passenger${NC}"
                echo ""
            fi

            if [ -f "${app_dir}shared/config/credentials/production.key" ]; then
                check_path "${app_dir}shared/config/credentials/production.key" "600" "  Production credentials key"
            fi

            if [ -f "${app_dir}shared/config/master.key" ]; then
                check_path "${app_dir}shared/config/master.key" "600" "  Master key"
            fi
        fi
    done
else
    echo -e "${YELLOW}No applications directory found at /home/deploy/apps${NC}"
    echo ""
fi

echo "6. SYSTEM CONFIGURATION FILES (requires sudo)"
echo "----------------------------------------"
echo -e "${BLUE}▶ PostgreSQL Configuration${NC}"
if sudo test -f /etc/postgresql/*/main/postgresql.conf; then
    pg_conf=$(sudo find /etc/postgresql -name postgresql.conf -type f | head -1)
    sudo stat -c "   %n - %a (%U:%G)" "$pg_conf"
fi
if sudo test -f /etc/postgresql/*/main/pg_hba.conf; then
    pg_hba=$(sudo find /etc/postgresql -name pg_hba.conf -type f | head -1)
    sudo stat -c "   %n - %a (%U:%G)" "$pg_hba"
fi
echo ""

echo -e "${BLUE}▶ Redis Configuration${NC}"
if sudo test -f /etc/redis/redis.conf; then
    redis_perms=$(sudo stat -c "%a" /etc/redis/redis.conf)
    redis_owner=$(sudo stat -c "%U:%G" /etc/redis/redis.conf)
    echo "   /etc/redis/redis.conf - $redis_perms ($redis_owner)"
    if [ "$redis_perms" = "640" ] && [ "$redis_owner" = "root:redis" ]; then
        echo -e "   Status: ${GREEN}✓ Correct (640 root:redis — password not world-readable)${NC}"
    else
        echo -e "   Status: ${YELLOW}⚠ Expected: 640 root:redis, Got: $redis_perms $redis_owner${NC}"
        echo -e "   ${YELLOW}Fix: sudo chmod 640 /etc/redis/redis.conf && sudo chown root:redis /etc/redis/redis.conf${NC}"
    fi
fi
echo ""

echo -e "${BLUE}▶ Nginx Configuration${NC}"
sudo stat -c "   %n - %a (%U:%G)" /etc/nginx/nginx.conf 2>/dev/null || echo "   Not found"
if [ -d /etc/nginx/sites-available ]; then
    echo "   Sites available:"
    for site in /etc/nginx/sites-available/*; do
        if [ -f "$site" ]; then
            sudo stat -c "     $(basename $site) - %a (%U:%G)" "$site"
        fi
    done
fi
echo ""

echo "7. GROUP MEMBERSHIPS"
echo "----------------------------------------"
echo -e "${BLUE}Deploy user groups:${NC}"
groups deploy
echo ""

echo -e "${BLUE}www-data user groups:${NC}"
groups www-data
echo ""

if groups www-data | grep -q deploy; then
    echo -e "${GREEN}✓ www-data is in deploy group (required for Nginx/Passenger access)${NC}"
else
    echo -e "${RED}✗ www-data is NOT in deploy group (Nginx may not access app files)${NC}"
fi
echo ""

echo "8. WORLD-WRITABLE FILES CHECK (Security Risk)"
echo "----------------------------------------"
echo "Searching for world-writable files in /home/deploy..."
world_writable=$(find /home/deploy -type f -perm -002 2>/dev/null | head -10)
if [ -z "$world_writable" ]; then
    echo -e "${GREEN}✓ No world-writable files found${NC}"
else
    echo -e "${RED}✗ Found world-writable files (SECURITY RISK):${NC}"
    echo "$world_writable"
fi
echo ""

echo "9. SETUID/SETGID FILES CHECK"
echo "----------------------------------------"
echo "Searching for setuid/setgid files in /home/deploy..."
setuid_files=$(find /home/deploy -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null)
if [ -z "$setuid_files" ]; then
    echo -e "${GREEN}✓ No setuid/setgid files found (normal for app directories)${NC}"
else
    echo -e "${YELLOW}⚠ Found setuid/setgid files:${NC}"
    echo "$setuid_files"
fi
echo ""

echo "10. FILES WITH PASSWORDS/SECRETS (Pattern Search)"
echo "----------------------------------------"
echo "Searching for potential secrets in filenames..."
secret_files=$(find /home/deploy/apps -type f \( -name "*secret*" -o -name "*password*" -o -name "*.key" -o -name ".env*" \) 2>/dev/null | head -20)
if [ -n "$secret_files" ]; then
    echo -e "${YELLOW}Found files that may contain secrets (check their permissions):${NC}"
    while IFS= read -r file; do
        perms=$(stat -c "%a" "$file" 2>/dev/null)
        owner=$(stat -c "%U:%G" "$file" 2>/dev/null)
        echo "   $file"
        echo "      Permissions: $perms, Owner: $owner"
        if [ "$perms" -le 600 ]; then
            echo -e "      ${GREEN}✓ Secure (owner-only access)${NC}"
        else
            echo -e "      ${YELLOW}⚠ Review permissions (currently group/world accessible)${NC}"
        fi
    done <<< "$secret_files"
else
    echo "No obvious secret files found"
fi
echo ""

echo "========================================================================"
echo "SUMMARY & RECOMMENDATIONS"
echo "========================================================================"
echo ""
echo "Expected Permissions Summary:"
echo "  - /home/deploy:                           710 (drwx--x---)"
echo "  - /home/deploy/.ssh:                      700 (drwx------)"
echo "  - /home/deploy/.ssh/authorized_keys:      600 (-rw-------)"
echo "  - /home/deploy/.bashrc, .profile:         600 (-rw-------)"
echo "  - Application directories:                750 (drwxr-x---)"
echo "  - Application public/ directories:        750 (drwxr-x---)"
echo "  - Application shared/log, shared/tmp:     770 (drwxrwx---)"
echo "  - Rails credentials files (*.key):        600 (-rw-------)"
echo "  - Database config files:                  600 (-rw-------)"
echo ""
echo "Key Security Requirements:"
echo "  ✓ www-data must be in deploy group"
echo "  ✓ Home directory must be 710 (group can traverse but not list)"
echo "  ✓ SSH keys and configs must be 600/700 (owner-only)"
echo "  ✓ Secret files (.key, .env) must be 600 (owner read/write only)"
echo "  ✓ No world-writable files in /home/deploy"
echo ""
echo "========================================================================"
