#!/bin/bash
# =============================================================================
# seed-share-structure.sh — pre-create the category skeleton on every array disk
#
# WHY THIS EXISTS:
#
#   The `data` share uses shareAllocator=highwater with shareSplitLevel=0.
#   Under those settings Unraid's user-share allocator picks a disk for a
#   given path exactly ONCE — the first time that path is created — and
#   pins every subsequent write into the same path to that disk forever,
#   regardless of free-space balance across the array.
#
#   Bulk-seeding the media library (import everything at once) creates
#   every category folder — media/movies, media/tv, media/music,
#   usenet/complete/*, imports/* — on whichever disk the allocator picked
#   first (usually disk1). From then on every new episode of an existing
#   show, every sequel in an existing series, every ripped album ends up
#   on that same disk, while disk2..N sit near-empty. Eventually the
#   pinned disk fills up, writes start ENOSPC-ing, and no amount of
#   parity/rebalance changes it — the pinning is a property of the
#   allocator's per-path decision, not the underlying storage.
#
#   The fix is to pre-create the SAME top-level category paths on every
#   disk in the array before any real data is written. Once each category
#   exists on every disk, the allocator's per-path pin still applies but
#   it now sees N candidate targets for each category and falls back to
#   its normal free-space-based selection when a new subfolder (a new
#   show, a new movie folder) is created inside the category.
#
#   This is idempotent — safe to re-run any time, and required after
#   adding a new disk to the array (otherwise the new disk starts empty
#   and the allocator will never pick it for existing categories).
#
# WHEN TO RUN:
#
#   • Automatically on first deploy (called by setup-unraid.sh).
#   • Automatically at every array start, before docker compose up
#     (called by the media_stack_up User Script).
#   • Manually after adding a disk to the array (see docs/operations.md
#     Maintenance Schedule row: "Re-seed disk folder structure").
#
# WHAT IT SEEDS:
#
#   The categories match the ones that generate-configs.py + the compose
#   stack expect. See CLAUDE.md § "Files on the Server" for the source
#   of truth.
# =============================================================================

set -euo pipefail

# Categories that any *arr, SAB, or manual-import workflow will write into.
# Order does not matter; the list is the authoritative shape of `data/`.
CATEGORIES=(
    "media/movies"
    "media/tv"
    "media/music"
    "usenet/complete/movies"
    "usenet/complete/tv"
    "usenet/complete/music"
    "imports/movies"
    "imports/tv"
    "imports/unsorted"
)

# Colour helpers — silently degrade if stdout isn't a tty.
if [[ -t 1 ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_INFO=$'\e[36m'; C_END=$'\e[0m'
else
    C_OK=""; C_WARN=""; C_INFO=""; C_END=""
fi

info()  { echo "${C_INFO}==>${C_END} $*"; }
ok()    { echo "${C_OK}  ✓${C_END} $*"; }
warn()  { echo "${C_WARN}  ! $*${C_END}"; }

# Only run on Unraid (or a sandbox that fakes /mnt/disk*). /mnt/user is the
# FUSE user-share layer; it MUST NOT be written to directly for this fix
# because writes through /mnt/user go through the very allocator we're
# trying to work around. We write to /mnt/disk* directly.
shopt -s nullglob
DISKS=(/mnt/disk[0-9]*)
shopt -u nullglob

if [[ ${#DISKS[@]} -eq 0 ]]; then
    warn "No /mnt/disk* mounts found — array not started, or non-Unraid host."
    warn "  Nothing to seed. This script is a no-op outside Unraid."
    exit 0
fi

info "Seeding category skeleton across ${#DISKS[@]} array disk(s)..."

created_total=0
already_total=0

for disk in "${DISKS[@]}"; do
    # Skip parity, cache, or pool mounts that happen to match the glob but
    # aren't array data disks. Real data disks are /mnt/diskN where N is a
    # small integer and the mount contains a `data` share dir after seeding,
    # or is at least writable now.
    if [[ ! -w "$disk" ]]; then
        warn "$disk not writable — skipping"
        continue
    fi

    disk_created=0
    disk_existed=0
    for cat in "${CATEGORIES[@]}"; do
        target="$disk/data/$cat"
        if [[ -d "$target" ]]; then
            disk_existed=$((disk_existed + 1))
            continue
        fi

        # `mkdir -p` walks the leading path and creates whatever's missing.
        # We only want to chown/chmod things this script actually creates —
        # never recurse into an existing library. Walk down manually so we
        # can tell "just created" from "already there" per component.
        components=()
        IFS='/' read -ra parts <<<"data/$cat"
        for part in "${parts[@]}"; do
            components+=("$part")
        done
        prefix="$disk"
        for part in "${components[@]}"; do
            prefix="$prefix/$part"
            if [[ ! -d "$prefix" ]]; then
                mkdir "$prefix"
                # Match the ownership + perms setup-unraid.sh uses for the
                # top-level data tree. NEVER -R — the only directory we touch
                # is the one we just created, on this single iteration.
                chown nobody:users "$prefix" 2>/dev/null || true
                chmod u=rwx,g=rwx,o= "$prefix" 2>/dev/null || true
            fi
        done
        disk_created=$((disk_created + 1))
    done

    if [[ $disk_created -gt 0 ]]; then
        ok "$disk: created $disk_created, already present $disk_existed"
    else
        ok "$disk: all ${#CATEGORIES[@]} categories already present"
    fi
    created_total=$((created_total + disk_created))
    already_total=$((already_total + disk_existed))
done

echo
info "Summary: $created_total folder(s) created, $already_total already present, across ${#DISKS[@]} disk(s)."
