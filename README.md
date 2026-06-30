# VPS Setup Scripts for Ruby on Rails

Production-ready bash scripts for setting up a secure Ubuntu 24.04 VPS to host Ruby on Rails applications with Nginx, Passenger, PostgreSQL, Redis, and Sidekiq.

Built with assistance from [Claude](https://claude.ai) by Anthropic.

**📖 [Operations Guide](OPERATIONS.md)** - Quick reference for managing your VPS (fail2ban, Nginx logs, troubleshooting)

## Scripts

### `ruby_vps.sh`
Initial VPS setup and hardening. Installs and configures:
- Ruby (via rbenv)
- Node.js and Yarn
- PostgreSQL
- Redis
- Nginx with Passenger
- Security hardening (SSH, firewall, automatic updates)
- Secure file permissions

**Usage:**
```bash
chmod +x ruby_vps.sh
./ruby_vps.sh
```

### `setup_rails_app.sh`
Configures individual Rails applications with proper permissions, Nginx virtual hosts, and optional Sidekiq background workers.

**Usage:**
```bash
./setup_rails_app.sh APP_NAME DOMAIN [OPTIONS]
```

**Arguments:**
- `APP_NAME` - Application name (e.g., "myapp")
- `DOMAIN` - Domain or subdomain (e.g., "myapp.example.com")

**Options:**
- `--db-name NAME` - Database name (default: APP_NAME_production)
- `--rails-env ENV` - Rails environment (default: production)
- `--request-ssl` - Request SSL certificate via Certbot
- `--setup-sidekiq` - Configure Sidekiq systemd service

**Example:**
```bash
./setup_rails_app.sh myapp myapp.example.com --request-ssl --setup-sidekiq
```

### `fix_permissions.sh`
Security audit and fix tool for existing installations. Corrects file permissions to prevent security vulnerabilities.

**Usage:**
```bash
bash fix_permissions.sh
```

**What it fixes:**
- Critical: `.passenger/` directory (fixes world-writable 777 → 750)
- Home directory permissions (710)
- SSH keys and configs (700/600)
- Application directories (750)
- Credential files (600)
- Development tool directories (700)

### `backup.sh`
Backs up the two pieces of state that can't be re-provisioned from the scripts: the deploy-owned PostgreSQL databases and each app's `shared/storage` folder. Run as the `deploy` user, it detects what's available, prompts for a selection (or accepts flags for non-interactive runs), writes everything to `/home/deploy/backup_YYYY_MM_DD/`, and archives it to `.tar.gz`. Makes no changes to the host.

**Usage:**
```bash
# Interactive
bash backup.sh

# Non-interactive
bash backup.sh --all
bash backup.sh --dbs wallet_production --storage wallet -y
```

**Options:** `--all`, `--dbs "a,b"`, `--storage "a,b"`, `--output-dir DIR`, `--no-archive`, `--keep-folder`, `-y/--yes`.

See [OPERATIONS.md](OPERATIONS.md#backups) for the output layout and restore commands.

## Security Features

- **Execute-only directory permissions (710)** - Prevents directory enumeration while allowing traversal
- **SSH hardening** - Root login disabled, password authentication disabled, key-only access
- **PostgreSQL peer authentication** - No passwords in config files, OS-level authentication
- **Redis security** - Localhost-only binding, dangerous commands disabled, password authentication
- **Nginx security headers** - X-Frame-Options, X-Content-Type-Options, Referrer-Policy, etc.
- **Rate limiting** - 10 requests/second per IP with burst allowance
- **Automatic security updates** - Unattended-upgrades configured
- **SSL/TLS ready** - Prepared for Let's Encrypt with Certbot

## Directory Structure

```
/home/deploy/
├── .rbenv/              # Ruby version manager
├── .ssh/                # SSH keys (700)
├── .bashrc              # Shell config (600)
├── .profile             # Shell config (600)
└── apps/
    └── myapp/
        ├── current      -> releases/[timestamp]
        ├── releases/    # Capistrano releases
        ├── repo/        # Git repository
        └── shared/      # Persistent files (710)
            ├── config/
            │   └── credentials/
            │       └── production.key (600)
            ├── log/
            ├── tmp/
            └── public/
```

## File Permissions Strategy

The scripts implement **execute-only group permissions** for enhanced security:

- **710 on directories** - Owner has full access, group can traverse but not list contents, no world access
- **600 on sensitive files** - Owner-only access for credentials, shell configs
- **www-data in deploy group** - Nginx/Passenger can access app files via group membership

This prevents directory enumeration attacks while allowing legitimate access to known paths.

## Capistrano Integration

Configure `config/deploy.rb`:
```ruby
set :application, "myapp"
set :repo_url, "git@github.com:username/myapp.git"
set :deploy_to, "/home/deploy/apps/myapp"

# Sidekiq (if using)
set :init_system, :systemd
set :sidekiq_service_unit_name, "sidekiq-myapp"
set :sidekiq_role, :app
```

Add to `Capfile`:
```ruby
require "capistrano/rbenv"
require "capistrano/rails"
require "capistrano/passenger"
require "capistrano/sidekiq"  # if using Sidekiq
```

## Password Requirements

| Password | Minimum | Why |
|---|---|---|
| `deploy` sudo password | 20 characters | Used only at a local/console `sudo` prompt — SSH password login is disabled. Store in a password manager. Generate with `openssl rand -base64 20`. |
| Redis `AUTH` password | 32 characters | Redis processes millions of `AUTH` commands per second locally; short passwords are brute-forceable from a compromised process. The script auto-generates `openssl rand -base64 32` (44 chars) — use that unless you have a reason to supply your own. Avoid whitespace and shell-special characters (`"`, `'`, `$`, `` ` ``). |

## Requirements

- Ubuntu 24.04 LTS
- Root or sudo access
- SSH key-based authentication recommended

## Post-Setup

After running the scripts, complete these manual steps:

1. **Point your domain to the server** (update DNS A record to server IP)

2. **Setup SSL with Let's Encrypt** (Certbot is already installed):
   ```bash
   sudo certbot --nginx -d yourdomain.com
   ```

3. **Configure deploy user sudoers** (for Sidekiq management via Capistrano):
   ```bash
   echo 'deploy ALL=(ALL) NOPASSWD: /bin/systemctl start sidekiq-*, /bin/systemctl stop sidekiq-*, /bin/systemctl restart sidekiq-*, /bin/systemctl reload sidekiq-*, /bin/systemctl status sidekiq-*' | sudo tee /etc/sudoers.d/deploy-sidekiq
   sudo chmod 440 /etc/sudoers.d/deploy-sidekiq
   ```

**Note:** The firewall (UFW) is already enabled by `ruby_vps.sh`, and the credentials directory is created by `setup_rails_app.sh` (you'll be prompted for the key during setup).

## Security Audit

Run a security audit on your VPS:
```bash
ssh deploy@your-server

# Check file permissions
ls -la /home/deploy/
ls -la /home/deploy/apps/myapp/

# Check services
systemctl status nginx passenger redis-server postgresql
systemctl status sidekiq-myapp  # if using Sidekiq

# Check network bindings (PostgreSQL and Redis should be localhost-only)
ss -tlnp | grep -E "(5432|6379)"

# Check firewall
sudo ufw status verbose
```

## Common Issues

**Sidekiq not starting after deployment:**
- Ensure deploy user has limited sudo for systemctl (see Post-Setup #1)
- Check logs: `journalctl -u sidekiq-myapp -n 50`

**Permission denied errors:**
- Verify www-data is in deploy group: `groups www-data`
- Check directory permissions are 710 (execute-only for group)

**Nginx 502 Bad Gateway:**
- Check Passenger is running: `sudo passenger-status`
- Verify Ruby path in Nginx config matches rbenv shims
- Check application logs in `shared/log/production.log`

## License

MIT

## Credits

These scripts were developed with assistance from Claude (Anthropic's AI assistant) to implement security best practices and modern deployment patterns for Ruby on Rails applications.
