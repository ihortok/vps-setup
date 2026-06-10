# VPS Operations Guide

Quick reference for common server management tasks.

---

## fail2ban Commands

### Check Status

```bash
# Show all active jails
sudo fail2ban-client status

# Show detailed status of nginx-limit-req jail
sudo fail2ban-client status nginx-limit-req

# Show SSH jail status
sudo fail2ban-client status sshd

# Show nginx-http-auth jail status
sudo fail2ban-client status nginx-http-auth
```

### View Logs

```bash
# View recent fail2ban activity (last 50 lines)
sudo journalctl -u fail2ban -n 50

# Follow fail2ban logs in real-time
sudo journalctl -u fail2ban -f

# View logs from last hour
sudo journalctl -u fail2ban --since "1 hour ago"

# View the main log file
sudo tail -50 /var/log/fail2ban.log

# Follow log file in real-time
sudo tail -f /var/log/fail2ban.log

# Search for ban actions
sudo grep "Ban" /var/log/fail2ban.log

# Search for specific IP
sudo grep "1.2.3.4" /var/log/fail2ban.log
```

### Manage Bans

```bash
# Unban a specific IP from all jails
sudo fail2ban-client unban 1.2.3.4

# Unban from specific jail
sudo fail2ban-client set nginx-limit-req unbanip 1.2.3.4

# Get banned IP list for a jail
sudo fail2ban-client get nginx-limit-req banip

# Ban an IP manually
sudo fail2ban-client set nginx-limit-req banip 1.2.3.4
```

### Configuration

```bash
# Reload fail2ban configuration
sudo fail2ban-client reload

# Restart fail2ban service
sudo systemctl restart fail2ban

# Check fail2ban version
sudo fail2ban-client version

# Edit jail configuration
sudo nano /etc/fail2ban/jail.local

# Test configuration syntax
sudo fail2ban-client -t
```

### Monitoring

```bash
# Watch fail2ban status (updates every 2 seconds)
watch -n 2 'sudo fail2ban-client status'

# Watch nginx-limit-req jail specifically
watch -n 2 'sudo fail2ban-client status nginx-limit-req'

# Show all ban/unban actions today
sudo journalctl -u fail2ban --since today | grep -E "Ban|Unban"

# Count bans by jail today
sudo journalctl -u fail2ban --since today | grep "Ban" | cut -d' ' -f6 | sort | uniq -c
```

---

## UFW (Firewall) Commands

### Check Status

```bash
# Show firewall status and rules
sudo ufw status

# Show detailed firewall status with rule numbers
sudo ufw status numbered

# Show verbose status with logging level
sudo ufw status verbose

# Check if UFW is enabled
sudo systemctl status ufw

# Show UFW version
sudo ufw version
```

### Managing Basic Rules

```bash
# Allow a specific port
sudo ufw allow 8080

# Allow a port with protocol
sudo ufw allow 8080/tcp
sudo ufw allow 53/udp

# Allow a service by name (from /etc/services)
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https

# Deny a port
sudo ufw deny 23

# Delete a rule by port
sudo ufw delete allow 8080

# Delete a rule by number (use 'status numbered' first)
sudo ufw delete 3

# Delete a rule by specification
sudo ufw delete allow 80/tcp
```

### Port Ranges

```bash
# Allow a range of ports
sudo ufw allow 6000:6007/tcp
sudo ufw allow 6000:6007/udp

# Allow specific protocol only
sudo ufw allow proto tcp from any to any port 80,443

# Delete port range rule
sudo ufw delete allow 6000:6007/tcp
```

### IP-Based Rules

```bash
# Allow from specific IP
sudo ufw allow from 203.0.113.4

# Allow from IP to specific port
sudo ufw allow from 203.0.113.4 to any port 22

# Allow from subnet
sudo ufw allow from 192.168.1.0/24

# Allow from subnet to specific port
sudo ufw allow from 192.168.1.0/24 to any port 3306

# Deny from specific IP
sudo ufw deny from 203.0.113.100

# Deny from specific IP to specific port
sudo ufw deny from 203.0.113.100 to any port 80

# Delete IP-based rule
sudo ufw delete allow from 203.0.113.4
```

### Interface-Specific Rules

```bash
# Allow on specific interface
sudo ufw allow in on eth0 to any port 80

# Allow from IP on specific interface
sudo ufw allow in on eth0 from 192.168.1.0/24

# Deny on specific interface
sudo ufw deny in on eth1 to any port 3306
```

### Advanced Rules

```bash
# Allow incoming traffic to specific IP and port
sudo ufw allow to 192.168.1.100 port 25

# Allow from specific IP to specific destination IP/port
sudo ufw allow from 203.0.113.4 to 192.168.1.100 port 22

# Limit connection attempts (rate limiting - max 6 connections per 30 seconds)
sudo ufw limit ssh
sudo ufw limit 22/tcp

# Allow established connections
sudo ufw allow in on eth0 from any to any established

# Route rules (for forwarding)
sudo ufw route allow in on eth0 out on eth1
```

### Default Policies

```bash
# Set default policy for incoming traffic
sudo ufw default deny incoming
sudo ufw default allow incoming
sudo ufw default reject incoming

# Set default policy for outgoing traffic
sudo ufw default allow outgoing
sudo ufw default deny outgoing

# Set default policy for routed traffic
sudo ufw default deny routed
```

### Enable/Disable Firewall

```bash
# Enable firewall (will prompt for confirmation)
sudo ufw enable

# Disable firewall
sudo ufw disable

# Reload firewall rules
sudo ufw reload

# Reset firewall to default settings (WARNING: removes all rules)
sudo ufw reset
```

### Logging

```bash
# Enable logging
sudo ufw logging on

# Disable logging
sudo ufw logging off

# Set logging level (off, low, medium, high, full)
sudo ufw logging low
sudo ufw logging medium
sudo ufw logging high

# View UFW logs
sudo tail -f /var/log/ufw.log

# View UFW logs via journalctl
sudo journalctl -u ufw -f

# Search for blocked connections
sudo grep "\[UFW BLOCK\]" /var/log/ufw.log

# Search for specific IP in logs
sudo grep "203.0.113.4" /var/log/ufw.log
```

### Application Profiles

```bash
# List available application profiles
sudo ufw app list

# Show info about an application profile
sudo ufw app info "Nginx Full"
sudo ufw app info OpenSSH

# Allow application profile
sudo ufw allow "Nginx Full"
sudo ufw allow "OpenSSH"

# Update application profiles
sudo ufw app update OpenSSH

# Delete application rule
sudo ufw delete allow "Nginx Full"
```

### Rule Management

```bash
# Insert rule at specific position
sudo ufw insert 1 allow from 203.0.113.4

# Show raw iptables rules generated by UFW
sudo iptables -L -n -v
sudo ip6tables -L -n -v

# Show UFW rules with rule numbers for easy deletion
sudo ufw status numbered

# Dry run - show what would happen without applying
sudo ufw --dry-run enable
```

### Common Use Cases

```bash
# Allow SSH from specific IP only (recommended for production)
sudo ufw allow from 203.0.113.4 to any port 22
sudo ufw deny 22

# Allow HTTP/HTTPS from anywhere
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'

# Allow PostgreSQL from localhost only
sudo ufw allow from 127.0.0.1 to any port 5432

# Allow Redis from localhost only
sudo ufw allow from 127.0.0.1 to any port 6379

# Rate limit SSH to prevent brute force
sudo ufw limit 22/tcp comment 'SSH rate limit'

# Block specific IP that's attacking
sudo ufw insert 1 deny from 203.0.113.100 comment 'Blocked attacker'
```

### Troubleshooting

```bash
# Check if UFW is blocking legitimate traffic
sudo tail -f /var/log/ufw.log | grep BLOCK

# Temporarily disable UFW to test
sudo ufw disable
# Test your connection
sudo ufw enable

# Check for conflicts with iptables
sudo iptables -L -n
sudo ufw status verbose

# Verify rule order (rules are processed top to bottom)
sudo ufw status numbered

# Reset UFW if rules are broken
sudo ufw disable
sudo ufw reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw enable

# Check UFW service status
sudo systemctl status ufw

# Restart UFW service
sudo systemctl restart ufw
```

### Monitoring

```bash
# Watch UFW logs in real-time
sudo tail -f /var/log/ufw.log

# Count blocked connections
sudo grep -c "\[UFW BLOCK\]" /var/log/ufw.log

# Top blocked IPs
sudo grep "\[UFW BLOCK\]" /var/log/ufw.log | grep -oE "SRC=[0-9.]+" | sort | uniq -c | sort -rn | head -10

# Show blocked connections from last hour
sudo grep "\[UFW BLOCK\]" /var/log/ufw.log | grep "$(date '+%b %e %H')"

# Monitor specific port blocks
sudo grep "\[UFW BLOCK\].*DPT=22" /var/log/ufw.log | tail -20

# Live monitoring of blocked SSH attempts
sudo tail -f /var/log/ufw.log | grep --line-buffered "DPT=22.*BLOCK"
```

### Backup and Restore

```bash
# Backup UFW rules
sudo cp /etc/ufw/user.rules /etc/ufw/user.rules.backup
sudo cp /etc/ufw/user6.rules /etc/ufw/user6.rules.backup

# Export current rules to file
sudo ufw status numbered > ~/ufw-rules-backup.txt

# Restore from backup
sudo cp /etc/ufw/user.rules.backup /etc/ufw/user.rules
sudo cp /etc/ufw/user6.rules.backup /etc/ufw/user6.rules
sudo ufw reload
```

---

## Nginx Logs and Errors

### View Error Logs

```bash
# Read last 200 lines
sudo tail -n 200 /var/log/nginx/error.log

# Read last 200 lines with scrolling (use arrow keys, q to quit)
sudo tail -n 200 /var/log/nginx/error.log | less

# Follow error log in real-time
sudo tail -f /var/log/nginx/error.log

# Show only errors (not warnings)
sudo tail -n 200 /var/log/nginx/error.log | grep "\[error\]"

# Show only critical/emergency
sudo tail -n 200 /var/log/nginx/error.log | grep -E "\[crit\]|\[emerg\]"
```

### View Access Logs

```bash
# Read last 200 lines
sudo tail -n 200 /var/log/nginx/access.log

# Follow access log in real-time
sudo tail -f /var/log/nginx/access.log

# Show 404 errors
sudo tail -n 200 /var/log/nginx/access.log | grep " 404 "

# Show 500 errors
sudo tail -n 200 /var/log/nginx/access.log | grep " 50[0-9] "

# Show requests from specific IP
sudo tail -n 200 /var/log/nginx/access.log | grep "1.2.3.4"
```

### Rate Limiting Analysis

```bash
# Check for rate limiting events
sudo grep "limiting requests" /var/log/nginx/error.log | tail -20

# See which IPs were rate limited
sudo grep "limiting requests" /var/log/nginx/error.log | grep -oE "client: [0-9.]+" | sort | uniq -c

# Check for 429 errors in access log
sudo grep " 429 " /var/log/nginx/access.log | tail -20

# Count rate limiting events
sudo grep -c "limiting requests" /var/log/nginx/error.log

# Show rate limiting with timestamps
sudo grep "limiting requests" /var/log/nginx/error.log | awk '{print $1, $2, $NF}' | tail -20
```

### Traffic Analysis

```bash
# Top 10 IP addresses by request count
sudo awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10

# Top 10 requested URLs
sudo awk '{print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10

# Top 10 user agents
sudo awk -F'"' '{print $6}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10

# HTTP status code distribution
sudo awk '{print $9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn

# Requests per hour (today)
sudo grep "$(date '+%d/%b/%Y')" /var/log/nginx/access.log | awk '{print $4}' | cut -d: -f2 | sort | uniq -c
```

### Configuration Testing

```bash
# Test Nginx configuration syntax
sudo nginx -t

# Test and show configuration
sudo nginx -T

# Reload Nginx after config changes
sudo systemctl reload nginx

# Restart Nginx
sudo systemctl restart nginx

# Check Nginx status
sudo systemctl status nginx
```

### Application-Specific Logs

```bash
# View app access log
sudo tail -f /var/log/nginx/access.log | grep "yourdomain.com"

# View app error log
sudo tail -f /var/log/nginx/error.log | grep "yourdomain.com"

# Check specific app virtual host logs (if configured)
sudo tail -f /var/log/nginx/myapp.access.log
sudo tail -f /var/log/nginx/myapp.error.log
```

### Log Rotation

```bash
# Check log rotation configuration
cat /etc/logrotate.d/nginx

# Manually trigger log rotation
sudo logrotate -f /etc/logrotate.d/nginx

# Check log sizes
sudo du -h /var/log/nginx/*

# List all Nginx logs with sizes
sudo ls -lh /var/log/nginx/
```

### Real-Time Monitoring

```bash
# Watch error log for new entries
sudo tail -f /var/log/nginx/error.log

# Watch access log with grep filter
sudo tail -f /var/log/nginx/access.log | grep --line-buffered " 50[0-9] "

# Monitor both access and error logs simultaneously
sudo tail -f /var/log/nginx/access.log /var/log/nginx/error.log

# Watch rate limiting events live
sudo tail -f /var/log/nginx/error.log | grep --line-buffered "limiting requests"
```

### Save Logs for Analysis

```bash
# Save last 1000 error log entries
sudo tail -n 1000 /var/log/nginx/error.log > nginx_errors.txt

# Save last hour of access logs
sudo grep "$(date '+%d/%b/%Y:%H')" /var/log/nginx/access.log > nginx_access_last_hour.txt

# Save all rate limiting events
sudo grep "limiting requests" /var/log/nginx/error.log > rate_limit_events.txt

# Download logs to local machine
scp deploy@server:/tmp/nginx_errors.txt ./
```

---

## Quick Troubleshooting

### Server is slow or unresponsive

```bash
# Check active connections
sudo netstat -ant | grep :80 | wc -l
sudo netstat -ant | grep :443 | wc -l

# Check Passenger status
sudo passenger-status

# Check system load
uptime
top
htop

# Check disk space
df -h

# Check memory usage
free -h
```

### Too many 429 errors

```bash
# Check current rate limiting
sudo grep "limiting requests" /var/log/nginx/error.log | tail -20

# Check if fail2ban banned legitimate users
sudo fail2ban-client status nginx-limit-req

# Temporarily increase rate limits (edit Nginx config)
sudo nano /etc/nginx/sites-available/yourapp
# Then reload: sudo nginx -t && sudo systemctl reload nginx

# Unban all IPs from rate limit jail
for ip in $(sudo fail2ban-client get nginx-limit-req banip); do
  sudo fail2ban-client set nginx-limit-req unbanip $ip
done
```

### Application not loading

```bash
# Check Nginx is running
sudo systemctl status nginx

# Check Passenger is running
sudo passenger-status

# Check Rails logs
tail -100 /home/deploy/apps/yourapp/shared/log/production.log

# Check Nginx error log
sudo tail -50 /var/log/nginx/error.log

# Restart application
sudo passenger-config restart-app /home/deploy/apps/yourapp/current
```

---

## File Permissions Security

### Expected Permissions Reference

```bash
# Critical security permissions
/home/deploy                        710  drwx--x---  (group can traverse but not list)
/home/deploy/.ssh                   700  drwx------  (owner-only access)
/home/deploy/.ssh/authorized_keys   600  -rw-------  (owner read/write only)
/home/deploy/.ssh/id_*              600  -rw-------  (private keys owner-only)
/home/deploy/.bashrc                600  -rw-------  (owner-only)
/home/deploy/.profile               600  -rw-------  (owner-only)
/home/deploy/.bash_history          600  -rw-------  (owner-only)

# Application directories
/home/deploy/apps                   750  drwxr-x---  (group can traverse)
/home/deploy/apps/myapp             750  drwxr-x---  (group can traverse)
/home/deploy/apps/myapp/current     750  drwxr-x---  (group can traverse)
/home/deploy/apps/myapp/current/public
                                    755  drwxr-xr-x  (Nginx needs read access)

# Shared directories (Passenger write access)
/home/deploy/apps/myapp/shared/log  770  drwxrwx---  (group writable)
/home/deploy/apps/myapp/shared/tmp  770  drwxrwx---  (group writable)
/home/deploy/apps/myapp/shared/pids 770  drwxrwx---  (group writable)

# Credential files
*.key files                         600  -rw-------  (owner-only)
.env files                          600  -rw-------  (owner-only)
master.key                          600  -rw-------  (owner-only)
production.key                      600  -rw-------  (owner-only)

# Development tool directories
/home/deploy/.bundle                700  drwx------  (owner-only)
/home/deploy/.local                 700  drwx------  (owner-only)
/home/deploy/.yarn                  700  drwx------  (owner-only)
/home/deploy/.rbenv                 750  drwxr-x---  (group read-only)
/home/deploy/.passenger             750  drwxr-x---  (NOT 777!)
```

### Check Current Permissions

```bash
# Quick permission check for critical files
stat -c "%a %U:%G %n" /home/deploy
stat -c "%a %U:%G %n" /home/deploy/.ssh
stat -c "%a %U:%G %n" /home/deploy/.ssh/authorized_keys

# Check all important directories
for dir in /home/deploy /home/deploy/.ssh /home/deploy/apps; do
    ls -ld "$dir"
done

# Check for world-writable files (security risk)
find /home/deploy -type f -perm -002 2>/dev/null

# Check for world-readable credential files (security risk)
find /home/deploy/apps -name "*.key" -o -name ".env*" | xargs ls -l 2>/dev/null

# Verify www-data group membership
groups www-data | grep deploy && echo "✓ www-data in deploy group" || echo "✗ Missing"
```

### Fix Incorrect Permissions

```bash
# Run the automated fix script
bash /home/deploy/vps-setup/fix_permissions.sh

# Or fix manually:

# Fix critical home directory (710 = owner full, group execute-only, no world)
chmod 710 /home/deploy

# Fix SSH directory and files
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/*

# Fix shell configs
chmod 600 /home/deploy/.bashrc
chmod 600 /home/deploy/.profile

# Fix CRITICAL security issue: .passenger directory
# (Sometimes created with 777 = world-writable!)
chmod 750 /home/deploy/.passenger

# Fix apps directory
chmod 750 /home/deploy/apps

# Fix specific app permissions
APP_NAME="myapp"
chmod 750 /home/deploy/apps/$APP_NAME
chmod -R u+rwX,g+rX,o-rwx /home/deploy/apps/$APP_NAME/current/public
chmod -R u+rwX,g+rwX,o-rwx /home/deploy/apps/$APP_NAME/shared/log
chmod -R u+rwX,g+rwX,o-rwx /home/deploy/apps/$APP_NAME/shared/tmp

# Fix credential files (CRITICAL - must be owner-only)
find /home/deploy/apps -name "*.key" -exec chmod 600 {} \;
find /home/deploy/apps -name ".env*" -exec chmod 600 {} \;

# Fix development tool directories
for dir in .bundle .local .yarn .cache .npm .gem; do
    [ -d "/home/deploy/$dir" ] && chmod -R u+rwX,g-rwx,o-rwx "/home/deploy/$dir"
done
```

### Common Permission Issues

#### Issue: Nginx returns 403 Forbidden

**Cause:** Incorrect permissions on home or public directory

**Fix:**
```bash
# Ensure group can traverse (execute-only) home directory
chmod 710 /home/deploy

# Ensure public directory is group-readable
chmod -R u+rwX,g+rX,o-rwx /home/deploy/apps/myapp/current/public

# Restart Nginx
sudo systemctl restart nginx
```

#### Issue: Passenger can't write to log files

**Cause:** Shared directories not group-writable

**Fix:**
```bash
# Make shared directories group-writable
chmod -R u+rwX,g+rwX,o-rwx /home/deploy/apps/myapp/shared/log
chmod -R u+rwX,g+rwX,o-rwx /home/deploy/apps/myapp/shared/tmp

# Restart app
sudo passenger-config restart-app /home/deploy/apps/myapp
```

#### Issue: Rails can't decrypt credentials

**Cause:** Incorrect permissions on production.key

**Fix:**
```bash
# Find and fix credential files
find /home/deploy/apps -name "*.key" -exec chmod 600 {} \;
find /home/deploy/apps -name "master.key" -exec chmod 600 {} \;

# Verify
ls -l /home/deploy/apps/myapp/shared/config/credentials/production.key
# Should show: -rw------- 1 deploy deploy
```

#### Issue: Security warning about world-writable files

**Cause:** Files with 777 or similar overly permissive settings

**Fix:**
```bash
# Find world-writable files
find /home/deploy -type f -perm -002

# Fix specific file
chmod 600 /path/to/file

# Fix entire directory tree (be careful!)
chmod -R u+rwX,g-w,o-rwx /home/deploy/apps/myapp
```

### Permission Bits Explanation

```
Permission bits: rwxrwxrwx = 777
                 ││││││└└└─ Others: read, write, execute
                 │││└└└──── Group: read, write, execute
                 └└└─────── Owner: read, write, execute

Common values:
  700 = rwx------ = Owner full, no group/others
  750 = rwxr-x--- = Owner full, group read+execute
  755 = rwxr-xr-x = Owner full, group+others read+execute
  600 = rw------- = Owner read+write only
  644 = rw-r--r-- = Owner read+write, group+others read
  710 = rwx--x--- = Owner full, group execute-only (can traverse but not list)
  770 = rwxrwx--- = Owner+group full, no others
```

### Security Best Practices

1. **Principle of Least Privilege**
   - Only grant minimum permissions needed
   - No world-readable files in home directory
   - Credential files must be 600 (owner-only)

2. **Group-Based Access for Nginx/Passenger**
   - www-data must be in deploy group
   - Home directory: 710 (group can traverse but not list)
   - Public directory: group-readable
   - Log/tmp directories: group-writable

3. **Regular Audits**
   ```bash
   # Run weekly
   bash /home/deploy/vps-setup/fix_permissions.sh

   # Check for security issues
   find /home/deploy -type f -perm -002  # World-writable
   find /home/deploy -type f -perm -004  # World-readable
   ```

4. **After Deployment**
   ```bash
   # Capistrano may create files with incorrect permissions
   # Run after each deploy:
   chmod -R u+rwX,g+rX,o-rwx /home/deploy/apps/myapp/current/public
   chmod -R u+rwX,g+rwX,o-rwx /home/deploy/apps/myapp/shared/log
   chmod 600 /home/deploy/apps/myapp/shared/config/credentials/*.key
   ```

---

## Security Alert Notifications

By default the setup scripts configure fail2ban and unattended-upgrades to log locally only. To receive email alerts follow the steps below.

### fail2ban — email on ban

Install a mail transfer agent (postfix is the simplest on Ubuntu):

```bash
sudo apt-get install -y postfix mailutils
```

Edit `/etc/fail2ban/jail.local` and update the `[DEFAULT]` section:

```ini
destemail = your@email.com
sendername = Fail2Ban-VPS
# action_mwl = ban + send email with whois info and log excerpt
action = %(action_mwl)s
```

Then restart fail2ban:

```bash
sudo systemctl restart fail2ban
```

Test the alert:

```bash
sudo fail2ban-client set sshd banip 127.0.0.2
# Check inbox, then unban:
sudo fail2ban-client set sshd unbanip 127.0.0.2
```

### unattended-upgrades — email on change

Edit `/etc/apt/apt.conf.d/50unattended-upgrades` and add/update these lines:

```
Unattended-Upgrade::Mail "your@email.com";
Unattended-Upgrade::MailReport "on-change";
```

Test with a dry run:

```bash
sudo unattended-upgrade --dry-run --debug 2>&1 | head -30
```

---

## Additional Resources

- [Nginx Documentation](https://nginx.org/en/docs/)
- [fail2ban Wiki](https://github.com/fail2ban/fail2ban/wiki)
- [Passenger Documentation](https://www.phusionpassenger.com/docs/)
- [Linux File Permissions](https://wiki.archlinux.org/title/File_permissions_and_attributes)
