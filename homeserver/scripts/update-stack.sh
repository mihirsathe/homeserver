#!/bin/bash
# =============================================================================
# update-stack.sh — Monthly stack update
#
# On Unraid, schedule this via User Scripts plugin:
#   Settings → User Scripts → Add New Script
#   Schedule: Monthly, day 1, 3am
#   Command: bash /mnt/user/appdata/homeserver/homeserver/scripts/update-stack.sh
#
# Uses /usr/bin/docker (explicit path) because Unraid's PATH in cron
# contexts may not include the docker binary location.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
# Single merged env-file written by generate-configs.py from .env + generated.env.
# Avoids --env-file precedence quirks where a stale STACK_DIR= entry in .env
# could blank out the value generated.env provides.
DOCKER_ENV="$STACK_DIR/.env.docker"
CADDYFILE="$STACK_DIR/configs/caddy/Caddyfile"
LOCK_FILE="/var/lock/homeserver-update.lock"
LOG_FILE="/var/log/homeserver-update.log"
MIN_FREE_MB=5120  # 5 GB free required on appdata before pulling

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo "  --dry-run    Validate preconditions and print planned actions; don't pull or restart."
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Tee all output to the log while preserving interactive stdout.
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

ts() { date +'%Y-%m-%dT%H:%M:%S%z'; }

echo "[$(ts)] ===== update-stack.sh starting (dry_run=$DRY_RUN) ====="

# Single-instance guard: scheduled cron run and a manual run must not collide.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(ts)] Another update-stack.sh run is already in progress — exiting."
    exit 1
fi

# Pre-flight: verify the files we need actually exist before touching Docker.
for f in "$COMPOSE_FILE" "$DOCKER_ENV" "$CADDYFILE"; do
    [[ -f "$f" ]] || { echo "[$(ts)] ERROR: required file not found: $f"; exit 1; }
done

# Pre-flight: Caddyfile must parse. A broken Caddyfile would take down the
# admin ingress on `compose up`, so validate before pulling. Run via
# `docker run --rm` against the existing caddy:2-alpine image (already on
# disk because the stack is up) so the check works whether or not the live
# caddy container is currently running. This deliberately runs before the
# dry-run branch — a syntax error should fail in dry-run too.
echo "[$(ts)] Pre-flight: validating Caddyfile..."
if ! /usr/bin/docker run --rm \
        -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" \
        caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    echo "[$(ts)] ERROR: Caddyfile failed to validate. Output:"
    /usr/bin/docker run --rm \
        -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" \
        caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile 2>&1 | sed 's/^/    /'
    exit 1
fi
echo "[$(ts)] Pre-flight: Caddyfile OK"

# Pre-flight: appdata must have room for fresh image layers.
# df reports 1K blocks; convert to MB. /mnt/user/appdata is a share, not a
# mountpoint, so check its backing mount via `-P` which resolves it properly.
FREE_MB=$(df -Pm /mnt/user/appdata 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -z "${FREE_MB:-}" ]]; then
    echo "[$(ts)] WARN: could not determine free space on /mnt/user/appdata"
elif (( FREE_MB < MIN_FREE_MB )); then
    echo "[$(ts)] ERROR: only ${FREE_MB}MB free on /mnt/user/appdata; need ${MIN_FREE_MB}MB. Aborting."
    exit 1
else
    echo "[$(ts)] Pre-flight: ${FREE_MB}MB free on appdata (min ${MIN_FREE_MB}MB)"
fi

compose() {
    /usr/bin/docker compose -f "$COMPOSE_FILE" --env-file "$DOCKER_ENV" "$@"
}

if (( DRY_RUN )); then
    echo "[$(ts)] Dry run: would run 'compose pull' and 'compose up -d'"
    echo "[$(ts)] Images that would be pulled:"
    compose config --images | sed 's/^/    /'
    exit 0
fi

# Pull latest images for all services
echo "[$(ts)] Pulling images..."
compose pull

# Restart any containers whose image changed (leaves unchanged ones running)
echo "[$(ts)] Redeploying..."
compose up -d

# Post-flight: wait for every service with a healthcheck to report healthy,
# OR (services without a healthcheck) to at least report running. Bail on
# timeout so a broken release can't be pruned out from under us.
echo "[$(ts)] Post-flight: waiting up to 300s for services to settle..."
deadline=$(( $(date +%s) + 300 ))
while (( $(date +%s) < deadline )); do
    # compose ps --format json emits one JSON object per line (not an array).
    # Each has Health (may be empty for no-healthcheck services) and State.
    bad=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        svc=$(echo "$line" | sed -n 's/.*"Service" *: *"\([^"]*\)".*/\1/p')
        st=$(echo "$line"  | sed -n 's/.*"State" *: *"\([^"]*\)".*/\1/p')
        hp=$(echo "$line"  | sed -n 's/.*"Health" *: *"\([^"]*\)".*/\1/p')
        # A service is "bad" if it's not running, or it has a healthcheck and
        # isn't healthy yet (starting/unhealthy both count as not-settled).
        if [[ "$st" != "running" ]]; then
            bad+=" $svc($st)"
        elif [[ -n "$hp" && "$hp" != "healthy" ]]; then
            bad+=" $svc(health=$hp)"
        fi
    done < <(compose ps --format json)

    if [[ -z "$bad" ]]; then
        echo "[$(ts)] All services healthy."
        break
    fi
    sleep 10
done

if [[ -n "${bad:-}" ]]; then
    echo "[$(ts)] ERROR: services did not settle within 300s:${bad}"
    echo "[$(ts)] Last 50 lines of logs per bad service:"
    for entry in $bad; do
        svc="${entry%%(*}"
        echo "--- $svc ---"
        compose logs --tail 50 "$svc" || true
    done
    echo "[$(ts)] Skipping image prune so a rollback (docker tag previous :backup) remains possible."
    exit 1
fi

# Remove dangling images to keep the SSD cache pool from filling up.
# Gated behind the health check above — a broken release keeps its old
# layers around so you can inspect or retag them.
echo "[$(ts)] Pruning dangling images..."
/usr/bin/docker image prune -f

echo "[$(ts)] ===== update complete ====="
compose ps
