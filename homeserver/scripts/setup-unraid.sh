#!/bin/bash
# =============================================================================
# setup-unraid.sh
# =============================================================================
# Automates Unraid configuration after first boot. Run this from the Unraid
# terminal once the OS is up and you've set a root password.
#
# What this script does:
#   1. Installs Community Applications plugin
#   2. Installs all required plugins via installplg
#   3. Writes Docker settings (overlay2, custom network access)
#   4. Writes Global Share settings (hardlinks enabled)
#   5. Creates the data share config
#   6. Creates all folder structure and sets permissions
#
# What this script does NOT do:
#   - Array disk assignment (requires human verification of drive serials)
#   - Formatting and starting the array (requires human confirmation)
#   - The two reboots required after Nvidia plugin installs
#
# Usage:
#   bash /boot/config/plugins/user.scripts/scripts/setup-unraid.sh
#   (or paste directly into the Unraid terminal)
#
# Run as: root (default on Unraid)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Run as root"
[[ ! -d /boot/config ]] && die "/boot/config not found — is this Unraid?"

export PATH="/usr/local/sbin:$PATH"
[[ ! -x /usr/local/sbin/plugin ]] && die "/usr/local/sbin/plugin not found — is this Unraid 6.x?"

info "Starting Unraid automated setup..."
echo ""

# ---------------------------------------------------------------------------
# STEP 1 & 2: Plugins
# ---------------------------------------------------------------------------
info "Step 1/8 — Installing plugins..."
echo ""

# plugin name -> "installed-dir|plg-url"
declare -A PLUGINS=(
    ["Community Applications"]="community.applications|https://raw.githubusercontent.com/unraid/community.applications/master/plugins/community.applications.plg"
    ["Fix Common Problems"]="fix.common.problems|https://raw.githubusercontent.com/unraid/fix.common.problems/master/plugins/fix.common.problems.plg"
    ["Appdata Backup"]="appdata.backup|https://raw.githubusercontent.com/Commifreak/unraid-appdata.backup/master/appdata.backup.plg"
    ["User Scripts"]="user.scripts|https://raw.githubusercontent.com/Squidly271/user.scripts/master/plugins/user.scripts.plg"
    ["Unassigned Devices"]="unassigned.devices|https://raw.githubusercontent.com/unraid/unassigned.devices/master/unassigned.devices.plg"
    ["Nvidia-Driver"]="nvidia-driver|https://raw.githubusercontent.com/unraid/unraid-nvidia-driver/master/nvidia-driver.plg"
    ["Dynamix File Integrity"]="dynamix.file.integrity|https://raw.githubusercontent.com/unraid/dynamix/master/unRAIDv6/dynamix.file.integrity.plg"
    ["Tailscale"]="tailscale|https://raw.githubusercontent.com/unraid/unraid-tailscale/main/plugin/tailscale.plg"
)

for name in "${!PLUGINS[@]}"; do
    IFS='|' read -r dir url <<< "${PLUGINS[$name]}"
    if [[ -d /usr/local/emhttp/plugins/$dir ]]; then
        ok "  $name — already installed"
    else
        info "  Installing $name..."
        plugin install "$url" && ok "  $name installed" \
            || warn "  $name install failed — install manually via Apps tab"
    fi
done
echo ""

info "Step 2/8 — Plugin installation complete."
echo ""

# ---------------------------------------------------------------------------
# STEP 3: Docker settings
# ---------------------------------------------------------------------------
info "Step 3/8 — Writing Docker settings..."

DOCKER_CFG="/boot/config/docker.cfg"

# Create if it doesn't exist
touch "$DOCKER_CFG"

# Apply each setting. Use sed to update existing lines, append if not present.
set_cfg() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

set_cfg "$DOCKER_CFG" "DOCKER_ENABLED"          "yes"
set_cfg "$DOCKER_CFG" "STORAGE_DRIVER"          "overlay2"
# Host access to custom networks — lets bootstrap.py reach container-only
# services from the Unraid shell (e.g. localhost:7878 for Radarr).
set_cfg "$DOCKER_CFG" "DOCKER_HOST_ACCESS"      "yes"
# Docker image storage on the cache SSD, not the spinning array
set_cfg "$DOCKER_CFG" "DOCKER_APP_CONFIG_PATH"  "/mnt/user/appdata"
set_cfg "$DOCKER_CFG" "DOCKER_IMAGE_PATH"        "/mnt/user/appdata"

ok "Docker settings written to $DOCKER_CFG"

# ---------------------------------------------------------------------------
# STEP 4: Global share settings (hardlinks)
# ---------------------------------------------------------------------------
info "Step 4/8 — Writing global share settings..."

SHARE_CFG="/boot/config/share.cfg"
touch "$SHARE_CFG"

# Support Hard Links — without this every media import is a full file copy.
# This is the single most important Unraid tunable for this stack.
set_cfg "$SHARE_CFG" "shareMoverLogging"    "no"
set_cfg "$SHARE_CFG" "shareInitialGroup"    "users"
set_cfg "$SHARE_CFG" "shareInitialOwner"    "nobody"
# The hardlinks tunable — maps to Settings → Global Share Settings → Tunable (support Hard Links)
set_cfg "$SHARE_CFG" "shareAFPEnabled"      "no"
set_cfg "$SHARE_CFG" "shareSMBEnabled"      "yes"
set_cfg "$SHARE_CFG" "shareNFSEnabled"      "no"

# The actual hardlinks-enabling tunable lives in the SMB config.
# Unraid writes this to /boot/config/smb-extra.conf but the global
# share setting is toggled via this cfg key:
set_cfg "$SHARE_CFG" "shareHardLinks"       "yes"

ok "Share settings written to $SHARE_CFG"

# ---------------------------------------------------------------------------
# STEP 5: UPS settings (apcupsd via USB)
# ---------------------------------------------------------------------------
# Unraid reads /boot/config/plugins/dynamix/ups.cfg at boot and regenerates
# /etc/apcupsd/apcupsd.conf from it. Writing this file directly is equivalent
# to toggling Settings → UPS Settings in the UI. Safe to run before the UPS
# is physically connected — apcupsd will start, fail to find a HID device,
# and idle until the USB cable appears. Nothing else is affected.
#
# Thresholds match the guidance in docs/vision/phases.md §3.2.
info "Step 5/8 — Writing UPS settings..."

UPS_CFG_DIR="/boot/config/plugins/dynamix"
UPS_CFG="${UPS_CFG_DIR}/ups.cfg"
mkdir -p "$UPS_CFG_DIR"
touch "$UPS_CFG"

set_cfg "$UPS_CFG" "SERVICE"      "enable"
set_cfg "$UPS_CFG" "CABLE"        "usb"
set_cfg "$UPS_CFG" "TYPE"         "usb"
set_cfg "$UPS_CFG" "DEVICE"       ""
set_cfg "$UPS_CFG" "UPSNAME"      "r640-ups"
set_cfg "$UPS_CFG" "BATTERYLEVEL" "20"
set_cfg "$UPS_CFG" "MINUTES"      "5"
set_cfg "$UPS_CFG" "TIMEOUT"      "0"
set_cfg "$UPS_CFG" "KILLUPS"      "no"
set_cfg "$UPS_CFG" "NISIP"        "127.0.0.1"

ok "UPS settings written to $UPS_CFG"

# ---------------------------------------------------------------------------
# STEP 6: Create the data share config
# ---------------------------------------------------------------------------
info "Step 6/8 — Creating share configs..."

SHARES_DIR="/boot/config/shares"
mkdir -p "$SHARES_DIR"

# data share — where all media and usenet downloads live
# Primary: array (spinning HDDs), Cache: yes (writes go to SSD first, mover runs nightly)
# All values are quoted: Unraid's mover sources cfg files with bash, and unquoted values
# with special characters (parentheses, semicolons) cause syntax errors that cascade to subsequent shares.
DATA_SHARE="$SHARES_DIR/data.cfg"
if [[ -f "$DATA_SHARE" ]]; then
    ok "  data share config already exists"
else
    cat > "$DATA_SHARE" << 'EOF'
shareComment="media and usenet downloads"
shareInclude=""
shareExclude=""
shareUseCache="yes"
shareCachePool="cache"
shareCachePool2=""
shareCOW="auto"
shareAllocator="highwater"
shareSplitLevel="0"
shareFloor="5%"
shareExport="-"
shareCaseSensitive="auto"
shareSecurity="private"
shareReadList=""
shareWriteList=""
shareVolsizelimit=""
shareExportNFS="-"
shareExportNFSFsid="0"
shareSecurityNFS="public"
shareHostListNFS=""
EOF
    ok "  data share config written"
fi

# appdata share — Docker config and databases, lives entirely on SSD cache pool
# This share should already exist from Unraid's defaults, but ensure correct settings
APPDATA_SHARE="$SHARES_DIR/appdata.cfg"
if [[ -f "$APPDATA_SHARE" ]]; then
    # Ensure cache=only so appdata never migrates to spinning array
    sed -i 's|^shareUseCache=.*|shareUseCache=only|' "$APPDATA_SHARE" 2>/dev/null || true
    ok "  appdata share: verified cache=only"
else
    cat > "$APPDATA_SHARE" << 'EOF'
shareComment="application data"
shareInclude=""
shareExclude=""
shareUseCache="only"
shareCachePool="cache"
shareCachePool2=""
shareCOW="auto"
shareAllocator="highwater"
shareSplitLevel="1"
shareFloor="0"
shareExport="-"
shareCaseSensitive="auto"
shareSecurity="private"
shareReadList=""
shareWriteList=""
shareVolsizelimit=""
shareExportNFS="-"
shareExportNFSFsid="0"
shareSecurityNFS="public"
shareHostListNFS=""
EOF
    ok "  appdata share config written"
fi

# usenet-incomplete share — SABnzbd active downloads, par2 + unrar
# cache=only means mover never touches these files; they stay on SSD until
# SAB moves them to /mnt/user/data/usenet/complete/ on the array.
INCOMPLETE_SHARE="$SHARES_DIR/usenet-incomplete.cfg"
if [[ -f "$INCOMPLETE_SHARE" ]]; then
    sed -i 's|^shareUseCache=.*|shareUseCache=only|' "$INCOMPLETE_SHARE" 2>/dev/null || true
    ok "  usenet-incomplete share: verified cache=only"
else
    cat > "$INCOMPLETE_SHARE" << 'EOF'
shareComment="SABnzbd incomplete downloads"
shareInclude=""
shareExclude=""
shareUseCache="only"
shareCachePool="cache"
shareCachePool2=""
shareCOW="auto"
shareAllocator="highwater"
shareSplitLevel="0"
shareFloor="0"
shareExport="-"
shareCaseSensitive="auto"
shareSecurity="private"
shareReadList=""
shareWriteList=""
shareVolsizelimit=""
shareExportNFS="-"
shareExportNFSFsid="0"
shareSecurityNFS="public"
shareHostListNFS=""
EOF
    ok "  usenet-incomplete share config written"
fi

# nextcloud share — personal files served by Nextcloud.
#
# Deliberately NOT a folder under the `data` share. Every container in the
# media path mounts /mnt/user/data at /data, including sabnzbd, which downloads
# from the internet for a living. Personal documents get their own
# share so the download plane has no path to them at all.
#
# cache=no (array direct), not cache=yes. The cache pool is 480 GB and filling
# it is the most common real incident on this box; the initial migration off
# a cloud provider is exactly the dump-hundreds-of-GB-at-once case that would
# do it. Upload speed is then bounded by parity writes rather than the 1 GbE
# link, which is the right trade for a file sync. Switch to `yes` with a floor
# once the pool has headroom.
#
# shareExport=- turns SMB off for this share. Files written behind Nextcloud's
# back are invisible to it until `occ files:scan` runs, so the share should
# only ever be reached through Nextcloud. Equivalent UI path:
# Shares -> nextcloud -> SMB -> Export: No.
NEXTCLOUD_SHARE="$SHARES_DIR/nextcloud.cfg"
if [[ -f "$NEXTCLOUD_SHARE" ]]; then
    ok "  nextcloud share config already exists"
else
    cat > "$NEXTCLOUD_SHARE" << 'EOF'
shareComment="Nextcloud user files"
shareInclude=""
shareExclude=""
shareUseCache="no"
shareCachePool="cache"
shareCachePool2=""
shareCOW="auto"
shareAllocator="highwater"
shareSplitLevel="0"
shareFloor="0"
shareExport="-"
shareCaseSensitive="auto"
shareSecurity="private"
shareReadList=""
shareWriteList=""
shareVolsizelimit=""
shareExportNFS="-"
shareExportNFSFsid="0"
shareSecurityNFS="public"
shareHostListNFS=""
EOF
    ok "  nextcloud share config written"
fi

ok "Share configs written"

# ---------------------------------------------------------------------------
# STEP 7: Folder structure and permissions
# ---------------------------------------------------------------------------
info "Step 7/8 — Creating folder structure..."

# Wait for the array to be available. If this script runs before array start,
# /mnt/user won't exist yet. In that case, print the commands and exit.
if [[ ! -d /mnt/user ]]; then
    warn "/mnt/user not available — array may not be started yet."
    warn "After starting the array, run these commands manually:"
    echo ""
    echo "  mkdir -p /mnt/user/data/{usenet/complete/{tv,movies,music},media/{tv,movies,music}}"
    echo "  mkdir -p /mnt/user/usenet-incomplete"
    echo "  mkdir -p /mnt/user/appdata/plex-transcode /mnt/user/appdata/ollama /mnt/user/appdata/actual /mnt/user/appdata/chess-coach/data"
    echo "  chown -R nobody:users /mnt/user/data/ /mnt/user/usenet-incomplete /mnt/user/appdata/plex-transcode /mnt/user/appdata/ollama /mnt/user/appdata/actual /mnt/user/appdata/chess-coach/data"
    echo "  chmod -R a=,a+rX,u+w,g+w /mnt/user/data/ /mnt/user/usenet-incomplete"
    echo ""
    echo "  # Nextcloud. Created but NOT chowned — the containers own their"
    echo "  # ownership (www-data 33, postgres 70). See docs/decisions.md."
    echo "  mkdir -p /mnt/cache/appdata/nextcloud /mnt/cache/appdata/nextcloud-db /mnt/cache/appdata/nextcloud-dump"
    echo "  mkdir -p /mnt/user/nextcloud"
    echo ""
else
    mkdir -p /mnt/user/data/{usenet/complete/{tv,movies,music},media/{tv,movies,music}}
    mkdir -p /mnt/user/usenet-incomplete
    mkdir -p /mnt/user/appdata/plex-transcode
    # actual-server ships no USER directive (the published image runs as root)
    # and takes no PUID/PGID. docker-compose.yml pins it to 99:100 via `user:`,
    # so /data must already exist owned by 99:100 or the container restart-loops.
    mkdir -p /mnt/user/appdata/actual

    # ollama runs as PUID:PGID with HOME=/ollama on a stock image that has no
    # chown-at-start entrypoint, unlike the hotio/linuxserver images. If docker
    # creates this bind dir itself it lands root-owned and every `ollama pull`
    # fails on a permission error that reads like a network problem.
    mkdir -p /mnt/user/appdata/ollama

    # chess-coach runs as PUID:PGID with no chown-at-start entrypoint (plain
    # python-slim image) — the bind dir must be nobody:users before first up,
    # or docker creates it root-owned and SQLite writes fail.
    #
    # ONLY data/ is chowned, deliberately. The parent also holds the GitHub
    # deploy key and the repo checkout, both of which must stay root-owned:
    # OpenSSH refuses a private key owned by another user ("bad ownership or
    # modes"), so a recursive chown of the parent silently breaks every future
    # `git pull` for coach updates. data/ is the only path bind-mounted into
    # the container, so it is the only path that needs to change hands.
    mkdir -p /mnt/user/appdata/chess-coach/data

    # Nextcloud — created, then deliberately left alone.
    #
    # Every chown above exists because that container is pinned to 99:100 in
    # docker-compose.yml (its image ships no USER directive, so without the
    # pin it would run as root). Nextcloud and Postgres are the opposite case:
    # both entrypoints start as root, chown their own volumes, and drop to
    # www-data (33) and postgres (70) themselves. Chowning these to
    # nobody:users is precisely what Unraid's Tools -> New Permissions does to
    # break a working install — so this script must not do it either.
    #
    # /mnt/cache, not /mnt/user, for the appdata paths: serving one Nextcloud
    # page stats thousands of PHP files and shfs (FUSE) makes that measurably
    # slow. Safe only because appdata is shareUseCache=only, so these are the
    # same files as /mnt/user/appdata/... by a shorter path, not a second copy.
    if [[ -d /mnt/cache ]]; then
        mkdir -p /mnt/cache/appdata/nextcloud \
                 /mnt/cache/appdata/nextcloud-db \
                 /mnt/cache/appdata/nextcloud-dump
        ok "  nextcloud appdata dirs created on the cache pool (ownership left to containers)"
    else
        warn "  /mnt/cache not present — create the nextcloud appdata dirs after the pool mounts:"
        warn "    mkdir -p /mnt/cache/appdata/{nextcloud,nextcloud-db,nextcloud-dump}"
    fi
    # User files live on the array via the user share — they have to span it.
    mkdir -p /mnt/user/nextcloud

    chown -R nobody:users /mnt/user/data/ /mnt/user/usenet-incomplete
    chown -R nobody:users /mnt/user/appdata/plex-transcode
    chown -R nobody:users /mnt/user/appdata/ollama
    chown -R nobody:users /mnt/user/appdata/actual
    chown -R nobody:users /mnt/user/appdata/chess-coach/data
    chmod -R a=,a+rX,u+w,g+w /mnt/user/data/ /mnt/user/usenet-incomplete

    ok "Folder structure created:"
    find /mnt/user/data /mnt/user/usenet-incomplete -maxdepth 3 -type d | sort | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# STEP 8: Create User Scripts
# ---------------------------------------------------------------------------
info "Step 8/8 — Creating User Scripts..."

USER_SCRIPTS_DIR="/boot/config/plugins/user.scripts/scripts"
mkdir -p "$USER_SCRIPTS_DIR"

# At Array Start — bring the Compose stack up. Replaces Compose Manager Plus:
# Unraid ships `docker compose` in the base OS, so we just call it from a
# User Script scheduled for "At Startup of Array". Wait briefly for the Docker
# service to settle before issuing commands.
mkdir -p "$USER_SCRIPTS_DIR/media_stack_up"
cat > "$USER_SCRIPTS_DIR/media_stack_up/script" <<'EOF'
#!/bin/bash
set -euo pipefail
STACK_DIR=/mnt/user/appdata/homeserver/homeserver
# Wait for Docker daemon to be ready (array start -> Docker start is async).
for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done
cd "$STACK_DIR"
# Single merged env-file. .env.docker is regenerated by generate-configs.py
# every run from .env + generated.env (with generated.env winning), so
# variable substitution is unambiguous — no --env-file precedence quirks.
docker compose --env-file .env.docker up -d
EOF
chmod +x "$USER_SCRIPTS_DIR/media_stack_up/script"
ok "  media_stack_up created (run at array start)"

# Monthly stack update — no credentials needed
mkdir -p "$USER_SCRIPTS_DIR/media_stack_update"
cat > "$USER_SCRIPTS_DIR/media_stack_update/script" <<'EOF'
#!/bin/bash
bash /mnt/user/appdata/homeserver/homeserver/scripts/update-stack.sh
EOF
chmod +x "$USER_SCRIPTS_DIR/media_stack_update/script"
ok "  media_stack_update created"

# Weekly appdata backup verification + optional offsite copy. Runs after the
# Appdata Backup plugin's own schedule; see backup-appdata.sh for details.
mkdir -p "$USER_SCRIPTS_DIR/media_stack_backup"
cat > "$USER_SCRIPTS_DIR/media_stack_backup/script" <<'EOF'
#!/bin/bash
bash /mnt/user/appdata/homeserver/homeserver/scripts/backup-appdata.sh
EOF
chmod +x "$USER_SCRIPTS_DIR/media_stack_backup/script"
ok "  media_stack_backup created"

# NOTE: Fan control (iDRAC throttling for non-Dell GPUs) is now a separate
# opt-in script — scripts/setup-fan-control.sh — because it requires iDRAC
# credentials and is only needed if your GPU choice causes fan issues. Run it
# after the GPU is installed and you've confirmed fans are in fact loud.

echo ""
warn "Manual steps remaining for User Scripts:"
warn "  Settings → User Scripts → set schedules:"
warn "    media_stack_up     → At Startup of Array"
warn "    media_stack_update → Monthly (1st, 3am)"
warn "    media_stack_backup → Weekly (Sunday, 4am — after Appdata Backup)"

# ---------------------------------------------------------------------------
# Done — print what still needs human intervention
# ---------------------------------------------------------------------------
echo ""
echo "========================================================"
echo " Automated setup complete."
echo "========================================================"
echo ""
echo " Still requires manual steps (in order):"
echo ""
echo " 1. ASSIGN ARRAY DISKS (Main tab)"
echo "    Verify drive serial numbers before assigning:"
echo "      Parity  → 16TB HDD"
echo "      Disk 1-4 → 8TB HDDs"
echo "      Cache   → both 480GB SSDs"
echo ""
echo " 2. PLUG IN UPS DATA CABLE (skip if UPS not yet physically installed)"
echo "    USB-B end → UPS, USB-A end → any rear R640 USB port."
echo "    ups.cfg is already written. Verify after the reboot in step 4 below:"
echo "      apcaccess status   (expect STATUS : ONLINE)"
echo ""
echo " 3. START ARRAY AND FORMAT DISKS"
echo "    Main → Start → check format boxes → Format"
echo "    Parity sync will begin (~30-45 hours, array usable during sync)"
echo ""
echo " 4. REBOOT — activate Nvidia-Driver"
echo "    Main → Reboot"
echo "    After reboot, verify:"
echo "      nvidia-smi"
echo "      docker run --rm --runtime=nvidia nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi"
echo "    If the container test fails: Apps → search 'nvidia container toolkit' → Install"
echo "    Then restart Docker (Settings → Docker → toggle off/on)"
echo "    Confirm nvidia-container-toolkit >= 1.16.2 (closes CVE-2024-0132):"
echo "      nvidia-ctk --version"
echo ""
echo " 5. JOIN TAILSCALE"
echo "    Settings → Tailscale → Start the daemon."
echo "    From the Unraid terminal:"
echo "      tailscale up --ssh --advertise-tags=tag:server"
echo "    Open the auth URL, sign in. Install Tailscale on admin devices,"
echo "    tag them tag:admin, and apply ACLs so only tag:admin can reach"
echo "    tag:server on the *arr/SAB/Seerr/Unraid-webUI ports."
echo ""
echo " 6. ROUTER PORT-FORWARD FOR PLEX"
echo "    Plex is the only service with a public port. On your router:"
echo "      TCP 32400 -> <this server's LAN IP>:32400"
echo "    No UDP. No other ports. Everything else is Tailscale-only."
echo ""
echo " 7. SET USER SCRIPT SCHEDULES"
echo "    Settings → User Scripts:"
echo "      media_stack_up     → At Startup of Array"
echo "      media_stack_update → Monthly (1st, 3am)"
echo "      media_stack_backup → Weekly (Sunday, 4am)"
echo ""
echo " 8. (OPTIONAL) FAN CONTROL"
echo "    Only if chassis fans stay at ~100% after boot with the GPU installed:"
echo "      bash /mnt/user/appdata/homeserver/homeserver/scripts/setup-fan-control.sh"
echo ""
echo " 9. DEPLOY THE STACK"
echo "    git clone https://github.com/mihirsathe/homeserver /mnt/user/appdata/homeserver"
echo "    cd /mnt/user/appdata/homeserver/homeserver"
echo "    cp .env.example .env"
echo "    python3 scripts/generate-configs.py"
echo "    docker compose --env-file .env.docker up -d"
echo "    python3 scripts/bootstrap.py"
echo ""
echo "10. HARDEN UNRAID ACCESS (post-deploy)"
echo "    Settings → Management Access → disable Telnet + SSH password auth."
echo "    Use Tailscale SSH (the --ssh flag in step 5) instead."
echo ""
echo "11. DISABLE iDRAC"
echo "    Once the server is stable, disable iDRAC entirely from either the"
echo "    iDRAC webUI (iDRAC Settings → Network → disable NIC) or from the"
echo "    Lifecycle Controller at next boot (F10 → Hardware Configuration →"
echo "    iDRAC Settings → Network). Re-enable from BIOS F2 if ever needed"
echo "    for hardware debugging. Closes the largest LAN-adjacent attack"
echo "    surface at zero hardware cost."
echo ""
echo "========================================================"
