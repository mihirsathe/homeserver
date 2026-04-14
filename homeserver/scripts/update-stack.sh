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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "[$(date)] Starting media stack update..."

# Pull latest images for all services
/usr/bin/docker compose -f "$STACK_DIR/docker-compose.yml" \
    --env-file "$STACK_DIR/.env" --env-file "$STACK_DIR/generated.env" pull

# Restart any containers whose image changed (leaves unchanged ones running)
/usr/bin/docker compose -f "$STACK_DIR/docker-compose.yml" \
    --env-file "$STACK_DIR/.env" --env-file "$STACK_DIR/generated.env" up -d

# Remove dangling images to keep the SSD cache pool from filling up
/usr/bin/docker image prune -f

echo "[$(date)] Update complete."
/usr/bin/docker compose -f "$STACK_DIR/docker-compose.yml" \
    --env-file "$STACK_DIR/.env" --env-file "$STACK_DIR/generated.env" ps
