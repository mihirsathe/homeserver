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
ENV_FILE="$STACK_DIR/.env"
GENERATED_ENV="$STACK_DIR/generated.env"
LOCK_FILE="/var/lock/homeserver-update.lock"

# Single-instance guard: scheduled cron run and a manual run must not collide.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date)] Another update-stack.sh run is already in progress — exiting."
    exit 1
fi

echo "[$(date)] Starting media stack update..."

# Pre-flight: verify the files we need actually exist before touching Docker.
for f in "$COMPOSE_FILE" "$ENV_FILE" "$GENERATED_ENV"; do
    [[ -f "$f" ]] || { echo "ERROR: required file not found: $f"; exit 1; }
done

compose() {
    /usr/bin/docker compose -f "$COMPOSE_FILE" \
        --env-file "$ENV_FILE" --env-file "$GENERATED_ENV" "$@"
}

# Pull latest images for all services
compose pull

# Restart any containers whose image changed (leaves unchanged ones running)
compose up -d

# Remove dangling images to keep the SSD cache pool from filling up.
# Only runs if pull and up -d succeeded (set -e guarantees this).
/usr/bin/docker image prune -f

echo "[$(date)] Update complete."
compose ps
