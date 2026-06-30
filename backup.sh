#!/bin/bash
################################################################################
# Backup Script for Rails apps on Ubuntu 24.04 VPS
################################################################################
#
# Backs up the two pieces of state that cannot be re-provisioned from the
# setup scripts:
#   1. PostgreSQL databases owned by the deploy role (the *_production app DBs)
#   2. Per-app Active Storage folders (apps/<app>/shared/storage)
#
# It detects what is available, lets you interactively choose what to back up
# (or accepts flags for non-interactive runs), writes everything into
# /home/deploy/backup_YYYY_MM_DD/, then archives that folder to .tar.gz.
#
# Prerequisites:
# - Must be run as the deploy user (not root)
# - PostgreSQL peer authentication (the default from ruby_vps.sh) so that
#   `pg_dump -d <db>` works over the unix socket with no password
#
# Usage:
#   ./backup.sh [OPTIONS]
#
# Options:
#   --all                Back up every detected DB and storage folder (no prompts)
#   --dbs "a,b"          Comma/space-separated DB names to back up (no prompt)
#   --storage "a,b"      Comma/space-separated app names whose storage to back up
#   --output-dir DIR     Parent dir for the backup folder (default: /home/deploy)
#   --no-archive         Leave the plain backup_DATE/ folder, skip the .tar.gz step
#   --keep-folder        Keep the working folder after a successful archive
#   -y, --yes            Skip the final confirmation prompt
#   -h, --help           Show this help and exit
#
# Examples:
#   ./backup.sh
#   ./backup.sh --all
#   ./backup.sh --dbs wallet_production --storage wallet -y
#
# This script makes no changes to the host; it only reads DBs/files and writes
# the backup. Restore instructions live in OPERATIONS.md.
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

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all                Back up every detected DB and storage folder (no prompts)"
    echo "  --dbs \"a,b\"          Comma/space-separated DB names to back up (no prompt)"
    echo "  --storage \"a,b\"      Comma/space-separated app names whose storage to back up"
    echo "  --output-dir DIR     Parent dir for the backup folder (default: /home/deploy)"
    echo "  --no-archive         Leave the plain backup_DATE/ folder, skip the .tar.gz step"
    echo "  --keep-folder        Keep the working folder after a successful archive"
    echo "  -y, --yes            Skip the final confirmation prompt"
    echo "  -h, --help           Show this help and exit"
}

# Prints a numbered menu (to stderr) for the given items, reads a selection from
# the controlling terminal, and echoes the chosen 1-based indices (space
# separated) to stdout. Accepts 'all', 'none'/empty, or space/comma-separated
# numbers. Re-prompts on invalid input. Always returns 0.
select_indices() {
    local title="$1"
    shift
    local items=("$@")
    local count=${#items[@]}
    local i

    {
        echo ""
        echo "$title"
        for ((i = 0; i < count; i++)); do
            printf "  %2d) %s\n" "$((i + 1))" "${items[$i]}"
        done
        echo "  Enter numbers (e.g. '1 3 4' or '1,3,4'), 'all', or 'none'."
    } >&2

    local raw tok ok seen out all_idx
    while true; do
        printf "> " >&2
        if ! read -r raw </dev/tty; then
            raw="none"
        fi
        # Normalize: commas -> spaces, collapse/trim whitespace
        raw="$(echo "$raw" | tr ',' ' ' | xargs || true)"
        case "$raw" in
            "" | [Nn][Oo][Nn][Ee])
                echo ""
                return 0
                ;;
            [Aa][Ll][Ll])
                all_idx=""
                for ((i = 1; i <= count; i++)); do
                    all_idx="$all_idx $i"
                done
                echo "${all_idx# }"
                return 0
                ;;
        esac
        ok=true
        for tok in $raw; do
            if ! [[ "$tok" =~ ^[0-9]+$ ]] || ((tok < 1 || tok > count)); then
                echo "  Invalid entry: '$tok'. Please try again." >&2
                ok=false
                break
            fi
        done
        if $ok; then
            # De-duplicate while preserving order
            seen=" "
            out=""
            for tok in $raw; do
                case "$seen" in
                    *" $tok "*) continue ;;
                esac
                out="$out $tok"
                seen="$seen$tok "
            done
            echo "${out# }"
            return 0
        fi
    done
}

################################################################################
# Parse Arguments
################################################################################

DEPLOY_USER="deploy"
OUTPUT_DIR="/home/$DEPLOY_USER"
DO_ALL=false
NO_ARCHIVE=false
KEEP_FOLDER=false
ASSUME_YES=false
DBS_ARG=""
STORAGE_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            DO_ALL=true
            shift
            ;;
        --dbs)
            DBS_ARG="$2"
            shift 2
            ;;
        --storage)
            STORAGE_ARG="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --no-archive)
            NO_ARCHIVE=true
            shift
            ;;
        --keep-folder)
            KEEP_FOLDER=true
            shift
            ;;
        -y | --yes)
            ASSUME_YES=true
            shift
            ;;
        -h | --help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

################################################################################
# Verify Environment
################################################################################

CURRENT_USER=$(whoami)
if [ "$CURRENT_USER" != "$DEPLOY_USER" ]; then
    log_error "This script must be run as the '$DEPLOY_USER' user, not '$CURRENT_USER'."
    exit 1
fi

if ! command_exists psql || ! command_exists pg_dump; then
    log_error "psql/pg_dump not found. Is PostgreSQL installed (run ruby_vps.sh first)?"
    exit 1
fi

OUTPUT_DIR="${OUTPUT_DIR%/}"
if [ ! -d "$OUTPUT_DIR" ] || [ ! -w "$OUTPUT_DIR" ]; then
    log_error "Output directory '$OUTPUT_DIR' does not exist or is not writable."
    exit 1
fi

log_success "Running as $DEPLOY_USER user"

################################################################################
# Detect PostgreSQL databases (deploy-owned, via peer authentication)
################################################################################

if ! psql -tAc "SELECT 1" >/dev/null 2>&1; then
    log_error "Cannot connect to PostgreSQL as '$DEPLOY_USER' over the unix socket."
    exit 1
fi

DETECTED_DBS=()
mapfile -t DETECTED_DBS < <(psql -tAc \
    "SELECT d.datname FROM pg_database d
       JOIN pg_roles r ON d.datdba = r.oid
      WHERE d.datistemplate = false
        AND r.rolname = '$DEPLOY_USER'
      ORDER BY d.datname;")

if [ ${#DETECTED_DBS[@]} -eq 0 ]; then
    log_warning "No PostgreSQL databases owned by '$DEPLOY_USER' were found."
else
    log_info "Detected ${#DETECTED_DBS[@]} deploy-owned database(s)."
fi

################################################################################
# Detect per-app storage folders
################################################################################

APPS_DIR="/home/$DEPLOY_USER/apps"
DETECTED_APPS=()
DETECTED_STORAGE_PATHS=()
STORAGE_LABELS=()

if [ -d "$APPS_DIR" ]; then
    shopt -s nullglob
    for app_path in "$APPS_DIR"/*/; do
        app="$(basename "$app_path")"
        storage="${app_path}shared/storage"
        [ -d "$storage" ] || continue
        size="$(du -sh "$storage" 2>/dev/null | cut -f1)"
        [ -z "$size" ] && size="?"
        DETECTED_APPS+=("$app")
        DETECTED_STORAGE_PATHS+=("$storage")
        STORAGE_LABELS+=("$app  →  $storage  ($size)")
    done
    shopt -u nullglob
fi

if [ ${#DETECTED_APPS[@]} -eq 0 ]; then
    log_warning "No app storage folders found under $APPS_DIR."
else
    log_info "Detected ${#DETECTED_APPS[@]} app storage folder(s)."
fi

################################################################################
# Resolve selections
################################################################################

SELECTED_DBS=()
SELECTED_APPS=()
SELECTED_STORAGE_PATHS=()

if $DO_ALL; then
    if [ ${#DETECTED_DBS[@]} -gt 0 ]; then
        SELECTED_DBS=("${DETECTED_DBS[@]}")
    fi
    if [ ${#DETECTED_APPS[@]} -gt 0 ]; then
        SELECTED_APPS=("${DETECTED_APPS[@]}")
        SELECTED_STORAGE_PATHS=("${DETECTED_STORAGE_PATHS[@]}")
    fi
elif [ -n "$DBS_ARG" ] || [ -n "$STORAGE_ARG" ]; then
    # Non-interactive: validate requested names against the detected sets
    if [ -n "$DBS_ARG" ]; then
        for name in $(echo "$DBS_ARG" | tr ',' ' '); do
            found=false
            if [ ${#DETECTED_DBS[@]} -gt 0 ]; then
                for d in "${DETECTED_DBS[@]}"; do
                    if [ "$d" = "$name" ]; then
                        found=true
                        break
                    fi
                done
            fi
            if $found; then
                SELECTED_DBS+=("$name")
            else
                log_error "Requested database not found among deploy-owned DBs: $name"
                exit 1
            fi
        done
    fi
    if [ -n "$STORAGE_ARG" ]; then
        for name in $(echo "$STORAGE_ARG" | tr ',' ' '); do
            idx=-1
            if [ ${#DETECTED_APPS[@]} -gt 0 ]; then
                for i in "${!DETECTED_APPS[@]}"; do
                    if [ "${DETECTED_APPS[$i]}" = "$name" ]; then
                        idx=$i
                        break
                    fi
                done
            fi
            if [ "$idx" -ge 0 ]; then
                SELECTED_APPS+=("$name")
                SELECTED_STORAGE_PATHS+=("${DETECTED_STORAGE_PATHS[$idx]}")
            else
                log_error "Requested app storage not found: $name"
                exit 1
            fi
        done
    fi
else
    # Interactive menus
    if [ ${#DETECTED_DBS[@]} -gt 0 ]; then
        chosen="$(select_indices "PostgreSQL databases to back up:" "${DETECTED_DBS[@]}")"
        for idx in $chosen; do
            SELECTED_DBS+=("${DETECTED_DBS[$((idx - 1))]}")
        done
    fi
    if [ ${#DETECTED_APPS[@]} -gt 0 ]; then
        chosen="$(select_indices "App storage folders to back up:" "${STORAGE_LABELS[@]}")"
        for idx in $chosen; do
            SELECTED_APPS+=("${DETECTED_APPS[$((idx - 1))]}")
            SELECTED_STORAGE_PATHS+=("${DETECTED_STORAGE_PATHS[$((idx - 1))]}")
        done
    fi
fi

if [ ${#SELECTED_DBS[@]} -eq 0 ] && [ ${#SELECTED_APPS[@]} -eq 0 ]; then
    log_warning "Nothing selected; nothing to back up."
    exit 0
fi

################################################################################
# Confirm
################################################################################

echo ""
echo "========================================================================"
echo "The following will be backed up:"
echo "========================================================================"
if [ ${#SELECTED_DBS[@]} -gt 0 ]; then
    echo "  Databases:"
    for db in "${SELECTED_DBS[@]}"; do
        echo "    - $db"
    done
fi
if [ ${#SELECTED_APPS[@]} -gt 0 ]; then
    echo "  Storage folders:"
    for i in "${!SELECTED_APPS[@]}"; do
        echo "    - ${SELECTED_APPS[$i]}  (${SELECTED_STORAGE_PATHS[$i]})"
    done
fi
echo ""

if ! $ASSUME_YES; then
    printf "Proceed? [y/N] " >&2
    if ! read -r confirm </dev/tty; then
        confirm="n"
    fi
    case "$confirm" in
        [Yy] | [Yy][Ee][Ss]) ;;
        *)
            log_warning "Aborted by user."
            exit 0
            ;;
    esac
fi

################################################################################
# Create backup folder (same-day collision guard)
################################################################################

STAMP="$(date +%Y_%m_%d)"
BACKUP_NAME="backup_${STAMP}"
BACKUP_DIR="${OUTPUT_DIR}/${BACKUP_NAME}"
if [ -e "$BACKUP_DIR" ] || [ -e "${BACKUP_DIR}.tar.gz" ]; then
    BACKUP_NAME="backup_${STAMP}_$(date +%H%M%S)"
    BACKUP_DIR="${OUTPUT_DIR}/${BACKUP_NAME}"
    log_warning "A backup for today already exists; using $BACKUP_NAME instead."
fi

mkdir -p "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"
[ ${#SELECTED_DBS[@]} -gt 0 ] && mkdir -p "$BACKUP_DIR/databases"
[ ${#SELECTED_APPS[@]} -gt 0 ] && mkdir -p "$BACKUP_DIR/storage"
log_info "Writing backup to $BACKUP_DIR"

################################################################################
# Dump databases
################################################################################

DB_FAILURES=()
if [ ${#SELECTED_DBS[@]} -gt 0 ]; then
    for db in "${SELECTED_DBS[@]}"; do
        out="$BACKUP_DIR/databases/${db}.sql"
        log_info "Dumping database '$db'..."
        if pg_dump --no-owner --no-privileges --clean --if-exists -d "$db" -f "$out"; then
            chmod 600 "$out"
            log_success "Dumped database: $db"
        else
            log_error "pg_dump failed for '$db' (continuing with remaining items)"
            rm -f "$out"
            DB_FAILURES+=("$db")
        fi
    done
fi

################################################################################
# Copy storage folders
################################################################################

STORAGE_FAILURES=()
if [ ${#SELECTED_APPS[@]} -gt 0 ]; then
    for i in "${!SELECTED_APPS[@]}"; do
        app="${SELECTED_APPS[$i]}"
        src="${SELECTED_STORAGE_PATHS[$i]}"
        dest="$BACKUP_DIR/storage/$app"
        log_info "Copying storage for '$app'..."
        mkdir -p "$dest"
        if cp -a "$src/." "$dest/"; then
            log_success "Copied storage: $app"
        else
            log_error "Failed to copy storage for '$app' (continuing)"
            STORAGE_FAILURES+=("$app")
        fi
    done
fi

################################################################################
# Write manifest
################################################################################

{
    echo "VPS backup"
    echo "Created:  $(date -Is)"
    echo "Host:     $(hostname)"
    echo "By user:  $DEPLOY_USER"
    echo ""
    if [ ${#SELECTED_DBS[@]} -gt 0 ]; then
        echo "Databases (plain SQL; pg_dump --clean --if-exists --no-owner --no-privileges):"
        for db in "${SELECTED_DBS[@]}"; do
            echo "  - databases/${db}.sql"
        done
        echo ""
    fi
    if [ ${#SELECTED_APPS[@]} -gt 0 ]; then
        echo "Storage folders (cp -a of apps/<app>/shared/storage):"
        for app in "${SELECTED_APPS[@]}"; do
            echo "  - storage/${app}/"
        done
        echo ""
    fi
    echo "Restore hints (run as $DEPLOY_USER):"
    echo "  Database: createdb -O $DEPLOY_USER <db>   # only if it does not exist yet"
    echo "            psql -d <db> -f databases/<db>.sql"
    echo "  Storage:  cp -a storage/<app>/. /home/$DEPLOY_USER/apps/<app>/shared/storage/"
    echo "            then run: bash fix_permissions.sh"
} >"$BACKUP_DIR/MANIFEST.txt"
chmod 600 "$BACKUP_DIR/MANIFEST.txt"

################################################################################
# Archive
################################################################################

ARCHIVE=""
if $NO_ARCHIVE; then
    log_info "Skipping archive step (--no-archive). Backup left at: $BACKUP_DIR"
elif command_exists tar; then
    ARCHIVE="${BACKUP_DIR}.tar.gz"
    (cd "$OUTPUT_DIR" && tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME")
    chmod 600 "$ARCHIVE"
    log_success "Archive created: $ARCHIVE"
    if ! $KEEP_FOLDER; then
        rm -rf "$BACKUP_DIR"
        log_info "Removed working folder (use --keep-folder to retain it)."
    fi
else
    log_warning "'tar' not found; leaving uncompressed folder at: $BACKUP_DIR"
fi

################################################################################
# Summary
################################################################################

echo ""
echo "========================================================================"
echo "Backup complete"
echo "========================================================================"
if [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ]; then
    echo "  Archive: $ARCHIVE ($(du -sh "$ARCHIVE" 2>/dev/null | cut -f1))"
else
    echo "  Folder:  $BACKUP_DIR"
fi

TOTAL_SELECTED=$((${#SELECTED_DBS[@]} + ${#SELECTED_APPS[@]}))
TOTAL_FAILURES=$((${#DB_FAILURES[@]} + ${#STORAGE_FAILURES[@]}))

if [ "$TOTAL_FAILURES" -gt 0 ]; then
    echo ""
    log_warning "$TOTAL_FAILURES of $TOTAL_SELECTED item(s) failed:"
    if [ ${#DB_FAILURES[@]} -gt 0 ]; then
        for db in "${DB_FAILURES[@]}"; do
            echo "    - database: $db"
        done
    fi
    if [ ${#STORAGE_FAILURES[@]} -gt 0 ]; then
        for app in "${STORAGE_FAILURES[@]}"; do
            echo "    - storage:  $app"
        done
    fi
    # Exit non-zero only if everything failed, so automation notices a total failure
    if [ "$TOTAL_FAILURES" -eq "$TOTAL_SELECTED" ]; then
        log_error "All selected items failed."
        exit 1
    fi
fi

log_success "Done."
