#!/bin/bash
# =============================================================================
# setup-fan-control.sh — iDRAC fan control (OPT-IN, run only if needed)
# =============================================================================
# When you install a non-Dell GPU (e.g. the RTX 3050) in the R640, iDRAC's
# Third-Party PCIe Card fan response ramps all chassis fans to ~100% because
# it can't read the card's thermistors. Audibly: jet engine.
#
# This script tells iDRAC to back off and fixes fans at a manual, sane offset.
# Only run this AFTER installing the GPU and confirming the fans are in fact
# loud — on a stock R640 with Dell-sanctioned peripherals there is nothing to fix.
#
# What this writes:
#   /boot/config/plugins/user.scripts/scripts/fan_control/.env     (mode 600)
#   /boot/config/plugins/user.scripts/scripts/fan_control/script   (mode 755)
#
# Then in the Unraid UI:
#   Settings → User Scripts → fan_control → Schedule: At Startup of Array
#
# Why credentials go in a separate .env file, not baked into the script:
# /boot is exposed on the Unraid "flash" SMB share. The iDRAC password gives
# full out-of-band control of the host. Keeping it in a 0600 file (still on
# flash, but not world-readable through SMB mounts) is the pragmatic middle
# ground. Delete /boot/config/plugins/user.scripts/scripts/fan_control/.env
# to revoke.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run as root"
[[ ! -d /boot/config ]] && die "/boot/config not found — is this Unraid?"

USER_SCRIPTS_DIR="/boot/config/plugins/user.scripts/scripts"
FAN_DIR="$USER_SCRIPTS_DIR/fan_control"
mkdir -p "$FAN_DIR"

info "Fan control setup — iDRAC credentials required."
echo ""
read -rp "  iDRAC IP address: "  IDRAC_IP
read -rp "  iDRAC username [root]: " IDRAC_USER
IDRAC_USER="${IDRAC_USER:-root}"
read -rsp "  iDRAC password: " IDRAC_PASS
echo ""
echo ""

# Write credentials to a 0600 file that the fan_control script sources.
# Creating with restrictive umask first avoids a race where the file is
# briefly world-readable before chmod lands.
(umask 077 && cat > "$FAN_DIR/.env" <<EOF
IDRAC_IP="${IDRAC_IP}"
IDRAC_USER="${IDRAC_USER}"
IDRAC_PASS="${IDRAC_PASS}"
EOF
)
chmod 600 "$FAN_DIR/.env"
ok "  Credentials written to $FAN_DIR/.env (mode 0600)"

# Fan control script — sources the .env, does not bake values.
# <<'EOF' (quoted) prevents this outer shell from expanding $IDRAC_* inside.
cat > "$FAN_DIR/script" <<'EOF'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"
sleep 30  # wait for iDRAC + network to be fully up after Unraid boot
racadm -r "$IDRAC_IP" -u "$IDRAC_USER" -p "$IDRAC_PASS" set system.thermalsettings.ThirdPartyPCIFanResponse 0
racadm -r "$IDRAC_IP" -u "$IDRAC_USER" -p "$IDRAC_PASS" set system.thermalsettings.ThermalProfile 2
racadm -r "$IDRAC_IP" -u "$IDRAC_USER" -p "$IDRAC_PASS" set system.thermalsettings.FanSpeedOffset 255
EOF
chmod +x "$FAN_DIR/script"
ok "  fan_control script created"

echo ""
warn "Manual step remaining:"
warn "  Settings → User Scripts → fan_control → Schedule: At Startup of Array"
echo ""
ok "Done. To revoke credentials later: rm $FAN_DIR/.env"
