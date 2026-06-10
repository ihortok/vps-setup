#!/bin/bash

################################################################################
# Ubuntu 24.04 VPS Setup Script for Multiple Ruby Applications
################################################################################
#
# IMPORTANT: DO NOT RUN THIS SCRIPT AS ROOT!
#
# If you are setting up a fresh VPS, follow these steps BEFORE running this script:
#
# 1. SSH into your VPS as root:
#    ssh root@your-vps-ip
#
# 2. Create a deploy user:
#    adduser deploy
#
# 3. Add deploy to the sudo group:
#    usermod -aG sudo deploy
#
# 4. Configure SSH authorized keys for the deploy user:
#    mkdir -p /home/deploy/.ssh
#    cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
#    chown -R deploy:deploy /home/deploy/.ssh
#    chmod 700 /home/deploy/.ssh
#    chmod 600 /home/deploy/.ssh/authorized_keys
#
# 5. (Optional) Test SSH login as deploy user from another terminal before logging out as root
#
# 6. Exit root session and log in as deploy user:
#    exit
#    ssh deploy@your-vps-ip
#
# 7. Copy this script to the server and run it as the deploy user:
#    bash ruby_vps.sh
#
# This script is idempotent and safe to re-run.
#
################################################################################

# Exit on any error, undefined variables, and pipe failures
set -euo pipefail

################################################################################
# Configuration Variables
################################################################################

DEPLOY_USER="deploy"
RUBY_VERSION="4.0.5"
NODE_VERSION="24"
# POSTGRESQL_VERSION="16"  # Not needed - using Ubuntu's default PostgreSQL 16

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

################################################################################
# Verify User
################################################################################

log_info "Verifying user permissions..."

CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "$DEPLOY_USER" ]; then
    log_error "This script must be run as the '$DEPLOY_USER' user, not '$CURRENT_USER'."
    log_error "Please read the comments at the top of this script for setup instructions."
    exit 1
fi

# Verify sudo access
if ! sudo -n true 2>/dev/null; then
    log_warning "This script requires sudo access. You may be prompted for your password."
fi

log_success "Running as $DEPLOY_USER user with sudo access"

################################################################################
# System Update
################################################################################

log_info "Updating system package lists..."
sudo apt-get update -qq

log_info "Upgrading installed packages..."
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

log_success "System packages updated"

################################################################################
# Install System Build Tools and Dependencies
################################################################################

log_info "Installing system build tools and dependencies..."

PACKAGES=(
    # Build essentials
    build-essential
    autoconf
    bison
    patch

    # Development libraries
    libssl-dev
    libyaml-dev
    libreadline-dev
    zlib1g-dev
    libffi-dev
    libgdbm-dev

    # Image processing (for image_processing gem + ruby-vips)
    # Note: ruby-vips uses FFI (no native extensions). Modern FFI gem (1.17+)
    # ships precompiled binaries for x86_64-linux, so no compilation needed.
    # Only the runtime library is required. Saves ~50-100 MB vs libvips-dev.
    libvips42

    # Version control
    git

    # Utilities
    curl
    wget
    gnupg
    ca-certificates
)

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}"

log_success "System build tools and dependencies installed"

################################################################################
# Install rbenv and ruby-build
################################################################################

log_info "Installing rbenv and ruby-build..."

RBENV_ROOT="$HOME/.rbenv"

if [ ! -d "$RBENV_ROOT" ]; then
    log_info "Cloning rbenv..."
    git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"

    log_info "Compiling rbenv dynamic bash extension..."
    cd "$RBENV_ROOT" && src/configure && make -C src

    log_info "Cloning ruby-build..."
    git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
else
    log_info "rbenv already installed, updating..."
    cd "$RBENV_ROOT" && git pull
    cd "$RBENV_ROOT/plugins/ruby-build" && git pull
fi

# Configure rbenv in shell profile
BASHRC="$HOME/.bashrc"
if ! grep -q 'rbenv init' "$BASHRC"; then
    log_info "Adding rbenv to ~/.bashrc..."
    cat >> "$BASHRC" << 'EOF'

# rbenv configuration
export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"
EOF
fi

# Load rbenv for current session
export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init - bash)"

log_success "rbenv and ruby-build installed"

################################################################################
# Install Ruby
################################################################################

log_info "Installing Ruby $RUBY_VERSION..."

if rbenv versions | grep -q "$RUBY_VERSION"; then
    log_info "Ruby $RUBY_VERSION already installed"
else
    log_info "Compiling Ruby $RUBY_VERSION (this may take several minutes)..."
    rbenv install "$RUBY_VERSION"
fi

log_info "Setting Ruby $RUBY_VERSION as global default..."
rbenv global "$RUBY_VERSION"
rbenv rehash

# Verify Ruby installation
INSTALLED_RUBY_VERSION=$(ruby -v)
log_success "Ruby installed: $INSTALLED_RUBY_VERSION"

# Update RubyGems
log_info "Updating RubyGems..."
gem update --system --no-document -q

# Install Bundler
log_info "Installing Bundler..."
gem install bundler --no-document -q
rbenv rehash

log_success "Ruby environment configured"

################################################################################
# Install Node.js (LTS)
################################################################################

log_info "Installing Node.js $NODE_VERSION LTS..."

# Check if correct Node.js version is installed
NEEDS_NODE_INSTALL=true
if command_exists node; then
    CURRENT_NODE_MAJOR=$(node -v | cut -d'.' -f1 | sed 's/v//')
    if [ "$CURRENT_NODE_MAJOR" = "$NODE_VERSION" ]; then
        log_info "Node.js $NODE_VERSION already installed: $(node -v)"
        NEEDS_NODE_INSTALL=false
    else
        log_warning "Node.js $CURRENT_NODE_MAJOR found, but Node.js $NODE_VERSION required. Upgrading..."
    fi
fi

if [ "$NEEDS_NODE_INSTALL" = true ]; then
    log_info "Adding NodeSource repository..."
    # Download to a temp file first so the script can be inspected before execution.
    NODESOURCE_SETUP=$(mktemp /tmp/nodesource_setup.XXXXXX.sh)
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" -o "$NODESOURCE_SETUP"
    sudo -E bash "$NODESOURCE_SETUP"
    rm -f "$NODESOURCE_SETUP"

    log_info "Installing Node.js..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends nodejs

    INSTALLED_NODE_VERSION=$(node -v)
    log_success "Node.js installed: $INSTALLED_NODE_VERSION"
fi

################################################################################
# Install Yarn (via Corepack - modern approach)
################################################################################

log_info "Installing Yarn..."

if command_exists yarn && [ "$(yarn -v 2>/dev/null)" ]; then
    CURRENT_YARN_VERSION=$(yarn -v)
    log_info "Yarn already installed: $CURRENT_YARN_VERSION"
else
    log_info "Enabling Corepack (built-in package manager for Yarn/pnpm)..."

    # Corepack is included with Node.js 16+ but needs to be enabled
    sudo corepack enable

    # Install latest stable Yarn
    log_info "Installing Yarn via Corepack..."
    corepack prepare yarn@stable --activate

    INSTALLED_YARN_VERSION=$(yarn -v)
    log_success "Yarn installed via Corepack: $INSTALLED_YARN_VERSION"
fi

################################################################################
# Install PostgreSQL (Ubuntu default - version 16)
################################################################################

log_info "Installing PostgreSQL..."

if command_exists psql; then
    CURRENT_PG_VERSION=$(psql --version)
    log_info "PostgreSQL already installed: $CURRENT_PG_VERSION"
else
    log_info "Installing PostgreSQL server and contrib extensions..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        postgresql \
        postgresql-contrib \
        libpq-dev

    INSTALLED_PG_VERSION=$(psql --version 2>/dev/null || echo "PostgreSQL 16")
    log_success "PostgreSQL installed: $INSTALLED_PG_VERSION"
fi

# Ensure PostgreSQL is running
log_info "Ensuring PostgreSQL service is running..."
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Create PostgreSQL role for deploy user if it doesn't exist
log_info "Configuring PostgreSQL role for $DEPLOY_USER..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DEPLOY_USER'" | grep -q 1; then
    log_info "PostgreSQL role '$DEPLOY_USER' already exists"
else
    # Create user with CREATEDB privilege (not superuser for security)
    sudo -u postgres createuser -d "$DEPLOY_USER"
    log_success "PostgreSQL role '$DEPLOY_USER' created with CREATEDB privilege"
fi

log_success "PostgreSQL configured"

################################################################################
# Install SQLite
################################################################################

log_info "Installing SQLite..."

if command_exists sqlite3; then
    CURRENT_SQLITE_VERSION=$(sqlite3 --version)
    log_info "SQLite already installed: $CURRENT_SQLITE_VERSION"
else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends sqlite3 libsqlite3-dev
    INSTALLED_SQLITE_VERSION=$(sqlite3 --version)
    log_success "SQLite installed: $INSTALLED_SQLITE_VERSION"
fi

################################################################################
# Install Redis
################################################################################

log_info "Installing Redis (from official redis.io APT repo; Sidekiq 8 requires Redis >= 7.2)..."

# Add the official Redis APT repository (one-time setup; re-runs skip this block)
if [ ! -f /etc/apt/sources.list.d/redis.list ]; then
    log_info "Adding official Redis APT repository..."

    # Prerequisites for fetching the GPG key and reading the release codename
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        curl gpg lsb-release

    # Import the Redis signing key (overwriting any prior copy is fine)
    curl -fsSL https://packages.redis.io/gpg | \
        sudo gpg --dearmor --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
    sudo chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg

    # Register the repo
    echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/redis.list >/dev/null

    sudo apt-get update -qq
fi

# Install redis-server. `--force-confold` makes any future package upgrade
# preserve the ACL line we append below, deterministically across dpkg versions.
log_info "Installing redis-server..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    -o Dpkg::Options::="--force-confold" redis-server

# systemctl enable/start are idempotent (no-ops if already in state)
sudo systemctl enable redis-server
sudo systemctl start redis-server

INSTALLED_REDIS_VERSION=$(redis-server --version)
log_success "Redis installed: $INSTALLED_REDIS_VERSION"

# Configure Redis security (ACL-based; Redis 8 compatible)
REDIS_CONF="/etc/redis/redis.conf"
NEEDS_REDIS_RESTART=false

# Bind to localhost only. Redis 8's default already is localhost-only
# (`bind 127.0.0.1 -::1`), so the grep guard skips this on a fresh install.
# The block exists so a re-run still enforces localhost binding if the
# default ever changes upstream.
if ! sudo grep -q "^bind 127.0.0.1" "$REDIS_CONF"; then
    sudo sed -i 's/^bind .*/bind 127.0.0.1 ::1/' "$REDIS_CONF"
    NEEDS_REDIS_RESTART=true
fi

# Configure ACL: password + command restrictions for the default user.
if sudo grep -qE '^user default on ' "$REDIS_CONF"; then
    log_info "Redis ACL already configured"
else
    log_info "Configuring Redis authentication and command restrictions..."

    echo ""
    echo "==========================================================================="
    echo -e "${YELLOW}Redis Password Configuration${NC}"
    echo "==========================================================================="
    echo ""
    echo "Choose an option:"
    echo "  1) Generate a secure random password (recommended)"
    echo "  2) Provide your own password"
    echo ""
    read -p "Enter choice (1 or 2): " -r PASSWORD_CHOICE
    echo ""

    if [ "$PASSWORD_CHOICE" = "1" ]; then
        # Generate a secure random password (base64 -> only [A-Za-z0-9+/=], no whitespace)
        REDIS_PASSWORD=$(openssl rand -base64 32)

        echo -e "${GREEN}Generated secure password:${NC}"
        echo ""
        echo "┌────────────────────────────────────────────────────────┐"
        echo -e "│  ${YELLOW}$REDIS_PASSWORD${NC}  │"
        echo "└────────────────────────────────────────────────────────┘"
        echo ""
        echo -e "${RED}⚠️  IMPORTANT: Copy this password NOW to your password manager!${NC}"
        echo -e "${RED}⚠️  It will be written to /etc/redis/redis.conf only.${NC}"
        echo ""
        read -p "Press ENTER after you have saved the password..." -r
        echo ""
        read -p "Type the password to confirm you saved it: " -s -r CONFIRM_PASSWORD
        echo ""

        if [ "$REDIS_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
            log_error "Passwords don't match. Redis password not configured."
            log_error "You can re-run this script to try again."
            exit 1
        fi

        log_success "Password confirmed!"

    elif [ "$PASSWORD_CHOICE" = "2" ]; then
        # User provides their own password
        echo "Enter your Redis password (minimum 32 characters, no whitespace):"
        read -s -r REDIS_PASSWORD
        echo ""
        echo "Confirm password:"
        read -s -r REDIS_PASSWORD_CONFIRM
        echo ""

        if [ "$REDIS_PASSWORD" != "$REDIS_PASSWORD_CONFIRM" ]; then
            log_error "Passwords don't match. Please re-run the script."
            exit 1
        fi

        if [ ${#REDIS_PASSWORD} -lt 32 ]; then
            log_error "Password too short (minimum 32 characters). Please re-run the script."
            exit 1
        fi

        # ACL parsing reads the password up to whitespace; reject whitespace early.
        case "$REDIS_PASSWORD" in
            *[[:space:]]*)
                log_error "Password must not contain whitespace. Please re-run the script."
                exit 1
                ;;
        esac

        log_success "Password accepted"

    else
        log_error "Invalid choice. Please re-run the script."
        exit 1
    fi

    # ACL line: authentication + command restrictions in one directive.
    # `user default on >PASS ~* &* +@all -CMD...` means:
    #   on            - account enabled
    #   >PASS         - sets the password
    #   ~*            - all keys accessible
    #   &*            - all pub/sub channels accessible
    #   +@all -CMD... - all commands allowed except the listed dangerous ones
    # Bundled modules (Search, ReJSON, Bloom, TimeSeries, VectorSet) call
    # CONFIG via RM_Call internally during init, which bypasses ACL checks,
    # so they keep working while external clients are restricted.
    echo "user default on >$REDIS_PASSWORD ~* &* +@all -CONFIG -FLUSHDB -FLUSHALL -DEBUG -SHUTDOWN -KEYS" | \
        sudo tee -a "$REDIS_CONF" >/dev/null

    NEEDS_REDIS_RESTART=true

    # Clear password from memory
    unset REDIS_PASSWORD
    unset REDIS_PASSWORD_CONFIRM
    unset CONFIRM_PASSWORD

    # Restrict redis.conf to root:redis (640) so it is not world-readable.
    # The ACL line written above contains the plaintext password.
    sudo chmod 640 "$REDIS_CONF"
    sudo chown root:redis "$REDIS_CONF"

    log_success "Redis ACL configured in /etc/redis/redis.conf"
    log_info "Redis bound to localhost; default user requires password"
    log_info "CONFIG/FLUSHDB/FLUSHALL/DEBUG/SHUTDOWN/KEYS denied for external clients"
    log_warning "Store your Redis password securely in your password manager"
fi

if [ "$NEEDS_REDIS_RESTART" = "true" ]; then
    sudo systemctl restart redis-server
fi

log_success "Redis configured and running"

################################################################################
# Install Passenger + Nginx
################################################################################

log_info "Installing Passenger + Nginx from official Passenger APT repository..."

# Add Passenger APT repository
if [ ! -f /etc/apt/sources.list.d/passenger.list ]; then
    log_info "Adding Passenger APT repository..."
    sudo apt-get install -y -qq --no-install-recommends dirmngr gnupg apt-transport-https ca-certificates curl

    curl -fsSL https://oss-binaries.phusionpassenger.com/auto-software-signing-gpg-key-2025.txt | \
        gpg --dearmor | \
        sudo tee /etc/apt/trusted.gpg.d/phusion.gpg >/dev/null

    sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger noble main > /etc/apt/sources.list.d/passenger.list'

    sudo apt-get update -qq
else
    log_info "Passenger APT repository already configured"
fi

# Install Passenger + Nginx
if command_exists nginx && command_exists passenger; then
    log_info "Passenger and Nginx already installed"
else
    log_info "Installing libnginx-mod-http-passenger and Nginx..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libnginx-mod-http-passenger nginx

    log_success "Passenger + Nginx installed"
fi

# Configure Passenger to use rbenv Ruby
PASSENGER_CONF="/etc/nginx/conf.d/mod-http-passenger.conf"
RBENV_RUBY_PATH="/home/$DEPLOY_USER/.rbenv/shims/ruby"

log_info "Configuring Passenger to use rbenv Ruby..."

# Create or update Passenger configuration
if [ ! -f "$PASSENGER_CONF" ]; then
    # Create new config file
    sudo tee "$PASSENGER_CONF" >/dev/null <<EOF
# Phusion Passenger configuration
passenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;
passenger_ruby $RBENV_RUBY_PATH;
EOF
    log_success "Created Passenger configuration"
else
    # Update existing config
    if ! sudo grep -q "passenger_ruby $RBENV_RUBY_PATH" "$PASSENGER_CONF"; then
        # Backup original config
        sudo cp "$PASSENGER_CONF" "${PASSENGER_CONF}.bak"

        # Update or add passenger_ruby directive
        if sudo grep -q "passenger_ruby" "$PASSENGER_CONF"; then
            sudo sed -i "s|passenger_ruby .*;|passenger_ruby $RBENV_RUBY_PATH;|" "$PASSENGER_CONF"
        else
            echo "passenger_ruby $RBENV_RUBY_PATH;" | sudo tee -a "$PASSENGER_CONF" >/dev/null
        fi

        log_success "Updated Passenger configuration to use rbenv Ruby"
    else
        log_info "Passenger already configured to use rbenv Ruby"
    fi
fi

# Validate Passenger installation
log_info "Validating Passenger installation..."
sudo passenger-config validate-install --auto

# Enable and start Nginx
log_info "Enabling and starting Nginx..."
sudo systemctl enable nginx
sudo systemctl restart nginx

# Disable default Nginx site for security
log_info "Disabling default Nginx site..."
if [ -L /etc/nginx/sites-enabled/default ]; then
    sudo rm -f /etc/nginx/sites-enabled/default
    log_success "Default Nginx site disabled"
else
    log_info "Default Nginx site already disabled"
fi

# Add a catch-all default_server that silently drops unmatched requests (return 444).
# Without this, requests with an unknown Host header fall through to the first
# alphabetical vhost, which can leak content or error details.
DEFAULT_VHOST="/etc/nginx/sites-available/00-default-drop"
if [ ! -f "$DEFAULT_VHOST" ]; then
    log_info "Creating default_server catch-all vhost (drops unmatched requests)..."
    sudo tee "$DEFAULT_VHOST" > /dev/null <<'NGINXEOF'
# Catch-all server block: silently drop requests that don't match any real vhost.
# Placed first alphabetically (00-) so it is selected as the default_server.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
NGINXEOF
    sudo ln -sf "$DEFAULT_VHOST" /etc/nginx/sites-enabled/00-default-drop
    log_success "Default catch-all vhost created (HTTP 444 for unmatched hosts)"
else
    log_info "Default catch-all vhost already exists"
fi

# Configure global rate limiting directive
log_info "Configuring global rate limiting settings..."
NGINX_CONF="/etc/nginx/nginx.conf"
if ! sudo grep -q "limit_req_status" "$NGINX_CONF"; then
    # Add limit_req_status and server_tokens to http block (after the opening http {)
    sudo sed -i '/^http {/a \    # Global rate limiting status code (429 = Too Many Requests)\n    limit_req_status 429;\n    # Hide Nginx version from error pages and Server: header\n    server_tokens off;' "$NGINX_CONF"
    log_success "Global rate limiting configured (HTTP 429) and server_tokens disabled"
else
    log_info "Global rate limiting already configured"
fi

if ! sudo grep -q "server_tokens" "$NGINX_CONF"; then
    sudo sed -i '/^http {/a \    # Hide Nginx version from error pages and Server: header\n    server_tokens off;' "$NGINX_CONF"
    log_success "server_tokens disabled in nginx.conf"
fi

log_success "Passenger + Nginx configured and running"

################################################################################
# Configure Deploy User Environment
################################################################################

log_info "Configuring deploy user environment..."

PROFILE="/home/$DEPLOY_USER/.profile"
BASHRC="/home/$DEPLOY_USER/.bashrc"

# Ensure .profile exists
if [ ! -f "$PROFILE" ]; then
    log_info "Creating .profile..."
    touch "$PROFILE"

    # Add standard .profile content to source .bashrc
    cat >> "$PROFILE" <<'EOF'
# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
EOF
    log_success ".profile created with .bashrc sourcing"
else
    log_info ".profile already exists"

    # Check if .profile already sources .bashrc
    if ! grep -q "\.bashrc" "$PROFILE"; then
        log_warning ".profile exists but doesn't source .bashrc"
        log_info "Adding .bashrc sourcing to .profile..."
        cat >> "$PROFILE" <<'EOF'

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi
EOF
        log_success ".profile configured to source .bashrc"
    else
        log_info ".profile already sources .bashrc"
    fi
fi

# Add RAILS_ENV to .profile if not already present
if ! grep -q "export RAILS_ENV" "$PROFILE"; then
    log_info "Adding RAILS_ENV to .profile..."
    cat >> "$PROFILE" <<'EOF'

# Set Rails environment for production server
export RAILS_ENV="production"
EOF
    log_success "RAILS_ENV configured in .profile"
else
    log_info "RAILS_ENV already configured in .profile"
fi

log_success "Deploy user environment configured"
log_info "RAILS_ENV will be available for all login shells and SSH sessions"

################################################################################
# Configure www-data for Application Access
################################################################################

log_info "Configuring www-data for application access..."

# Add www-data to deploy group
if ! groups www-data | grep -q "\bdeploy\b"; then
    log_info "Adding www-data to deploy group..."
    sudo usermod -a -G deploy www-data
    log_success "www-data added to deploy group"

    # Restart Nginx to apply group membership
    log_info "Restarting Nginx to apply group membership..."
    sudo systemctl restart nginx
    log_success "Nginx restarted"
else
    log_info "www-data already in deploy group"
fi

# Set deploy home directory to group-traversable (but not world-traversable)
# Group has execute-only (can traverse but not list contents)
DEPLOY_HOME="/home/$DEPLOY_USER"
log_info "Setting secure permissions on $DEPLOY_HOME..."
chmod 710 "$DEPLOY_HOME"
log_success "Deploy home directory secured (710: owner=rwx, group=x only, others=none)"

log_success "www-data configured for application access"

################################################################################
# Set Secure File Permissions
################################################################################

log_info "Setting secure file permissions..."

# Ensure .ssh directory has correct permissions
if [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh"/* 2>/dev/null || true
fi

# Ensure shell config files are owner-only (no group or other access)
chmod 600 "$HOME/.bashrc" 2>/dev/null || true
chmod 600 "$HOME/.profile" 2>/dev/null || true

# Ensure rbenv directory has secure permissions (750 = owner full, group read/execute, no world access)
chmod -R u+rwX,g+rX,g-w,o-rwx "$RBENV_ROOT"

# Secure common development tool directories (prevent world-readable)
for dir in .bundle .local .yarn .cache .npm .gem; do
    if [ -d "$HOME/$dir" ]; then
        chmod -R u+rwX,g-rwx,o-rwx "$HOME/$dir" 2>/dev/null || true
    fi
done

# Create apps directory with secure permissions
log_info "Creating apps directory structure..."
mkdir -p "$HOME/apps"
chmod 750 "$HOME/apps"
log_success "Apps directory created with secure permissions (750)"

log_success "File permissions configured"

################################################################################
# Install Certbot (Let's Encrypt SSL)
################################################################################

log_info "Installing Certbot for SSL certificates..."

if command_exists certbot; then
    log_info "Certbot already installed: $(certbot --version)"
else
    log_info "Installing Certbot and Nginx plugin..."

    # Install snapd if not present (Certbot's recommended installation method)
    if ! command_exists snap; then
        sudo apt-get install -y -qq --no-install-recommends snapd
        sudo snap install core
        sudo snap refresh core
    fi

    # Remove old certbot packages if present
    sudo apt-get remove -y -qq certbot &>/dev/null || true

    # Install certbot via snap (official recommended method)
    sudo snap install --classic certbot

    # Create symbolic link
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot

    log_success "Certbot installed: $(certbot --version)"
fi

log_success "Certbot ready for SSL certificate requests"

################################################################################
# Configure Firewall (UFW)
################################################################################

log_info "Configuring firewall (UFW)..."

# Install UFW if not already installed
if ! command_exists ufw; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ufw
fi

# Check if firewall is already configured
if sudo ufw status | grep -q "Status: active"; then
    log_info "Firewall already active"
else
    log_info "Setting up firewall rules..."

    # Set default policies
    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    # Allow SSH (critical - don't lock yourself out!)
    sudo ufw allow OpenSSH

    # Allow HTTP and HTTPS for web traffic
    sudo ufw allow 80/tcp comment 'HTTP'
    sudo ufw allow 443/tcp comment 'HTTPS'

    # Enable firewall (--force to avoid interactive prompt)
    sudo ufw --force enable

    log_success "Firewall configured and enabled"
fi

# Show firewall status
log_info "Current firewall status:"
sudo ufw status numbered

log_success "Firewall configured"

################################################################################
# SSH Hardening Check and Configuration
################################################################################

log_info "Hardening SSH configuration..."

# Safety check: verify the current user has a working SSH key before locking down.
# We test by checking that ~/.ssh/authorized_keys exists and is non-empty, which
# means key-based auth is available and disabling passwords won't lock us out.
if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
    log_error "No SSH authorized_keys found for $USER. Aborting SSH hardening to prevent lockout."
    log_error "Add your public key to $HOME/.ssh/authorized_keys, then re-run."
    exit 1
fi

SSH_DROP_IN="/etc/ssh/sshd_config.d/99-hardened.conf"
SSH_DROP_IN_WRITTEN=false

if [ ! -f "$SSH_DROP_IN" ]; then
    sudo tee "$SSH_DROP_IN" > /dev/null <<'SSHEOF'
# Hardened SSH settings applied by ruby_vps.sh
# These override defaults in /etc/ssh/sshd_config via drop-in.
# Edit this file directly to adjust settings; it is NOT overwritten on re-runs.

PasswordAuthentication no
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 60
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
# local = allow -L local port forwarding (Postgres/Redis debugging), block -R remote forwarding
AllowTcpForwarding local
SSHEOF
    sudo chmod 600 "$SSH_DROP_IN"
    SSH_DROP_IN_WRITTEN=true
else
    log_info "SSH drop-in already exists, skipping write: $SSH_DROP_IN"
fi

# Validate and reload only when the drop-in was newly written
if [ "$SSH_DROP_IN_WRITTEN" = true ]; then
    if sudo sshd -t; then
        sudo systemctl reload sshd
        log_success "SSH hardened: password auth off, root login off, MaxAuthTries 3"
        echo ""
        log_warning "⚠️  IMPORTANT: Test SSH key login in a NEW terminal before closing this one!"
        log_warning "⚠️  If you get locked out, you can still access via VPS console."
        echo ""
        read -p "Press ENTER after you've confirmed SSH key login works..." -r
        echo ""
    else
        log_error "sshd config validation failed — drop-in NOT applied. Check $SSH_DROP_IN"
        sudo rm -f "$SSH_DROP_IN"
        exit 1
    fi
fi

log_success "SSH security configuration complete"

################################################################################
# Install fail2ban (Intrusion Prevention)
################################################################################

log_info "Installing fail2ban for intrusion prevention..."

if command_exists fail2ban-client; then
    log_info "fail2ban already installed: $(fail2ban-client version)"
else
    log_info "Installing fail2ban..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends fail2ban

    log_info "Configuring fail2ban..."

    # Create local configuration
    sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
# Ban duration: 1 hour
bantime = 3600

# Time window to count failures: 10 minutes
findtime = 600

# Number of failures before ban
maxretry = 5

# Email alerts (configure if needed)
destemail = root@localhost
sendername = Fail2Ban
action = %(action_)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 5

[nginx-limit-req]
enabled = true
filter = nginx-limit-req
logpath = /var/log/nginx/error.log
maxretry = 10
bantime = 600
EOF

    # Create nginx rate limit filter
    sudo tee /etc/fail2ban/filter.d/nginx-limit-req.conf > /dev/null <<'EOF'
[Definition]
failregex = limiting requests, excess: .* by zone .*, client: <HOST>
ignoreregex =
EOF

    # Enable and start fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban

    log_success "fail2ban installed and configured"
    log_info "SSH brute-force protection: 5 failed attempts = 1 hour ban"
fi

log_success "Intrusion prevention configured"

################################################################################
# Configure Automatic Security Updates
################################################################################

log_info "Configuring automatic security updates..."

if dpkg -l | grep -q unattended-upgrades; then
    log_info "unattended-upgrades already installed"
else
    log_info "Installing unattended-upgrades..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends unattended-upgrades apt-listchanges

    log_info "Configuring automatic security updates..."

    # Configure which updates to install
    sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'EOF'
// Automatically upgrade packages from these origins
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
};

// Do not automatically upgrade these packages
Unattended-Upgrade::Package-Blacklist {
};

// Automatically remove unused kernel packages
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Automatically remove unused dependencies
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Automatically reboot if required (disabled by default for safety)
Unattended-Upgrade::Automatic-Reboot "false";

// If automatic reboot is enabled, do it at this time
Unattended-Upgrade::Automatic-Reboot-Time "03:00";

// Enable logging
Unattended-Upgrade::SyslogEnable "true";

// Automatically fix interrupted dpkg
Unattended-Upgrade::AutoFixInterruptedDpkg "true";

// Split upgrade into smaller steps
Unattended-Upgrade::MinimalSteps "true";
EOF

    # Enable automatic updates
    sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

    # Enable and start the service
    sudo systemctl enable unattended-upgrades
    sudo systemctl start unattended-upgrades

    log_success "Automatic security updates enabled"
    log_info "Security patches will be installed daily"
    log_info "System will NOT automatically reboot (manual reboot required)"
fi

log_success "Automatic security updates configured"

################################################################################
# Cleanup
################################################################################

log_info "Cleaning up package manager cache..."
sudo apt-get autoremove -y -qq
sudo apt-get clean -qq

log_success "Cleanup completed"

################################################################################
# Final Security Permissions Audit
################################################################################

log_info "Performing final security permissions audit..."

# Fix any directories that may have been created with incorrect permissions during installation
for dir in .bundle .local .yarn .cache .npm .gem .config; do
    if [ -d "$HOME/$dir" ]; then
        chmod -R u+rwX,g-rwx,o-rwx "$HOME/$dir" 2>/dev/null || true
    fi
done

# Fix Passenger directory if it exists (sometimes created during Passenger installation)
if [ -d "$HOME/.passenger" ]; then
    chmod 750 "$HOME/.passenger"
    log_info "Secured .passenger directory (750)"
fi

# Ensure apps directory has correct permissions
if [ -d "$HOME/apps" ]; then
    chmod 750 "$HOME/apps"
fi

# Re-verify critical security permissions
chmod 710 "$HOME" 2>/dev/null || true
chmod 700 "$HOME/.ssh" 2>/dev/null || true
chmod 600 "$HOME/.ssh"/* 2>/dev/null || true
chmod 600 "$HOME/.bashrc" 2>/dev/null || true
chmod 600 "$HOME/.profile" 2>/dev/null || true

log_success "Final security permissions audit completed"

################################################################################
# Installation Summary
################################################################################

echo ""
echo "=========================================================================="
echo -e "${GREEN}VPS Setup Complete!${NC}"
echo "=========================================================================="
echo ""
echo "Installed Components:"
echo "-------------------"
echo -e "${BLUE}Ruby:${NC}          $(ruby -v)"
echo -e "${BLUE}Bundler:${NC}       $(bundle -v)"
echo -e "${BLUE}rbenv:${NC}         $(rbenv -v)"
echo -e "${BLUE}Node.js:${NC}       $(node -v)"
echo -e "${BLUE}npm:${NC}           $(npm -v)"
echo -e "${BLUE}Yarn:${NC}          $(yarn -v)"
echo -e "${BLUE}PostgreSQL:${NC}    $(psql --version)"
echo -e "${BLUE}SQLite:${NC}        $(sqlite3 --version | cut -d' ' -f1-3)"
echo -e "${BLUE}Redis:${NC}         $(redis-server --version | cut -d' ' -f3-4)"
echo -e "${BLUE}Nginx:${NC}         $(nginx -v 2>&1 | cut -d'/' -f2)"
echo -e "${BLUE}Passenger:${NC}     $(passenger --version | head -n1)"
echo -e "${BLUE}libvips:${NC}       $(vips --version | head -n1)"
echo ""
echo "Security Configuration:"
echo "---------------------"
echo -e "${BLUE}Firewall:${NC}      Active (SSH, HTTP, HTTPS allowed)"
echo -e "${BLUE}fail2ban:${NC}      Active (SSH brute-force protection)"
echo -e "${BLUE}Auto-Updates:${NC}  Enabled (security patches installed daily)"
echo -e "${BLUE}Redis Auth:${NC}    Password configured (stored only in your password manager)"
echo -e "${BLUE}Redis Bind:${NC}    Localhost only (127.0.0.1)"
echo -e "${BLUE}Redis Cmds:${NC}    Dangerous commands disabled (FLUSHDB, FLUSHALL, CONFIG)"
echo ""
echo "Environment Configuration:"
echo "------------------------"
echo -e "${BLUE}Deploy User:${NC}   $DEPLOY_USER"
echo -e "${BLUE}RAILS_ENV:${NC}     production (configured in ~/.profile)"
echo -e "${BLUE}www-data:${NC}      Added to deploy group for application access"
echo ""
echo "Next Steps:"
echo "----------"
echo "1. Ensure you have saved your Redis password in a secure password manager"
echo "2. Configure Nginx virtual hosts for your applications in /etc/nginx/sites-available/"
echo "3. Create symbolic links in /etc/nginx/sites-enabled/ to enable sites"
echo "4. Set up your Rails/Sinatra applications using Capistrano"
echo "5. Configure PostgreSQL databases for your applications"
echo "6. Set up SSL certificates (e.g., using Let's Encrypt with certbot)"
echo "7. Configure your Rails apps to use Redis password in config/cable.yml and sidekiq.yml"
echo ""
echo "Useful Commands:"
echo "---------------"
echo "  - Check RAILS_ENV:          echo \$RAILS_ENV (or: source ~/.profile && echo \$RAILS_ENV)"
echo "  - Test Nginx config:        sudo nginx -t"
echo "  - Reload Nginx:             sudo systemctl reload nginx"
echo "  - Restart Nginx:            sudo systemctl restart nginx"
echo "  - Check Passenger status:   sudo passenger-status"
echo "  - View Nginx error log:     sudo tail -f /var/log/nginx/error.log"
echo "  - PostgreSQL CLI:           psql -d database_name"
echo "  - Redis CLI (with auth):    redis-cli (then run: AUTH your_password)"
echo "  - Check firewall status:    sudo ufw status"
echo "  - Check fail2ban status:    sudo fail2ban-client status"
echo "  - Check banned IPs (SSH):   sudo fail2ban-client status sshd"
echo "  - Unban an IP:              sudo fail2ban-client set sshd unbanip IP_ADDRESS"
echo "  - Check security updates:   sudo unattended-upgrades --dry-run"
echo ""
echo "=========================================================================="
echo -e "${GREEN}Your VPS is now ready for deploying Ruby applications!${NC}"
echo "=========================================================================="
echo ""
