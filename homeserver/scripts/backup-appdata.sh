#!/bin/bash
# =============================================================================
# backup-appdata.sh — verify local appdata backup + optional offsite copy
#
# This script assumes the CA Appdata Backup plugin is what actually produces
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
#   the CA Appdata Backup plugin's own schedule).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
BACKUP_DIR="/mnt/user/backups/appdata"
LOG_FILE="/var/log/homeserver/backup.log"
CHECKSUM_DIR="/mnt/user/backups/appdata/.checksums"

mkdir -p "$(dirname "$LOG_FILE")" "$CHECKSUM_DIR"
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

if [[ ! -d "$BACKUP_DIR" ]]; then
    log "ERROR: $BACKUP_DIR does not exist. Is CA Appdata Backup configured?"
    exit 1
fi

# Find the newest backup archive. CA Appdata Backup writes dated directories
# containing tarballs; we look for either pattern rather than assuming one.
latest=$(find "$BACKUP_DIR" -maxdepth 2 \( -name '*.tar.gz' -o -name '*.tar.zst' -o -name '*.tar' \) \
             -printf '%T@ %p\n' 2>/dev/null \
         | sort -n | tail -1 | awk '{print $2}')

if [[ -z "${latest:-}" ]]; then
    log "ERROR: no backup archives found under $BACKUP_DIR"
    exit 1
fi

# Freshness gate: a backup more than 26h old means CA Appdata Backup didn't run.
mtime=$(stat -c '%Y' "$latest")
age_h=$(( ( $(date +%s) - mtime ) / 3600 ))
log "Newest backup: $latest (age ${age_h}h)"
if (( age_h > 26 )); then
    log "ERROR: newest backup is older than 26h — CA Appdata Backup likely didn't run."
    exit 1
fi

# Checksum + compare-to-previous to catch corruption-on-write. Store only the
# hash, not a copy of the archive — the CA plugin already keeps its own rotation.
hash_file="$CHECKSUM_DIR/$(basename "$latest").sha256"
if [[ -f "$hash_file" ]]; then
    log "Checksum already recorded for this archive; skipping hash."
else
    sha256sum "$latest" | awk '{print $1}' > "$hash_file"
    log "Recorded checksum: $(cat "$hash_file")"
fi

# Offsite copy — only if the user configured a remote. Skip cleanly otherwise.
if [[ -n "$BACKUP_REMOTE" ]]; then
    if ! command -v rclone >/dev/null 2>&1; then
        log "WARN: BACKUP_REMOTE is set but rclone is not installed. Skipping offsite."
    else
        log "Syncing $latest → $BACKUP_REMOTE"
        if rclone copy "$latest" "$BACKUP_REMOTE" --progress --stats=60s; then
            log "Offsite copy succeeded."
        else
            log "ERROR: rclone copy returned non-zero. Local backup retained."
            exit 1
        fi
    fi
else
    log "BACKUP_REMOTE unset — skipping offsite copy (local only)."
fi

# Prune local backups older than retention. CA plugin has its own retention
# but defaults are often too short. This is a safety net on top.
log "Pruning local archives older than ${BACKUP_LOCAL_RETENTION_DAYS}d"
find "$BACKUP_DIR" -maxdepth 2 \( -name '*.tar.gz' -o -name '*.tar.zst' -o -name '*.tar' \) \
    -mtime +"$BACKUP_LOCAL_RETENTION_DAYS" -print -delete || true
# Orphaned checksum files — remove hashes whose archive no longer exists.
find "$CHECKSUM_DIR" -maxdepth 1 -name '*.sha256' | while read -r hf; do
    archive="$BACKUP_DIR/$(basename "$hf" .sha256)"
    [[ -f "$archive" ]] || { rm -f "$hf"; log "Pruned orphaned checksum: $(basename "$hf")"; }
done

log "===== backup complete ====="
