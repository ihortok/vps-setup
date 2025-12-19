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
#   --setup-sidekiq      - Set up Sidekiq as systemd service (default: false)
#
# Examples:
#   ./setup_rails_app.sh wallet wallet.example.io
#   ./setup_rails_app.sh events events.example.io --db-name events_prod
#   ./setup_rails_app.sh example example.io --request-ssl --setup-sidekiq
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
    echo "  --setup-sidekiq      - Set up Sidekiq as systemd service (default: false)"
    echo ""
    echo "Example:"
    echo "  $0 wallet wallet.example.io"
    echo "  $0 wallet wallet.example.io --request-ssl --setup-sidekiq"
    exit 1
fi

APP_NAME="$1"
DOMAIN="$2"
shift 2

# Default values
DB_NAME="${APP_NAME}_production"
RAILS_ENV="production"
REQUEST_SSL=false
SETUP_SIDEKIQ=false

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
        --setup-sidekiq)
            SETUP_SIDEKIQ=true
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
echo -e "${BLUE}Sidekiq:${NC}         $([ "$SETUP_SIDEKIQ" = true ] && echo "Will set up as systemd service" || echo "Not requested (use --setup-sidekiq to enable)")"
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

# Create placeholder directory structure for testing
log_info "Creating placeholder public directory..."
mkdir -p "$APP_ROOT/current/public"

# Create simple index.html for testing Nginx configuration
cat > "$APP_ROOT/current/public/index.html" <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Hello World!</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .container {
            text-align: center;
        }
        h1 {
            font-size: 3em;
            margin: 0;
        }
        p {
            font-size: 1.2em;
            opacity: 0.9;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Hello World!</h1>
        <p>Nginx is configured correctly.</p>
        <p>Ready for deployment.</p>
    </div>
</body>
</html>
EOF

# Set proper ownership
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_ROOT"

log_success "Placeholder index.html created for testing"
log_info "You can now visit http://$DOMAIN to test the Nginx configuration"

################################################################################
# Create Rails Credentials Production Key
################################################################################

log_info "Setting up Rails credentials production key..."

# Create credentials directory
CREDENTIALS_DIR="$APP_ROOT/shared/config/credentials"
mkdir -p "$CREDENTIALS_DIR"

PRODUCTION_KEY_FILE="$CREDENTIALS_DIR/production.key"

# Check if key file already exists
if [ -f "$PRODUCTION_KEY_FILE" ]; then
    log_warning "Production key already exists at: $PRODUCTION_KEY_FILE"
    read -p "Overwrite existing key? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Keeping existing production key"
    else
        log_info "Will overwrite existing key"
        rm -f "$PRODUCTION_KEY_FILE"
    fi
fi

# Prompt for production key if file doesn't exist or was removed
if [ ! -f "$PRODUCTION_KEY_FILE" ]; then
    echo ""
    echo "==========================================================================="
    echo -e "${YELLOW}Rails Credentials Production Key${NC}"
    echo "==========================================================================="
    echo ""
    echo "Enter your Rails production.key content."
    echo "This is the encryption key for your Rails credentials."
    echo ""
    echo "To generate a new key, run on your development machine:"
    echo "  ${BLUE}EDITOR='echo' rails credentials:edit --environment production${NC}"
    echo ""
    echo "Or to use an existing key, paste it from:"
    echo "  ${BLUE}config/credentials/production.key${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Keep this key secret and store it securely!${NC}"
    echo ""
    read -p "Paste your production key (or press Enter to skip): " -r PRODUCTION_KEY
    echo ""

    if [ -z "$PRODUCTION_KEY" ]; then
        log_warning "Production key not provided - you'll need to add it manually before deploying"
        log_info "Create the file: $PRODUCTION_KEY_FILE"
        log_info "Set permissions: chmod 600 $PRODUCTION_KEY_FILE"
    else
        # Write key to file
        echo "$PRODUCTION_KEY" > "$PRODUCTION_KEY_FILE"

        # Set secure permissions (owner read/write only)
        chmod 600 "$PRODUCTION_KEY_FILE"

        # Set proper ownership
        chown "$DEPLOY_USER:$DEPLOY_USER" "$PRODUCTION_KEY_FILE"

        log_success "Production key saved to: $PRODUCTION_KEY_FILE"
        log_success "File permissions set to 600 (owner read/write only)"
    fi
fi

echo ""

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

# Rate limiting zone (10 req/sec per IP, with burst allowance)
limit_req_zone \\\$binary_remote_addr zone=${APP_NAME}_limit:10m rate=10r/s;
limit_req_status 429;

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

    # Security headers
    # Note: Most of these are also set by Rails by default (config.action_dispatch.default_headers)
    # We set them at Nginx level as defense-in-depth for static files and error pages
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # X-XSS-Protection is intentionally NOT included (deprecated, can cause vulnerabilities)
    # Rails 7.1+ disables it by default. Use Content-Security-Policy instead.

    # Client upload size (default 10MB)
    # Increase for specific endpoints if needed (e.g., location /uploads { client_max_body_size 100m; })
    client_max_body_size 10m;

    # Apply rate limiting to all requests
    location / {
        limit_req zone=${APP_NAME}_limit burst=20 nodelay;
        try_files \\\$uri @passenger;
    }

    location @passenger {
        passenger_enabled on;
    }

    # Action Cable WebSocket support
    location /cable {
        passenger_app_group_name ${APP_NAME}_websocket;
        passenger_force_max_concurrent_requests_per_process 0;
    }

    # Assets and static files (no rate limiting for static assets)
    location ~ ^/(assets|packs) {
        gzip_static on;
        expires max;
        add_header Cache-Control public;
        limit_req off;
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
# Set Up Sidekiq Systemd Service (Optional)
################################################################################

if [ "$SETUP_SIDEKIQ" = true ]; then
    log_info "Setting up Sidekiq as systemd service..."

    SIDEKIQ_SERVICE="sidekiq-${APP_NAME}"
    SIDEKIQ_SERVICE_FILE="/etc/systemd/system/${SIDEKIQ_SERVICE}.service"

    # Create systemd service file
    sudo tee "$SIDEKIQ_SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Sidekiq Background Worker for $APP_NAME
After=syslog.target network.target

[Service]
Type=notify
WatchdogSec=10

# Run as deploy user
User=$DEPLOY_USER
Group=$DEPLOY_USER

# Working directory (Capistrano current release)
WorkingDirectory=$APP_ROOT/current

# Environment
Environment=RAILS_ENV=$RAILS_ENV
Environment=RBENV_ROOT=/home/$DEPLOY_USER/.rbenv
Environment=PATH=/home/$DEPLOY_USER/.rbenv/shims:/home/$DEPLOY_USER/.rbenv/bin:/usr/local/bin:/usr/bin:/bin
Environment=MALLOC_ARENA_MAX=2

# Start Sidekiq
ExecStart=/home/$DEPLOY_USER/.rbenv/shims/bundle exec sidekiq -e $RAILS_ENV

# Graceful reload (stops accepting new jobs, finishes current ones)
ExecReload=/usr/bin/kill -TSTP \$MAINPID

# Restart policy
Restart=on-failure
RestartSec=1

# Process management
TimeoutSec=60
KillMode=mixed
KillSignal=SIGTERM

# Logging
StandardOutput=append:/home/$DEPLOY_USER/apps/$APP_NAME/shared/log/sidekiq.log
StandardError=append:/home/$DEPLOY_USER/apps/$APP_NAME/shared/log/sidekiq.log
SyslogIdentifier=$SIDEKIQ_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    log_success "Sidekiq systemd service created: $SIDEKIQ_SERVICE_FILE"

    # Reload systemd daemon
    log_info "Reloading systemd daemon..."
    sudo systemctl daemon-reload

    # Enable service (but don't start until first deploy)
    log_info "Enabling Sidekiq service..."
    sudo systemctl enable "$SIDEKIQ_SERVICE"

    log_success "Sidekiq service configured and enabled"
    log_warning "Note: Service will start after first Capistrano deployment"
    log_info "Capistrano should restart Sidekiq after each deployment"
else
    log_info "Sidekiq systemd service not requested (use --setup-sidekiq to enable)"
fi

################################################################################
# Set App Directory Permissions
################################################################################

log_info "Setting app directory permissions..."

# Set app directory ownership and permissions
sudo chgrp -R deploy "$APP_ROOT"

# Base permissions: User gets full access, Group gets execute-only (traverse but not list), Others get nothing
# This prevents www-data from listing directory contents while still allowing traversal to known paths
sudo chmod -R u+rwX,g-rw+X,o-rwx "$APP_ROOT"

# Public directory needs group read+execute so Nginx can serve static files
if [ -d "$APP_ROOT/current/public" ]; then
    sudo chmod -R u+rwX,g+rX,o-rwx "$APP_ROOT/current/public"
    log_success "Public directory set to group-readable for Nginx"
fi

# Shared directories that Passenger needs write access to (will be created by Capistrano)
# These will be created during deployment, but we set permissions now for when they exist
for shared_dir in log tmp pids; do
    if [ -d "$APP_ROOT/shared/$shared_dir" ]; then
        sudo chmod -R u+rwX,g+rwX,o-rwx "$APP_ROOT/shared/$shared_dir"
        log_success "Shared $shared_dir directory set to group-writable for Passenger"
    fi
done

log_success "App directory permissions configured"
log_info "www-data can traverse directories but cannot list contents (execute-only)"
log_info "www-data can read/serve files from public/ directory only"

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
echo "  - Rails credentials: $CREDENTIALS_DIR/production.key $([ -f "$PRODUCTION_KEY_FILE" ] && echo "(✓ configured)" || echo "(⚠ needs manual setup)")"
echo "  - PostgreSQL database: $DB_NAME (owned by $DEPLOY_USER)"
echo "  - Nginx virtual host: $NGINX_CONFIG (enabled and active)"
if [ "$REQUEST_SSL" = true ]; then
    echo "  - SSL certificate: $([ -d "/etc/letsencrypt/live/$DOMAIN" ] && echo "✓ Configured" || echo "✗ Failed (see warnings above)")"
fi
if [ "$SETUP_SIDEKIQ" = true ]; then
    echo "  - Sidekiq systemd service: sidekiq-${APP_NAME} (enabled, will start after first deploy)"
fi
echo "  - App directory permissions: Secured with group-based access (www-data via deploy group)"
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
if [ ! -f "$PRODUCTION_KEY_FILE" ]; then
    echo "2. ${YELLOW}⚠ Add production.key manually (REQUIRED before deploy):${NC}"
    echo "   ${BLUE}echo 'YOUR_PRODUCTION_KEY' > $PRODUCTION_KEY_FILE${NC}"
    echo "   ${BLUE}chmod 600 $PRODUCTION_KEY_FILE${NC}"
    echo ""
    echo "   Generate a new key on your development machine:"
    echo "   ${BLUE}EDITOR='echo' rails credentials:edit --environment production${NC}"
    echo ""
    NEXT_STEP=3
else
    NEXT_STEP=2
fi
echo "$NEXT_STEP. Configure database.yml for production (config/database.yml):"
echo "   ${BLUE}$RAILS_ENV:${NC}"
echo "   ${BLUE}  adapter: postgresql${NC}"
echo "   ${BLUE}  database: $DB_NAME${NC}"
echo "   ${BLUE}  username: $DEPLOY_USER${NC}"
echo "   ${BLUE}  host: localhost${NC}"
echo ""
NEXT_STEP=$((NEXT_STEP + 1))
echo "$NEXT_STEP. Configure Redis password in your app (if using Redis):"
echo "   ${YELLOW}Retrieve your Redis password from your password manager${NC}"
echo "   ${BLUE}Update config/cable.yml and sidekiq.yml with this password:${NC}"
echo ""
echo "   ${BLUE}# config/cable.yml${NC}"
echo "   ${BLUE}production:${NC}"
echo "   ${BLUE}  adapter: redis${NC}"
echo "   ${BLUE}  url: redis://:YOUR_PASSWORD@localhost:6379/1${NC}"
echo ""
echo "   ${BLUE}# config/sidekiq.yml (if using Sidekiq)${NC}"
echo "   ${BLUE}:production:${NC}"
echo "   ${BLUE}  :concurrency: 5${NC}"
echo "   ${BLUE}  :queues:${NC}"
echo "   ${BLUE}    - default${NC}"
echo ""
NEXT_STEP=$((NEXT_STEP + 1))

if [ "$SETUP_SIDEKIQ" = true ]; then
    echo "$NEXT_STEP. Configure Capistrano to restart Sidekiq (Capfile):"
    echo "   ${BLUE}require 'capistrano/sidekiq'${NC}"
    echo ""
    echo "   Add to Gemfile:"
    echo "   ${BLUE}gem 'capistrano-sidekiq', group: :development${NC}"
    echo ""
    NEXT_STEP=$((NEXT_STEP + 1))
fi

echo "$NEXT_STEP. Deploy your application:"
echo "   ${BLUE}cap $RAILS_ENV deploy${NC}"
echo ""

if [ "$REQUEST_SSL" = false ]; then
    NEXT_STEP=$((NEXT_STEP + 1))
    echo "$NEXT_STEP. Set up SSL certificate (optional, after first successful deploy):"
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
echo "  - Check production key:     ${BLUE}cat $PRODUCTION_KEY_FILE${NC}"
echo "  - Set production key:       ${BLUE}echo 'YOUR_KEY' > $PRODUCTION_KEY_FILE && chmod 600 $PRODUCTION_KEY_FILE${NC}"
if [ "$REQUEST_SSL" = true ]; then
    echo "  - Check SSL certificate:    ${BLUE}sudo certbot certificates${NC}"
    echo "  - Renew SSL (if needed):    ${BLUE}sudo certbot renew${NC}"
fi
if [ "$SETUP_SIDEKIQ" = true ]; then
    echo "  - View Sidekiq log:         ${BLUE}tail -f $APP_ROOT/shared/log/sidekiq.log${NC}"
    echo "  - Check Sidekiq status:     ${BLUE}sudo systemctl status sidekiq-${APP_NAME}${NC}"
    echo "  - Start Sidekiq:            ${BLUE}sudo systemctl start sidekiq-${APP_NAME}${NC}"
    echo "  - Stop Sidekiq:             ${BLUE}sudo systemctl stop sidekiq-${APP_NAME}${NC}"
    echo "  - Reload Sidekiq (graceful):${BLUE}sudo systemctl reload sidekiq-${APP_NAME}${NC}"
    echo "  - Restart Sidekiq:          ${BLUE}sudo systemctl restart sidekiq-${APP_NAME}${NC}"
fi
echo ""
echo "=========================================================================="
echo -e "${GREEN}Ready for Capistrano deployment!${NC}"
echo "=========================================================================="
echo ""
