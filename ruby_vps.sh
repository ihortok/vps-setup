#!/bin/bash

################################################################################
# Ubuntu 22.04 VPS Setup Script for Multiple Ruby Applications
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
RUBY_VERSION="3.4.7"  # Latest stable as of January 2025
NODE_VERSION="24"     # LTS version
# POSTGRESQL_VERSION="16"  # Not needed - using Ubuntu's default PostgreSQL 14

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
    rustc

    # Development libraries
    libssl-dev
    libyaml-dev
    libreadline6-dev
    zlib1g-dev
    # libgmp-dev          # Rarely needed for web apps, can skip
    # libncurses5-dev     # Terminal UI library, rarely needed for Rails
    libffi-dev
    libgdbm6
    libgdbm-dev
    # libdb-dev           # Berkeley DB, rarely used in modern Rails

    # PostgreSQL client libraries
    libpq-dev

    libsqlite3-dev

    # Image processing (for image_processing gem)
    libvips
    libvips-dev

    # Version control
    git

    # Utilities
    curl
    wget
    gnupg2
    ca-certificates
    lsb-release
    apt-transport-https
    software-properties-common
)

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PACKAGES[@]}"

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
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash -

    log_info "Installing Node.js..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs

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
# Install PostgreSQL (Ubuntu default - version 14)
################################################################################

log_info "Installing PostgreSQL..."

if command_exists psql; then
    CURRENT_PG_VERSION=$(psql --version)
    log_info "PostgreSQL already installed: $CURRENT_PG_VERSION"
else
    log_info "Installing PostgreSQL server and contrib extensions..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        postgresql \
        postgresql-contrib

    INSTALLED_PG_VERSION=$(psql --version 2>/dev/null || echo "PostgreSQL 14")
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
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 libsqlite3-dev
    INSTALLED_SQLITE_VERSION=$(sqlite3 --version)
    log_success "SQLite installed: $INSTALLED_SQLITE_VERSION"
fi

################################################################################
# Install Redis
################################################################################

log_info "Installing Redis..."

if command_exists redis-server; then
    CURRENT_REDIS_VERSION=$(redis-server --version)
    log_info "Redis already installed: $CURRENT_REDIS_VERSION"
else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq redis-server

    # Configure Redis to start on boot
    sudo systemctl enable redis-server
    sudo systemctl start redis-server

    INSTALLED_REDIS_VERSION=$(redis-server --version)
    log_success "Redis installed: $INSTALLED_REDIS_VERSION"
fi

# Configure Redis password for security
REDIS_PASSWORD_FILE="$HOME/.redis_password"
REDIS_CONF="/etc/redis/redis.conf"

if sudo grep -q "^requirepass" "$REDIS_CONF"; then
    log_info "Redis password already configured"
else
    log_info "Configuring Redis password for security..."

    # Generate a secure random password
    REDIS_PASSWORD=$(openssl rand -base64 32)

    # Add password to Redis configuration
    echo "requirepass $REDIS_PASSWORD" | sudo tee -a "$REDIS_CONF" >/dev/null

    # Restart Redis to apply changes
    sudo systemctl restart redis-server

    # Save password securely for deploy user
    echo "$REDIS_PASSWORD" > "$REDIS_PASSWORD_FILE"
    chmod 600 "$REDIS_PASSWORD_FILE"

    log_success "Redis password configured and saved to $REDIS_PASSWORD_FILE"
    log_warning "IMPORTANT: Save your Redis password from $REDIS_PASSWORD_FILE"
fi

log_success "Redis configured and running"

################################################################################
# Install Passenger + Nginx
################################################################################

log_info "Installing Passenger + Nginx from official Passenger APT repository..."

# Add Passenger APT repository
if [ ! -f /etc/apt/sources.list.d/passenger.list ]; then
    log_info "Adding Passenger APT repository..."
    sudo apt-get install -y -qq dirmngr gnupg apt-transport-https ca-certificates curl

    curl https://oss-binaries.phusionpassenger.com/auto-software-signing-gpg-key.txt | \
        gpg --dearmor | \
        sudo tee /etc/apt/trusted.gpg.d/phusionpassenger.gpg >/dev/null

    sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger jammy main > /etc/apt/sources.list.d/passenger.list'

    sudo apt-get update -qq
else
    log_info "Passenger APT repository already configured"
fi

# Install Passenger + Nginx
if command_exists nginx && command_exists passenger; then
    log_info "Passenger and Nginx already installed"
else
    log_info "Installing libnginx-mod-http-passenger and Nginx..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libnginx-mod-http-passenger nginx

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

log_success "Passenger + Nginx configured and running"

################################################################################
# Set Secure File Permissions
################################################################################

log_info "Setting secure file permissions..."

# Ensure .ssh directory has correct permissions
if [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME/.ssh"/* 2>/dev/null || true
fi

# Ensure rbenv directory has correct permissions
chmod -R u+rwX,go-w "$RBENV_ROOT"

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
        sudo apt-get install -y -qq snapd
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
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
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
# Cleanup
################################################################################

log_info "Cleaning up package manager cache..."
sudo apt-get autoremove -y -qq
sudo apt-get clean -qq

log_success "Cleanup completed"

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
echo -e "${BLUE}Redis Auth:${NC}    Password configured"
if [ -f "$REDIS_PASSWORD_FILE" ]; then
    echo -e "${YELLOW}Redis Password:${NC} $(cat $REDIS_PASSWORD_FILE)"
    echo -e "${YELLOW}               Saved in: $REDIS_PASSWORD_FILE${NC}"
fi
echo ""
echo "Next Steps:"
echo "----------"
echo "1. SAVE YOUR REDIS PASSWORD from $REDIS_PASSWORD_FILE"
echo "2. Configure Nginx virtual hosts for your applications in /etc/nginx/sites-available/"
echo "3. Create symbolic links in /etc/nginx/sites-enabled/ to enable sites"
echo "4. Set up your Rails/Sinatra applications using Capistrano"
echo "5. Configure PostgreSQL databases for your applications"
echo "6. Set up SSL certificates (e.g., using Let's Encrypt with certbot)"
echo "7. Configure your Rails apps to use Redis password in config/cable.yml and sidekiq.yml"
echo ""
echo "Useful Commands:"
echo "---------------"
echo "  - Test Nginx config:        sudo nginx -t"
echo "  - Reload Nginx:             sudo systemctl reload nginx"
echo "  - Restart Nginx:            sudo systemctl restart nginx"
echo "  - Check Passenger status:   sudo passenger-status"
echo "  - View Nginx error log:     sudo tail -f /var/log/nginx/error.log"
echo "  - PostgreSQL CLI:           psql -d database_name"
echo "  - Redis CLI (with auth):    redis-cli -a \$(cat $REDIS_PASSWORD_FILE)"
echo "  - Check firewall status:    sudo ufw status"
echo ""
echo "=========================================================================="
echo -e "${GREEN}Your VPS is now ready for deploying Ruby applications!${NC}"
echo "=========================================================================="
echo ""
