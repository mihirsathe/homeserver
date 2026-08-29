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
#   Settings → User Scripts → media_stack_backup → weekly (Sunday 5am, an hour
#   *after* the Appdata Backup plugin's own 4am schedule).
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
BACKUP_NEXTCLOUD_REMOTE=""
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    set -a; source <(grep -E '^(BACKUP_LOCAL_RETENTION_DAYS|BACKUP_REMOTE|BACKUP_NEXTCLOUD_REMOTE)=' "$ENV_FILE" || true); set +a
fi

# ---------------------------------------------------------------------------
# Nextcloud — deliberately FIRST, before any of the appdata checks below.
#
# Everything after this point can exit non-zero (no backup dir, no archive, a
# stale archive), and all of those are conditions of the Appdata Backup
# plugin, not of Nextcloud. Running this first means a plugin that quietly
# stopped weeks ago cannot also silently take the personal-file backup with
# it. These are the only irreplaceable bytes on the box.
#
# THE INDEPENDENCE HAS TO HOLD BOTH WAYS, which is why nothing in this section
# calls `exit`. It records failures in NC_FAILED and carries on, so that a
# failed rclone here — much more likely than a plugin failure, since this leg
# may move hundreds of GB over a network that only has to blink once — cannot
# take the appdata verification, checksum, offsite copy and prune down with
# it. The exit code is resolved once, at the very end of the script.
#
# Two halves, and they are separated on purpose:
#
#   1. The DATABASE is dumped with Nextcloud in maintenance mode, so it is
#      internally consistent. That window is seconds to a minute.
#   2. The FILES are copied with Nextcloud back up. Holding maintenance mode
#      across a multi-hundred-GB rclone is not acceptable for a service the
#      household relies on. The cost is that a file uploaded mid-copy can
#      reach the remote without its database row — which `occ files:scan`
#      reconciles, and which is the benign direction. The reverse (a database
#      referencing files that were never copied) is what the ordering avoids.
# ---------------------------------------------------------------------------
NC_DUMP_DIR="/mnt/cache/appdata/nextcloud-dump"
NC_DATA_DIR="/mnt/user/nextcloud"

# Explicit path, matching update-stack.sh and restore-appdata.sh. This script
# runs as the weekly `media_stack_backup` User Script, and Unraid's PATH in a
# cron context does not reliably include the docker binary. A bare `docker`
# would make every scheduled run report "not deployed" and exit 0 — silently
# skipping the only backup the irreplaceable files ever get.
DOCKER=/usr/bin/docker
[[ -x "$DOCKER" ]] || DOCKER="$(command -v docker || true)"

NC_FAILED=0

nc_occ() { "$DOCKER" exec -u www-data nextcloud php occ "$@"; }
nc_maintenance_off() {
    if nc_occ maintenance:mode --off >/dev/null 2>&1; then
        log "Nextcloud maintenance mode OFF"
    else
        # The one failure that leaves the SERVICE DOWN rather than merely
        # leaving a backup incomplete: every sync client, CalDAV and CardDAV
        # endpoint returns 503 until someone clears it. It has to fail the run,
        # because a non-zero exit is the only thing that fires User Scripts'
        # email-on-failure hook — the sole notification path this design has.
        log "ERROR: could not clear Nextcloud maintenance mode — IT IS STILL DOWN."
        log "       Clear by hand: docker exec -u www-data nextcloud php occ maintenance:mode --off"
        NC_FAILED=1
    fi
}

if [[ -z "$DOCKER" ]]; then
    # Deliberately NOT reported as "not deployed" — that reads as a benign skip
    # and exits 0, which is exactly how this would go unnoticed for months.
    log "ERROR: docker binary not found (cron PATH?) — cannot back up Nextcloud."
    NC_FAILED=1
elif ! "$DOCKER" inspect nextcloud >/dev/null 2>&1; then
    log "Nextcloud not deployed — skipping its backup."
else
    log "----- Nextcloud backup -----"
    mkdir -p "$NC_DUMP_DIR"
    # A run killed hard enough to skip its trap (OOM, host reset) leaves a
    # partial .tmp behind, and the retention prune below only matches finished
    # .sql.gz files — so without this they accumulate on the cache pool
    # forever. An hour is well clear of any legitimate in-flight dump.
    find "$NC_DUMP_DIR" -maxdepth 1 -name '*.sql.gz.tmp' -mmin +60 -delete 2>/dev/null || true

    # The trap is the whole reason this is safe to run unattended. This script
    # is `set -euo pipefail`, so a failed pg_dump or a full disk aborts it
    # mid-flight — and without the trap that would leave Nextcloud in
    # maintenance mode until someone noticed it was down. Armed before
    # maintenance mode goes on, cleared once it is back off.
    trap nc_maintenance_off EXIT

    if nc_occ maintenance:mode --on >/dev/null 2>&1; then
        log "Nextcloud maintenance mode ON (database dump window)"
    else
        log "WARN: could not enable maintenance mode — dumping anyway, consistency not guaranteed"
    fi

    NC_DUMP="$NC_DUMP_DIR/nextcloud-$(date +%F-%H%M).sql.gz"
    # No -h, so this goes over the unix socket, which the postgres image's
    # generated pg_hba.conf trusts. Nothing has to know the password, and the
    # password never lands in a process list or in this log.
    #
    # --clean --if-exists makes the dump restorable into a database that still
    # EXISTS, which is the common disaster: Nextcloud 500s on a corrupt table,
    # the database is still there, and a plain dump would then hit "already
    # exists" on every CREATE and duplicate-key on every COPY. psql defaults
    # ON_ERROR_STOP to off, so that scrolls errors and still exits 0 — a
    # restore that reports success and changed nothing. --if-exists keeps it
    # quiet when restoring into an empty database too.
    if "$DOCKER" exec nextcloud-db pg_dump -U nextcloud -d nextcloud --clean --if-exists \
            | gzip > "$NC_DUMP.tmp"; then
        mv "$NC_DUMP.tmp" "$NC_DUMP"
        log "Database dumped: $NC_DUMP ($(du -h "$NC_DUMP" | cut -f1))"
    else
        rm -f "$NC_DUMP.tmp"
        log "ERROR: pg_dump failed — no database dump from this run."
        # Not fatal to the rest. A dead database container says nothing about
        # the user files, and those are the half that cannot be re-sourced.
        NC_FAILED=1
    fi

    # Released BEFORE the long file copy, and before anything else that can
    # fail — so maintenance mode is never held across a failure path.
    nc_maintenance_off
    trap - EXIT

    if [[ -z "$BACKUP_NEXTCLOUD_REMOTE" ]]; then
        log "BACKUP_NEXTCLOUD_REMOTE unset — user files have NO offsite copy."
        log "  The Appdata Backup plugin does not cover $NC_DATA_DIR. Array parity"
        log "  survives a dead disk; it does not survive a deleted file or a lost array."
    elif ! command -v rclone >/dev/null 2>&1; then
        log "WARN: BACKUP_NEXTCLOUD_REMOTE is set but rclone is not installed. Skipping."
    else
        log "Syncing $NC_DATA_DIR -> $BACKUP_NEXTCLOUD_REMOTE"
        # `copy`, NOT `sync`. sync mirrors deletions to the remote, which
        # would faithfully replicate the exact accident this backup exists to
        # survive. The cost is that the remote only grows; prune it
        # deliberately, not as a side effect of a bad local delete.
        #
        # Previews are excluded: regenerable, and they are the one thing in a
        # Nextcloud data dir that grows without bound.
        if rclone copy "$NC_DATA_DIR" "$BACKUP_NEXTCLOUD_REMOTE" \
                --exclude 'appdata_*/preview/**' \
                --stats=60s; then
            log "Nextcloud file copy succeeded."
        else
            log "ERROR: rclone copy of Nextcloud files failed."
            NC_FAILED=1
        fi
    fi

    # Same retention as the appdata archives. The dumps live inside appdata,
    # so the plugin's next weekly archive sweeps one up too — this offsite
    # copy just means that coverage does not lag by a week.
    find "$NC_DUMP_DIR" -maxdepth 1 -name '*.sql.gz' \
        -mtime +"$BACKUP_LOCAL_RETENTION_DAYS" -print -delete || true
    # Runs even if the file copy above failed — the dump is small, independent,
    # and getting it offsite should not be hostage to a stalled bulk transfer.
    if [[ -n "$BACKUP_NEXTCLOUD_REMOTE" ]] && command -v rclone >/dev/null 2>&1; then
        if rclone copy "$NC_DUMP_DIR" "$BACKUP_NEXTCLOUD_REMOTE/db" >/dev/null 2>&1; then
            log "Database dump copied offsite."
        else
            log "WARN: could not copy the database dump offsite."
            NC_FAILED=1
        fi
    fi

    if (( NC_FAILED )); then
        log "----- Nextcloud backup FINISHED WITH ERRORS (continuing to appdata) -----"
    else
        log "----- Nextcloud backup complete -----"
    fi
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

# Single place the exit code is decided. The appdata half above exits 1 inline
# on its own failures; the Nextcloud half deliberately does not, so its result
# is resolved here instead. Either way a non-zero exit is what makes the
# User Scripts "email on failure" hook fire.
if (( NC_FAILED )); then
    log "===== appdata backup complete, but the NEXTCLOUD half reported errors ====="
    log "      Re-run by hand once fixed: bash scripts/backup-appdata.sh"
    exit 1
fi

log "===== backup complete ====="
