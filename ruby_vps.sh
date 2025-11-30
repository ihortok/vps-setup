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
RUBY_VERSION="3.3.6"  # Latest stable as of January 2025
NODE_VERSION="20"     # LTS version
POSTGRESQL_VERSION="16"

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
    libgmp-dev
    libncurses5-dev
    libffi-dev
    libgdbm6
    libgdbm-dev
    libdb-dev

    # PostgreSQL client libraries
    libpq-dev

    # SQLite
    libsqlite3-dev

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

if command_exists node; then
    CURRENT_NODE_VERSION=$(node -v)
    log_info "Node.js already installed: $CURRENT_NODE_VERSION"
else
    log_info "Adding NodeSource repository..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash -

    log_info "Installing Node.js..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs

    INSTALLED_NODE_VERSION=$(node -v)
    log_success "Node.js installed: $INSTALLED_NODE_VERSION"
fi

################################################################################
# Install Yarn
################################################################################

log_info "Installing Yarn..."

if command_exists yarn; then
    CURRENT_YARN_VERSION=$(yarn -v)
    log_info "Yarn already installed: $CURRENT_YARN_VERSION"
else
    log_info "Adding Yarn repository..."
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list

    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq yarn

    INSTALLED_YARN_VERSION=$(yarn -v)
    log_success "Yarn installed: $INSTALLED_YARN_VERSION"
fi

################################################################################
# Install PostgreSQL
################################################################################

log_info "Installing PostgreSQL $POSTGRESQL_VERSION..."

if command_exists psql; then
    CURRENT_PG_VERSION=$(psql --version)
    log_info "PostgreSQL already installed: $CURRENT_PG_VERSION"
else
    log_info "Adding PostgreSQL APT repository..."
    sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
    wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -

    sudo apt-get update -qq

    log_info "Installing PostgreSQL server and client..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "postgresql-$POSTGRESQL_VERSION" "postgresql-client-$POSTGRESQL_VERSION"

    log_success "PostgreSQL $POSTGRESQL_VERSION installed"
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
    sudo -u postgres createuser -s "$DEPLOY_USER"
    log_success "PostgreSQL role '$DEPLOY_USER' created with superuser privileges"
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
    log_info "Installing libnginx-mod-http-passenger..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libnginx-mod-http-passenger nginx

    log_success "Passenger + Nginx installed"
fi

# Ensure Passenger Nginx module is enabled
if [ ! -f /etc/nginx/modules-enabled/50-mod-http-passenger.conf ]; then
    log_info "Enabling Passenger Nginx module..."
    if [ -f /usr/share/nginx/modules-available/mod-http-passenger.load ]; then
        sudo ln -s /usr/share/nginx/modules-available/mod-http-passenger.load /etc/nginx/modules-enabled/50-mod-http-passenger.conf
    fi
fi

# Configure Passenger to use the correct Ruby
PASSENGER_CONF="/etc/nginx/conf.d/mod-http-passenger.conf"
if [ -f "$PASSENGER_CONF" ]; then
    RBENV_RUBY_PATH="$HOME/.rbenv/shims/ruby"

    # Check if passenger_ruby is already configured correctly
    if ! sudo grep -q "passenger_ruby $RBENV_RUBY_PATH" "$PASSENGER_CONF"; then
        log_info "Configuring Passenger to use rbenv Ruby..."

        # Backup original config
        sudo cp "$PASSENGER_CONF" "${PASSENGER_CONF}.bak"

        # Update or add passenger_ruby directive
        if sudo grep -q "passenger_ruby" "$PASSENGER_CONF"; then
            sudo sed -i "s|passenger_ruby .*|passenger_ruby $RBENV_RUBY_PATH;|" "$PASSENGER_CONF"
        else
            echo "passenger_ruby $RBENV_RUBY_PATH;" | sudo tee -a "$PASSENGER_CONF" >/dev/null
        fi

        log_success "Passenger configured to use rbenv Ruby"
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
echo ""
echo "Next Steps:"
echo "----------"
echo "1. Configure Nginx virtual hosts for your applications in /etc/nginx/sites-available/"
echo "2. Create symbolic links in /etc/nginx/sites-enabled/ to enable sites"
echo "3. Set up your Rails/Sinatra applications using Capistrano"
echo "4. Configure PostgreSQL databases for your applications"
echo "5. Set up SSL certificates (e.g., using Let's Encrypt with certbot)"
echo ""
echo "Useful Commands:"
echo "---------------"
echo "  - Test Nginx config:        sudo nginx -t"
echo "  - Reload Nginx:             sudo systemctl reload nginx"
echo "  - Restart Nginx:            sudo systemctl restart nginx"
echo "  - Check Passenger status:   sudo passenger-status"
echo "  - View Nginx error log:     sudo tail -f /var/log/nginx/error.log"
echo "  - PostgreSQL CLI:           psql -d database_name"
echo "  - Redis CLI:                redis-cli"
echo ""
echo "=========================================================================="
echo -e "${GREEN}Your VPS is now ready for deploying Ruby applications!${NC}"
echo "=========================================================================="
echo ""
