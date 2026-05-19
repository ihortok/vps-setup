# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A small set of bash scripts that provision and harden an Ubuntu 22.04 VPS for hosting Ruby on Rails apps behind Nginx + Phusion Passenger, with PostgreSQL, Redis, and optional Sidekiq. There is no application code, no test suite, and no build — just shell scripts and Markdown reference docs. All scripts are designed to run **on the target VPS** (not locally) and are idempotent.

## Files

- `ruby_vps.sh` — one-time host setup: rbenv/Ruby, Node/Yarn, PostgreSQL, Redis, Nginx + Passenger, UFW, fail2ban, unattended-upgrades, SSH hardening, baseline permissions.
- `setup_rails_app.sh APP_NAME DOMAIN [OPTIONS]` — per-app provisioning: directory tree, PostgreSQL DB, Nginx vhost, optional Certbot SSL (`--request-ssl`) and Sidekiq systemd unit (`--setup-sidekiq`). DB name defaults to `${APP_NAME}_production`.
- `fix_permissions.sh` — idempotent re-audit/fix of all expected permissions on an existing install. Safe to re-run anytime, including after a Capistrano deploy.
- `check_file_permissions.sh` — read-only audit reporting actual vs. expected permissions; makes no changes.
- `OPERATIONS.md` — day-2 reference (fail2ban, UFW, Nginx logs, permission troubleshooting). Consult this before inventing commands for those topics.
- `README.md` — user-facing overview and the canonical source for the Capistrano `deploy.rb` / `Capfile` snippets.

## Execution order and preconditions

`ruby_vps.sh` aborts if not run as `deploy` with passwordless sudo. The header comment block lists the manual root steps that must happen first (create `deploy` user, add to `sudo`, copy `authorized_keys`, then SSH back in as `deploy`). Always read those steps before changing the user-verification logic — they are the contract.

Order: `ruby_vps.sh` once per host → `setup_rails_app.sh` once per app → `fix_permissions.sh` whenever permissions drift (notably after deploys).

## Architecture: how the pieces fit

The security model is the part that requires reading across files to understand. Changes to one script's permission decisions usually require matching changes in the others.

- **Two-user model.** Everything app-related lives under `/home/deploy`. Nginx/Passenger runs as `www-data`, which is added to the `deploy` group. App access flows through group membership, never world bits.
- **Execute-only group traversal (710).** `/home/deploy` is `drwx--x---`: `www-data` can `cd` through it to reach known app paths but cannot `ls` it. This pattern repeats at every level — owner full, group execute-only or read+execute as needed, world nothing. Do not "fix" a 710 to 755 to silence a permission error; the right fix is usually adding `www-data` to the `deploy` group or making a specific subdir group-readable.
- **`.passenger` gotcha.** Passenger sometimes creates `~/.passenger` as 777 during install. `ruby_vps.sh` and `fix_permissions.sh` both explicitly clamp it to 750. Preserve that — it is the single most important non-obvious permission fix in the repo.
- **PostgreSQL uses peer authentication.** No DB passwords are stored in config. `setup_rails_app.sh` creates the role to match the OS user, so Rails connects via Unix socket as `deploy`. Do not introduce password-based auth without coordinating across the Nginx config, `database.yml` expectations, and the role creation step.
- **Redis is localhost-only with a password and dangerous commands renamed/disabled.** Binding and ACL are set in `ruby_vps.sh`; UFW does not need to expose 6379. Same pattern for Postgres on 5432.
- **Nginx vhosts are generated per-app** by `setup_rails_app.sh` and include the rate-limiting `limit_req` directive (zone defined globally in `ruby_vps.sh` at 50 req/sec per IP — see the most recent commit for current tuning). fail2ban's `nginx-limit-req` jail watches the resulting 429s.
- **Sidekiq lifecycle is delegated to systemd**, with one unit per app (`sidekiq-${APP_NAME}.service`). Capistrano restarts it via a narrow NOPASSWD sudoers rule for `systemctl {start,stop,restart,reload,status} sidekiq-*` — the rule is documented in `README.md` under Post-Setup and is **not** installed by the scripts; it is a manual one-time step.

## Conventions when editing these scripts

- Keep everything idempotent. Every install/config block should check current state (`command_exists`, `grep` the config, `systemctl is-enabled`, etc.) before acting. Re-running a script must be a no-op when the system is already in the desired state.
- Use the existing `log_info` / `log_success` / `log_warning` / `log_error` helpers and `set -euo pipefail` — every script does, and they are how operators read script output during a long run.
- `OPERATIONS.md` is the operator-facing source of truth for day-2 commands. If you change a path, port, jail name, or service name, update `OPERATIONS.md` in the same change.
- Expected permissions are documented in `OPERATIONS.md` under "Expected Permissions Reference" and enforced by `fix_permissions.sh` / audited by `check_file_permissions.sh`. Keep all three in sync when changing any expected mode.
