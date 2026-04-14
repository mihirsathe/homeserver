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

info "Starting Unraid automated setup..."
echo ""

# ---------------------------------------------------------------------------
# STEP 1: Community Applications plugin
# ---------------------------------------------------------------------------
info "Step 1/7 — Installing Community Applications plugin..."

CA_PLG="https://raw.githubusercontent.com/Squidly271/community.applications/master/plugins/community.applications.plg"
CA_DEST="/boot/config/plugins/community.applications.plg"

if [[ -f /usr/local/emhttp/plugins/community.applications/plugin ]]; then
    ok "Community Applications already installed"
else
    installplg "$CA_PLG" && ok "Community Applications installed" \
        || die "Failed to install Community Applications"
fi

# ---------------------------------------------------------------------------
# STEP 2: Install all required plugins
# ---------------------------------------------------------------------------
info "Step 2/7 — Installing required plugins..."
echo ""

# Plugin URLs — all sourced from the official Unraid community repos.
# nvidia-container-toolkit URL includes the version path that Unraid's CA
# store would normally resolve for you.
declare -A PLUGINS=(
    ["Fix Common Problems"]="https://raw.githubusercontent.com/Squidly271/Fix-Common-Problems/master/source/fix.common.problems.plg"
    ["CA Appdata Backup"]="https://raw.githubusercontent.com/Squidly271/ca.backup2/master/plugins/ca.backup2.plg"
    ["User Scripts"]="https://raw.githubusercontent.com/Squidly271/user.scripts/master/plugins/user.scripts.plg"
    ["Unassigned Devices"]="https://raw.githubusercontent.com/dlandon/unassigned.devices/master/unassigned.devices.plg"
    ["Compose Manager Plus"]="https://raw.githubusercontent.com/mstrhakr/compose_plugin/main/compose.manager.plus.plg"
    ["Nvidia-Driver"]="https://raw.githubusercontent.com/unraid/unraid-nvidia-driver/master/nvidia-driver.plg"
    ["Dynamix File Integrity"]="https://raw.githubusercontent.com/bergware/dynamix/master/unRAIDv6/dynamix.file.integrity.plg"
)

# Modern ich777/unraid-nvidia-driver bundles the container toolkit — no separate
# install needed. A single reboot after driver install is sufficient.
for name in "${!PLUGINS[@]}"; do
    url="${PLUGINS[$name]}"
    info "  Installing: $name"
    installplg "$url" 2>/dev/null && ok "  $name installed" \
        || warn "  $name install returned non-zero (may already be installed)"
done
echo ""

# ---------------------------------------------------------------------------
# STEP 3: Docker settings
# ---------------------------------------------------------------------------
info "Step 3/7 — Writing Docker settings..."

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
# Host access to custom networks — critical for our medianet bridge network
# to be reachable from the host (e.g. bootstrap.py calling localhost:7878)
set_cfg "$DOCKER_CFG" "DOCKER_HOST_ACCESS"      "yes"
# Docker image storage on the cache SSD, not the spinning array
set_cfg "$DOCKER_CFG" "DOCKER_APP_CONFIG_PATH"  "/mnt/user/appdata"
set_cfg "$DOCKER_CFG" "DOCKER_IMAGE_PATH"        "/mnt/user/appdata"

ok "Docker settings written to $DOCKER_CFG"

# ---------------------------------------------------------------------------
# STEP 4: Global share settings (hardlinks)
# ---------------------------------------------------------------------------
info "Step 4/7 — Writing global share settings..."

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
# STEP 5: Create the data share config
# ---------------------------------------------------------------------------
info "Step 5/7 — Creating share configs..."

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

ok "Share configs written"

# ---------------------------------------------------------------------------
# STEP 6: Folder structure and permissions
# ---------------------------------------------------------------------------
info "Step 6/7 — Creating folder structure..."

# Wait for the array to be available. If this script runs before array start,
# /mnt/user won't exist yet. In that case, print the commands and exit.
if [[ ! -d /mnt/user ]]; then
    warn "/mnt/user not available — array may not be started yet."
    warn "After starting the array, run these commands manually:"
    echo ""
    echo "  mkdir -p /mnt/user/data/{usenet/{incomplete,complete/{tv,movies,music}},media/{tv,movies,music}}"
    echo "  mkdir -p /mnt/user/appdata/plex-transcode"
    echo "  chown -R nobody:users /mnt/user/data/ /mnt/user/appdata/plex-transcode"
    echo "  chmod -R a=,a+rX,u+w,g+w /mnt/user/data/"
    echo ""
else
    mkdir -p /mnt/user/data/{usenet/{incomplete,complete/{tv,movies,music}},media/{tv,movies,music}}
    mkdir -p /mnt/user/appdata/plex-transcode

    chown -R nobody:users /mnt/user/data/
    chown -R nobody:users /mnt/user/appdata/plex-transcode
    chmod -R a=,a+rX,u+w,g+w /mnt/user/data/

    ok "Folder structure created:"
    find /mnt/user/data -type d | sort | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# STEP 7: Create User Scripts
# ---------------------------------------------------------------------------
info "Step 7/7 — Creating User Scripts..."

USER_SCRIPTS_DIR="/boot/config/plugins/user.scripts/scripts"
mkdir -p "$USER_SCRIPTS_DIR"

# Monthly stack update — no credentials needed
mkdir -p "$USER_SCRIPTS_DIR/media_stack_update"
cat > "$USER_SCRIPTS_DIR/media_stack_update/script" <<'EOF'
#!/bin/bash
bash /mnt/user/appdata/homeserver/homeserver/scripts/update-stack.sh
EOF
chmod +x "$USER_SCRIPTS_DIR/media_stack_update/script"
ok "  media_stack_update created"

# Weekly appdata backup verification + optional offsite copy. Runs after the
# CA Appdata Backup plugin's own schedule; see backup-appdata.sh for details.
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
warn "    media_stack_update → Monthly (1st, 3am)"
warn "    media_stack_backup → Weekly (Sunday, 4am — after CA Appdata Backup)"

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
echo " 2. START ARRAY AND FORMAT DISKS"
echo "    Main → Start → check format boxes → Format"
echo "    Parity sync will begin (~30-45 hours, array usable during sync)"
echo ""
echo " 3. REBOOT — activate Nvidia-Driver"
echo "    Main → Reboot"
echo "    After reboot, verify:"
echo "      nvidia-smi"
echo "      docker run --rm --runtime=nvidia nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi"
echo "    If the container test fails: Apps → search 'nvidia container toolkit' → Install"
echo "    Then restart Docker (Settings → Docker → toggle off/on)"
echo ""
echo " 4. SET USER SCRIPT SCHEDULES"
echo "    Settings → User Scripts:"
echo "      media_stack_update → Monthly (1st, 3am)"
echo "      media_stack_backup → Weekly (Sunday, 4am)"
echo ""
echo " 5. (OPTIONAL) FAN CONTROL"
echo "    Only if chassis fans stay at ~100% after boot with the GPU installed:"
echo "      bash /mnt/user/appdata/homeserver/homeserver/scripts/setup-fan-control.sh"
echo ""
echo " 6. DEPLOY THE STACK"
echo "    git clone https://github.com/mihirsathe/homeserver /mnt/user/appdata/homeserver"
echo "    cd /mnt/user/appdata/homeserver/homeserver"
echo "    cp .env.example .env"
echo "    python3 scripts/generate-configs.py"
echo "    docker compose --env-file .env --env-file generated.env up -d"
echo "    python3 scripts/bootstrap.py"
echo ""
echo "========================================================"
