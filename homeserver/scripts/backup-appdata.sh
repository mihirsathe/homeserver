#!/bin/bash
# =============================================================================
# backup-appdata.sh — verify local appdata backup + optional offsite copy
#
# This script assumes the Appdata Backup plugin is what actually produces
# the backup archive (configured in the Unraid UI to write to
# /mnt/user/backups/appdata/). All this script does is:
#   1. Sanity-check that a recent backup exists.
#   2. Record its checksum so corruption-on-write is detectable later.
#   3. Copy to an offsite rclone remote (if BACKUP_REMOTE is set).
#   4. Prune local backups older than BACKUP_LOCAL_RETENTION_DAYS.
#   5. Log the outcome.
#
# Schedule via Unraid User Scripts:
#   Settings → User Scripts → media_stack_backup → weekly (Sunday 4am, *after*
#   the Appdata Backup plugin's own schedule).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
BACKUP_DIR="/mnt/user/backups/appdata"
LOG_FILE="/var/log/homeserver/backup.log"
CHECKSUM_DIR="/mnt/user/backups/appdata/.checksums"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

ts() { date +'%Y-%m-%dT%H:%M:%S%z'; }
log() { echo "[$(ts)] $*"; }

log "===== backup-appdata.sh starting ====="

# Pull optional settings from .env. Defaults are used if unset.
BACKUP_LOCAL_RETENTION_DAYS=14
BACKUP_REMOTE=""
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source <(grep -E '^(BACKUP_LOCAL_RETENTION_DAYS|BACKUP_REMOTE)=' "$ENV_FILE" || true); set +a
fi

# Checked BEFORE anything creates it. `mkdir -p "$CHECKSUM_DIR"` used to run
# above this, which made the guard unreachable — and on Unraid, creating
# /mnt/user/backups also creates a SHARE, with default settings the operator
# never asked for. Fail on the real cause instead.
if [[ ! -d "$BACKUP_DIR" ]]; then
    log "ERROR: $BACKUP_DIR does not exist. Is Appdata Backup configured?"
    exit 1
fi
mkdir -p "$CHECKSUM_DIR"

# Find the newest backup archive. Appdata Backup writes dated directories
# containing tarballs; we look for either pattern rather than assuming one.
latest=$(find "$BACKUP_DIR" -maxdepth 2 \( -name '*.tar.gz' -o -name '*.tar.zst' -o -name '*.tar' \) \
             -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | awk '{print $2}')

if [[ -z "${latest:-}" ]]; then
    log "ERROR: no backup archives found under $BACKUP_DIR"
    exit 1
fi

# Freshness gate: a backup more than 26h old means Appdata Backup didn't run.
mtime=$(stat -c '%Y' "$latest")
age_h=$(( ( $(date +%s) - mtime ) / 3600 ))
log "Newest backup: $latest (age ${age_h}h)"
if (( age_h > 26 )); then
    log "ERROR: newest backup is older than 26h — Appdata Backup likely didn't run."
    exit 1
fi

# The plugin writes a DATED DIRECTORY containing one tarball per container, so
# `$latest` is one of many. Everything below therefore works on the directory.
latest_dir=$(dirname "$latest")
stamp=$(basename "$latest_dir")
log "Backup set: $latest_dir ($(find "$latest_dir" -maxdepth 1 -name '*.tar*' | wc -l) archives)"

# Checksum + compare-to-previous to catch corruption-on-write. Store only the
# hash, not a copy of the archive.
#
# Keyed by <stamp>/<archive>, matching where the archive actually lives. The old
# key was just the basename at depth 1, which (a) collided across every dated
# directory, since they all contain the same filenames, and (b) made the orphan
# prune below reconstruct a path that never exists — so it deleted every
# checksum in the same run that wrote it, and nothing was ever compared.
mkdir -p "$CHECKSUM_DIR/$stamp"
for a in "$latest_dir"/*.tar*; do
    [[ -f "$a" ]] || continue
    hash_file="$CHECKSUM_DIR/$stamp/$(basename "$a").sha256"
    if [[ -f "$hash_file" ]]; then
        # Now that hashes survive, actually COMPARE rather than just skipping.
        if sha256sum -c --status <<<"$(cat "$hash_file")  $a"; then
            log "  verified $(basename "$a")"
        else
            log "ERROR: $(basename "$a") CHANGED since its checksum was recorded — corruption on disk?"
            exit 1
        fi
    else
        sha256sum "$a" | awk '{print $1}' > "$hash_file"
        log "  recorded $(basename "$a") $(cat "$hash_file")"
    fi
done

# Offsite copy — only if the user configured a remote. Skip cleanly otherwise.
if [[ -n "$BACKUP_REMOTE" ]]; then
    if ! command -v rclone >/dev/null 2>&1; then
        log "WARN: BACKUP_REMOTE is set but rclone is not installed. Skipping offsite."
    else
        # The whole dated set, into its own remote prefix.
        #
        # This used to be `rclone copy "$latest" "$BACKUP_REMOTE"`, which
        # uploaded ONE arbitrary tarball out of the set — whichever the plugin
        # wrote last — and landed it under its bare basename. Since basenames
        # repeat every week, each run also OVERWROTE the previous upload, so
        # offsite retention was one file and a corrupt archive destroyed the
        # last good copy. --progress is dropped: there is no TTY under cron.
        log "Syncing $latest_dir → $BACKUP_REMOTE/$stamp"
        if rclone copy "$latest_dir" "$BACKUP_REMOTE/$stamp" --stats=60s; then
            log "Offsite copy succeeded."
        else
            log "ERROR: rclone copy returned non-zero. Local backup retained."
            exit 1
        fi
    fi
else
    log "BACKUP_REMOTE unset — skipping offsite copy (local only)."
fi

# Prune local backups older than retention. The Appdata Backup plugin has its
# own retention but defaults are often too short. This is a safety net on top.
log "Pruning local archives older than ${BACKUP_LOCAL_RETENTION_DAYS}d"
find "$BACKUP_DIR" -maxdepth 2 \( -name '*.tar.gz' -o -name '*.tar.zst' -o -name '*.tar' \) \
    -mtime +"$BACKUP_LOCAL_RETENTION_DAYS" -print -delete || true
# Orphaned checksum files — remove hashes whose archive no longer exists.
find "$CHECKSUM_DIR" -mindepth 2 -maxdepth 2 -name '*.sha256' | while read -r hf; do
    archive="$BACKUP_DIR/$(basename "$(dirname "$hf")")/$(basename "$hf" .sha256)"
    [[ -f "$archive" ]] || { rm -f "$hf"; log "Pruned orphaned checksum: $(basename "$hf")"; }
done
find "$CHECKSUM_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true

log "===== backup complete ====="
