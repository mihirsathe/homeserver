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

# installplg lives in /usr/local/sbin which isn't always in PATH
export PATH="/usr/local/sbin:$PATH"
[[ ! -x /usr/local/sbin/installplg ]] && die "installplg not found — is this Unraid 6.x?"

info "Starting Unraid automated setup..."
echo ""

# ---------------------------------------------------------------------------
# STEP 1 & 2: Plugins
# ---------------------------------------------------------------------------
info "Step 1/8 — Checking plugins..."
echo ""

# Map of plugin name -> installed check (directory under /usr/local/emhttp/plugins/)
declare -A PLUGIN_CHECKS=(
    ["Community Applications"]="community.applications"
    ["Fix Common Problems"]="fix.common.problems"
    ["Appdata Backup"]="appdata.backup"
    ["User Scripts"]="user.scripts"
    ["Unassigned Devices"]="unassigned.devices"
    ["Nvidia-Driver"]="nvidia-driver"
    ["Dynamix File Integrity"]="dynamix.file.integrity"
    ["Tailscale"]="tailscale"
)

MISSING_PLUGINS=()
for name in "${!PLUGIN_CHECKS[@]}"; do
    dir="${PLUGIN_CHECKS[$name]}"
    if [[ -d /usr/local/emhttp/plugins/$dir ]]; then
        ok "  $name — already installed"
    else
        warn "  $name — NOT installed"
        MISSING_PLUGINS+=("$name")
    fi
done
echo ""

if [[ ${#MISSING_PLUGINS[@]} -gt 0 ]]; then
    warn "The following plugins must be installed manually via Apps before continuing:"
    for p in "${MISSING_PLUGINS[@]}"; do
        warn "  • $p"
    done
    warn "Apps tab → search by name → Install → then re-run this script."
    warn "For Nvidia-Driver: search 'Nvidia-Driver' in Apps."
    warn "For Appdata Backup: search 'Appdata Backup' (Commifreak's fork)."
    die "Install missing plugins and re-run."
fi

info "Step 2/8 — All plugins present, skipping install."
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
DATA_SHARE="$SHARES_DIR/data.cfg"
if [[ -f "$DATA_SHARE" ]]; then
    ok "  data share config already exists"
else
    cat > "$DATA_SHARE" << 'EOF'
shareComment=
shareAllocator=highwater
shareSplitLevel=0
shareInclude=
shareExclude=
shareUseCache=yes
shareCachePool=cache
shareCOW=auto
shareMinFreeSize=50000
shareNameOrig=data
shareFloor=5%
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
shareComment=Docker application data
shareAllocator=highwater
shareSplitLevel=1
shareInclude=
shareExclude=
shareUseCache=only
shareCachePool=cache
shareCOW=auto
shareNameOrig=appdata
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
shareComment=SABnzbd incomplete downloads (cache-only, never migrates to array)
shareAllocator=highwater
shareSplitLevel=0
shareInclude=
shareExclude=
shareUseCache=only
shareCachePool=cache
shareCOW=auto
shareNameOrig=usenet-incomplete
EOF
    ok "  usenet-incomplete share config written"
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
    echo "  mkdir -p /mnt/user/appdata/plex-transcode"
    echo "  chown -R nobody:users /mnt/user/data/ /mnt/user/usenet-incomplete /mnt/user/appdata/plex-transcode"
    echo "  chmod -R a=,a+rX,u+w,g+w /mnt/user/data/ /mnt/user/usenet-incomplete"
    echo ""
else
    mkdir -p /mnt/user/data/{usenet/complete/{tv,movies,music},media/{tv,movies,music}}
    mkdir -p /mnt/user/usenet-incomplete
    mkdir -p /mnt/user/appdata/plex-transcode

    chown -R nobody:users /mnt/user/data/ /mnt/user/usenet-incomplete
    chown -R nobody:users /mnt/user/appdata/plex-transcode
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
docker compose --env-file .env --env-file generated.env up -d
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
echo "    docker compose --env-file .env --env-file generated.env up -d"
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
