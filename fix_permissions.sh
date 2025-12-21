#!/bin/bash
################################################################################
# VPS File Permissions Security Fix Script
################################################################################
#
# This script fixes file permission issues on existing VPS installations.
# Run this if you've already set up your VPS and want to apply security fixes.
#
# Usage:
#   bash fix_permissions.sh
#
# This script is idempotent and safe to re-run.
#
################################################################################

set -euo pipefail

################################################################################
# Color codes for output
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

fix_permissions() {
    local path="$1"
    local perms="$2"
    local description="$3"

    if [ -e "$path" ]; then
        local before=$(stat -c "%a" "$path" 2>/dev/null)
        chmod "$perms" "$path" 2>/dev/null || true
        local after=$(stat -c "%a" "$path" 2>/dev/null)

        if [ "$before" != "$after" ]; then
            log_success "Fixed $description: $path ($before → $after)"
        else
            log_info "Already correct: $description ($after)"
        fi
    fi
}

################################################################################
# Verify User
################################################################################

DEPLOY_USER="deploy"
CURRENT_USER=$(whoami)

if [ "$CURRENT_USER" != "$DEPLOY_USER" ]; then
    log_error "This script must be run as the '$DEPLOY_USER' user, not '$CURRENT_USER'."
    exit 1
fi

log_success "Running as $DEPLOY_USER user"

################################################################################
# Fix Permissions
################################################################################

echo ""
echo "========================================================================"
echo "VPS File Permissions Security Fix"
echo "========================================================================"
echo ""

log_info "Starting permission security audit and fixes..."
echo ""

# CRITICAL FIX: .passenger directory (world-writable = security risk)
if [ -d "$HOME/.passenger" ]; then
    before=$(stat -c "%a" "$HOME/.passenger")
    chmod 750 "$HOME/.passenger"
    after=$(stat -c "%a" "$HOME/.passenger")

    if [ "$before" = "777" ]; then
        log_warning "CRITICAL: Fixed world-writable .passenger directory ($before → $after)"
    else
        log_success "Secured .passenger directory: $after"
    fi
fi

# Fix home directory
fix_permissions "$HOME" "710" "Home directory"

# Fix SSH directory and files
if [ -d "$HOME/.ssh" ]; then
    fix_permissions "$HOME/.ssh" "700" "SSH directory"

    for file in "$HOME/.ssh"/*; do
        if [ -f "$file" ]; then
            fix_permissions "$file" "600" "SSH file: $(basename $file)"
        fi
    done
fi

# Fix shell configuration files
fix_permissions "$HOME/.bashrc" "600" "Bash configuration"
fix_permissions "$HOME/.profile" "600" "Profile configuration"
fix_permissions "$HOME/.bash_history" "600" "Bash history"

# Fix development tool directories
log_info "Fixing development tool directories..."
for dir in .bundle .local .yarn .cache .npm .gem .config .rbenv; do
    if [ -d "$HOME/$dir" ]; then
        before=$(stat -c "%a" "$HOME/$dir")
        chmod -R u+rwX,g-rwx,o-rwx "$HOME/$dir" 2>/dev/null || true
        after=$(stat -c "%a" "$HOME/$dir")

        if [ "$before" != "$after" ]; then
            log_success "Fixed $dir: $before → $after"
        else
            log_info "Already correct: $dir ($after)"
        fi
    fi
done

# Fix apps directory
if [ -d "$HOME/apps" ]; then
    fix_permissions "$HOME/apps" "750" "Apps root directory"

    # Fix each application
    for app_dir in "$HOME/apps"/*/ ; do
        if [ -d "$app_dir" ]; then
            app_name=$(basename "$app_dir")
            log_info "Fixing permissions for app: $app_name"

            # App root should be 750
            fix_permissions "$app_dir" "750" "  App root: $app_name"

            # Public directory should be group-readable (755) for Nginx
            if [ -d "${app_dir}current/public" ]; then
                chmod -R u+rwX,g+rX,o-rwx "${app_dir}current/public" 2>/dev/null || true
                log_success "  Public directory: group-readable for Nginx"
            fi

            # Shared directories should be group-writable (770) for Passenger
            for shared_dir in log tmp pids sockets; do
                if [ -d "${app_dir}shared/$shared_dir" ]; then
                    chmod -R u+rwX,g+rwX,o-rwx "${app_dir}shared/$shared_dir" 2>/dev/null || true
                    log_success "  Shared $shared_dir: group-writable for Passenger"
                fi
            done

            # Credential files should be 600 (owner-only)
            find "$app_dir" -type f \( -name "*.key" -o -name ".env*" -o -name "master.key" \) 2>/dev/null | while read -r file; do
                fix_permissions "$file" "600" "  Credential file: $(basename $file)"
            done
        fi
    done
fi

echo ""
log_info "Checking for security issues..."

# Check for world-writable files
world_writable=$(find "$HOME" -type f -perm -002 2>/dev/null | head -5)
if [ -z "$world_writable" ]; then
    log_success "No world-writable files found"
else
    log_warning "Found world-writable files (SECURITY RISK):"
    echo "$world_writable"
fi

# Verify www-data group membership
if groups www-data 2>/dev/null | grep -q deploy; then
    log_success "www-data is in deploy group (required for Nginx/Passenger)"
else
    log_warning "www-data is NOT in deploy group"
    log_info "Run: sudo usermod -a -G deploy www-data && sudo systemctl restart nginx"
fi

echo ""
echo "========================================================================"
echo "Summary"
echo "========================================================================"
echo ""
echo "Fixed Permissions:"
echo "  - /home/deploy:                    710 (drwx--x---)"
echo "  - /home/deploy/.ssh:               700 (drwx------)"
echo "  - /home/deploy/.ssh/*:             600 (-rw-------)"
echo "  - Shell configs (.bashrc, etc):    600 (-rw-------)"
echo "  - .passenger:                      750 (drwxr-x---)"
echo "  - apps/:                           750 (drwxr-x---)"
echo "  - apps/*/current/public:           group-readable (for Nginx)"
echo "  - apps/*/shared/log,tmp:           770 (drwxrwx---)"
echo "  - Credential files (*.key):        600 (-rw-------)"
echo "  - Dev tools (.bundle, .yarn, etc): 700 (drwx------)"
echo ""
echo "Security Checks:"
echo "  - World-writable files: $([ -z "$world_writable" ] && echo "None (good)" || echo "Found (see above)")"
echo "  - www-data group membership: $(groups www-data 2>/dev/null | grep -q deploy && echo "OK" || echo "Missing")"
echo ""
echo "========================================================================"
echo -e "${GREEN}Permission fixes completed!${NC}"
echo "========================================================================"
echo ""
