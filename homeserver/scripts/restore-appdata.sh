#!/bin/bash
# =============================================================================
# restore-appdata.sh — interactive restore from a CA Appdata Backup archive
#
# Walks you through selecting an archive (local or offsite), stopping affected
# containers, extracting, restarting, and waiting for healthchecks to confirm
# the restore took. For use after an appdata corruption, a bad Plex update,
# or a service config going sideways.
#
# This is intentionally interactive — restore is rare, high-stakes, and every
# prompt lets you stop before anything destructive happens.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
ENV_FILE="$STACK_DIR/.env"
GENERATED_ENV="$STACK_DIR/generated.env"
BACKUP_DIR="/mnt/user/backups/appdata"
APPDATA_DIR="/mnt/user/appdata"

RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (needs to chown extracted files)."

compose() {
    /usr/bin/docker compose -f "$COMPOSE_FILE" \
        --env-file "$ENV_FILE" --env-file "$GENERATED_ENV" "$@"
}

echo "=== restore-appdata.sh ==="
echo ""
echo "Available local backups:"
mapfile -t archives < <(find "$BACKUP_DIR" -maxdepth 2 \
    \( -name '*.tar.gz' -o -name '*.tar.zst' -o -name '*.tar' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')

if [[ ${#archives[@]} -eq 0 ]]; then
    die "No backup archives found under $BACKUP_DIR"
fi

for i in "${!archives[@]}"; do
    a="${archives[$i]}"
    mtime=$(date -d "@$(stat -c '%Y' "$a")" '+%Y-%m-%d %H:%M')
    size=$(du -h "$a" | awk '{print $1}')
    printf "  [%2d] %s  %s  %s\n" "$i" "$mtime" "$size" "$a"
done
echo ""

read -rp "Select archive number: " idx
[[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid selection"
(( idx < ${#archives[@]} )) || die "Out of range"
chosen="${archives[$idx]}"

echo ""
echo "Chosen: $chosen"
echo ""
read -rp "Which services to restore? (space-separated, or 'all'): " services

if [[ "$services" == "all" ]]; then
    services=$(compose config --services | tr '\n' ' ')
fi

echo ""
warn "Will stop these containers:  $services"
warn "Will extract $chosen over:   $APPDATA_DIR"
warn "THIS OVERWRITES CURRENT APPDATA for the selected services."
echo ""
read -rp "Type 'yes' to proceed: " confirm
[[ "$confirm" == "yes" ]] || die "Aborted."

echo ""
echo "Stopping containers..."
# shellcheck disable=SC2086
compose stop $services

# Extract to a temp dir first, then move per service. This avoids wiping
# services the user didn't ask to restore, even if the archive is full-appdata.
tmp=$(mktemp -d -p /mnt/user/appdata .restore.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

echo "Extracting to staging dir: $tmp"
case "$chosen" in
    *.tar.gz) tar -xzf "$chosen" -C "$tmp" ;;
    *.tar.zst) tar --zstd -xf "$chosen" -C "$tmp" ;;
    *.tar)    tar -xf "$chosen" -C "$tmp" ;;
esac

for svc in $services; do
    src=""
    # CA Appdata Backup usually nests either under ./appdata/<svc> or ./<svc>
    for candidate in "$tmp/appdata/$svc" "$tmp/$svc"; do
        [[ -d "$candidate" ]] && { src="$candidate"; break; }
    done
    if [[ -z "$src" ]]; then
        warn "No $svc/ found in archive — skipping."
        continue
    fi

    echo "Restoring $svc..."
    # Move current appdata aside as .pre-restore, then move archive in.
    # Keeping the old copy lets you revert this script's work with one mv.
    if [[ -d "$APPDATA_DIR/$svc" ]]; then
        mv "$APPDATA_DIR/$svc" "$APPDATA_DIR/$svc.pre-restore-$(date +%Y%m%d-%H%M%S)"
    fi
    mv "$src" "$APPDATA_DIR/$svc"
    chown -R nobody:users "$APPDATA_DIR/$svc"
    echo "  ✓ $svc restored (previous kept as $svc.pre-restore-*)"
done

echo ""
echo "Starting containers..."
# shellcheck disable=SC2086
compose up -d $services

echo ""
echo "Waiting up to 180s for services to report healthy..."
deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
    bad=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        s=$(echo "$line" | sed -n 's/.*"Service" *: *"\([^"]*\)".*/\1/p')
        st=$(echo "$line" | sed -n 's/.*"State" *: *"\([^"]*\)".*/\1/p')
        hp=$(echo "$line" | sed -n 's/.*"Health" *: *"\([^"]*\)".*/\1/p')
        [[ " $services " == *" $s "* ]] || continue
        if [[ "$st" != "running" ]]; then
            bad+=" $s($st)"
        elif [[ -n "$hp" && "$hp" != "healthy" ]]; then
            bad+=" $s(health=$hp)"
        fi
    done < <(compose ps --format json)

    if [[ -z "$bad" ]]; then
        echo "  All restored services healthy."
        break
    fi
    sleep 10
done

if [[ -n "${bad:-}" ]]; then
    warn "Not all services are healthy:${bad}"
    warn "Inspect logs: compose logs --tail 100 <service>"
    warn "To revert: stop the service, rm -rf the restored dir, mv the .pre-restore-* back."
    exit 1
fi

echo ""
echo "Restore complete. Previous appdata snapshots kept under:"
find "$APPDATA_DIR" -maxdepth 1 -name '*.pre-restore-*' -printf '  %p\n'
echo "Remove them with 'rm -rf' once you've confirmed everything works."
