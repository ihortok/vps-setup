#!/bin/bash
################################################################################
# Rails/Sinatra Application Setup Script for Ubuntu 22.04
################################################################################
#
# This script sets up a single Rails or Sinatra application on a VPS that has
# already been configured with the ruby_vps.sh script.
#
# What this script does:
# - Creates application directory
# - Creates PostgreSQL database for the application
# - Configures Nginx virtual host with Passenger
# - Sets proper permissions
#
# Prerequisites:
# - VPS must be set up with ruby_vps.sh first
# - Must be run as the deploy user (not root)
# - Domain/subdomain should already point to this server's IP
#
# Usage:
#   ./setup_rails_app.sh APP_NAME DOMAIN [OPTIONS]
#
# Arguments:
#   APP_NAME    - Application name (e.g., "wallet", "events", "blog")
#   DOMAIN      - Domain or subdomain (e.g., "wallet.example.com")
#
# Options:
#   --db-name NAME       - Database name (default: APP_NAME_production)
#   --rails-env ENV      - Rails environment (default: production)
#   --request-ssl        - Request SSL certificate via Certbot (default: false)
#
# Examples:
#   ./setup_rails_app.sh wallet wallet.example.io
#   ./setup_rails_app.sh events events.example.io --db-name events_prod
#   ./setup_rails_app.sh example example.io --request-ssl
#
################################################################################

set -euo pipefail

################################################################################
# Color Output
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

################################################################################
# Parse Arguments
################################################################################

if [ $# -lt 2 ]; then
    log_error "Usage: $0 APP_NAME DOMAIN [OPTIONS]"
    echo ""
    echo "Arguments:"
    echo "  APP_NAME    - Application name (e.g., 'wallet', 'events')"
    echo "  DOMAIN      - Domain or subdomain (e.g., 'wallet.example.com')"
    echo ""
    echo "Options:"
    echo "  --db-name NAME       - Database name (default: APP_NAME_production)"
    echo "  --rails-env ENV      - Rails environment (default: production)"
    echo "  --request-ssl        - Request SSL certificate via Certbot (default: false)"
    echo ""
    echo "Example:"
    echo "  $0 wallet wallet.example.io"
    echo "  $0 wallet wallet.example.io --request-ssl"
    exit 1
fi

APP_NAME="$1"
DOMAIN="$2"
shift 2

# Default values
DB_NAME="${APP_NAME}_production"
RAILS_ENV="production"
REQUEST_SSL=false

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --db-name)
            DB_NAME="$2"
            shift 2
            ;;
        --rails-env)
            RAILS_ENV="$2"
            shift 2
            ;;
        --request-ssl)
            REQUEST_SSL=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

################################################################################
# Configuration
################################################################################

DEPLOY_USER="deploy"
CURRENT_USER=$(whoami)

# Paths
APP_ROOT="/home/$DEPLOY_USER/apps/$APP_NAME"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONFIG="$NGINX_AVAILABLE/$APP_NAME"

# Redis password (for showing in setup summary)
REDIS_PASSWORD_FILE="$HOME/.redis_password"

################################################################################
# Validation
################################################################################

log_info "Validating environment..."

# Check user
if [ "$CURRENT_USER" != "$DEPLOY_USER" ]; then
    log_error "This script must be run as the '$DEPLOY_USER' user, not '$CURRENT_USER'."
    exit 1
fi

# Check if VPS is set up
if ! command -v nginx &> /dev/null; then
    log_error "Nginx is not installed. Please run ruby_vps.sh first."
    exit 1
fi

if ! command -v psql &> /dev/null; then
    log_error "PostgreSQL is not installed. Please run ruby_vps.sh first."
    exit 1
fi

# Validate app name (alphanumeric, underscore, hyphen only)
if ! [[ "$APP_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid app name. Use only letters, numbers, underscores, and hyphens."
    exit 1
fi

# Validate domain
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    log_error "Invalid domain format: $DOMAIN"
    exit 1
fi

# Check if Certbot is installed when SSL is requested
if [ "$REQUEST_SSL" = true ]; then
    if ! command -v certbot &> /dev/null; then
        log_error "Certbot is not installed. Please run ruby_vps.sh first or install Certbot manually."
        exit 1
    fi
fi

log_success "Environment validated"

################################################################################
# Summary
################################################################################

echo ""
echo "=========================================================================="
echo "Application Setup Configuration"
echo "=========================================================================="
echo -e "${BLUE}Application:${NC}     $APP_NAME"
echo -e "${BLUE}Domain:${NC}          $DOMAIN"
echo -e "${BLUE}Database:${NC}        $DB_NAME"
echo -e "${BLUE}Rails Env:${NC}       $RAILS_ENV"
echo -e "${BLUE}App Root:${NC}        $APP_ROOT"
echo -e "${BLUE}SSL:${NC}             $([ "$REQUEST_SSL" = true ] && echo "Will request certificate via Certbot" || echo "Not requested (use --request-ssl to enable)")"
echo "=========================================================================="
echo ""

read -p "Continue with setup? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Setup cancelled"
    exit 0
fi

################################################################################
# Create Application Directory
################################################################################

log_info "Creating application directory..."

# Create app directory
mkdir -p "$APP_ROOT"

log_success "Application directory created: $APP_ROOT"

################################################################################
# Create PostgreSQL Database
################################################################################

log_info "Setting up PostgreSQL database..."

# Check if database already exists
if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    log_warning "Database '$DB_NAME' already exists, skipping creation"
else
    log_info "Creating database '$DB_NAME'..."
    sudo -u postgres createdb -O "$DEPLOY_USER" "$DB_NAME"
    log_success "Database '$DB_NAME' created"
fi

################################################################################
# Create Nginx Configuration
################################################################################

log_info "Creating Nginx configuration..."

if [ -f "$NGINX_CONFIG" ]; then
    log_warning "Nginx config already exists: $NGINX_CONFIG"
    log_info "Creating backup: ${NGINX_CONFIG}.bak"
    sudo cp "$NGINX_CONFIG" "${NGINX_CONFIG}.bak"
fi

# Create Nginx virtual host config
sudo tee "$NGINX_CONFIG" > /dev/null <<EOF
# Nginx + Passenger configuration for $APP_NAME
# Domain: $DOMAIN

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $APP_ROOT/current/public;

    # Enable Passenger
    passenger_enabled on;
    passenger_app_env $RAILS_ENV;
    passenger_ruby /home/$DEPLOY_USER/.rbenv/shims/ruby;
    passenger_preload_bundler on;

    # Action Cable WebSocket support
    location /cable {
        passenger_app_group_name ${APP_NAME}_websocket;
        passenger_force_max_concurrent_requests_per_process 0;
    }

    # Client upload size
    client_max_body_size 100m;

    # Assets and static files
    location ~ ^/(assets|packs) {
        gzip_static on;
        expires max;
        add_header Cache-Control public;
    }

    # Error pages
    error_page 500 502 503 504 /500.html;
    error_page 404 /404.html;
    error_page 422 /422.html;
}
EOF

log_success "Nginx configuration created: $NGINX_CONFIG"

# Enable the site
if [ -L "$NGINX_ENABLED/$APP_NAME" ]; then
    log_info "Site already enabled in Nginx"
else
    log_info "Enabling site in Nginx..."
    sudo ln -s "$NGINX_CONFIG" "$NGINX_ENABLED/$APP_NAME"
    log_success "Site enabled"
fi

# Test Nginx configuration
log_info "Testing Nginx configuration..."
if sudo nginx -t; then
    log_success "Nginx configuration is valid"

    log_info "Reloading Nginx..."
    sudo systemctl reload nginx
    log_success "Nginx reloaded"
else
    log_error "Nginx configuration test failed"
    log_error "Please fix the configuration before deploying"
    exit 1
fi

################################################################################
# Request SSL Certificate (Optional)
################################################################################

if [ "$REQUEST_SSL" = true ]; then
    log_info "Requesting SSL certificate from Let's Encrypt..."

    # Run certbot with Nginx plugin
    sudo certbot --nginx -d "$DOMAIN"
else
    log_info "SSL certificate not requested (use --request-ssl to enable)"
fi

################################################################################
# Set Permissions
################################################################################

log_info "Setting proper permissions..."

# Ensure deploy user owns the app directory
chmod u+rwX,go-w "$APP_ROOT"

log_success "Permissions configured"

################################################################################
# Summary and Next Steps
################################################################################

echo ""
echo "=========================================================================="
echo -e "${GREEN}Application Setup Complete!${NC}"
echo "=========================================================================="
echo ""
echo "Application Details:"
echo "-------------------"
echo -e "${BLUE}Name:${NC}           $APP_NAME"
echo -e "${BLUE}Domain:${NC}         $DOMAIN"
echo -e "${BLUE}Database:${NC}       $DB_NAME"
echo -e "${BLUE}Root Path:${NC}      $APP_ROOT"
echo -e "${BLUE}Nginx Config:${NC}   $NGINX_CONFIG"
echo ""
echo "What's Been Created:"
echo "-------------------"
echo "  - Application directory: $APP_ROOT"
echo "  - PostgreSQL database: $DB_NAME (owned by $DEPLOY_USER)"
echo "  - Nginx virtual host: $NGINX_CONFIG (enabled and active)"
if [ "$REQUEST_SSL" = true ]; then
    echo "  - SSL certificate: $([ -d "/etc/letsencrypt/live/$DOMAIN" ] && echo "✓ Configured" || echo "✗ Failed (see warnings above)")"
fi
echo ""
echo -e "${BLUE}Note:${NC} Capistrano will create the full directory structure (releases/, shared/, etc.) on first deploy"
echo ""
echo -e "${YELLOW}Next Steps - Capistrano Configuration:${NC}"
echo "--------------------------------------"
echo ""
echo "1. Update your Capistrano configuration (config/deploy/$RAILS_ENV.rb):"
echo "   ${BLUE}set :deploy_to, '$APP_ROOT'${NC}"
echo "   ${BLUE}server '$DOMAIN', user: '$DEPLOY_USER', roles: %w{app db web}${NC}"
echo ""
echo "2. Configure database.yml for production (config/database.yml):"
echo "   ${BLUE}$RAILS_ENV:${NC}"
echo "   ${BLUE}  adapter: postgresql${NC}"
echo "   ${BLUE}  database: $DB_NAME${NC}"
echo "   ${BLUE}  username: $DEPLOY_USER${NC}"
echo "   ${BLUE}  host: localhost${NC}"
echo ""
if [ -f "$REDIS_PASSWORD_FILE" ]; then
    REDIS_PASSWORD=$(cat "$REDIS_PASSWORD_FILE")
    echo "3. Configure Redis password in your app (if using Redis):"
    echo "   ${YELLOW}Redis Password:${NC} $REDIS_PASSWORD"
    echo "   ${BLUE}Update config/cable.yml and sidekiq.yml with this password${NC}"
    echo ""
    echo "4. Deploy your application:"
else
    echo "3. Deploy your application:"
fi
echo "   ${BLUE}cap $RAILS_ENV deploy${NC}"
echo ""
if [ "$REQUEST_SSL" = false ]; then
    if [ -f "$REDIS_PASSWORD_FILE" ]; then
        echo "5. Set up SSL certificate (optional, after first successful deploy):"
    else
        echo "4. Set up SSL certificate (optional, after first successful deploy):"
    fi
    echo "   ${BLUE}sudo certbot --nginx -d $DOMAIN${NC}"
    echo ""
fi
echo "Useful Commands:"
echo "---------------"
echo "  - View Nginx error log:     ${BLUE}sudo tail -f /var/log/nginx/error.log${NC}"
echo "  - View application log:     ${BLUE}tail -f $APP_ROOT/shared/log/$RAILS_ENV.log${NC} (after deploy)"
echo "  - Restart application:      ${BLUE}sudo passenger-config restart-app $APP_ROOT${NC}"
echo "  - Check Passenger status:   ${BLUE}sudo passenger-status${NC}"
echo "  - Test Nginx config:        ${BLUE}sudo nginx -t${NC}"
echo "  - Reload Nginx:             ${BLUE}sudo systemctl reload nginx${NC}"
echo "  - Connect to database:      ${BLUE}psql -d $DB_NAME${NC}"
if [ "$REQUEST_SSL" = true ]; then
    echo "  - Check SSL certificate:    ${BLUE}sudo certbot certificates${NC}"
    echo "  - Renew SSL (if needed):    ${BLUE}sudo certbot renew${NC}"
fi
echo ""
echo "=========================================================================="
echo -e "${GREEN}Ready for Capistrano deployment!${NC}"
echo "=========================================================================="
echo ""
