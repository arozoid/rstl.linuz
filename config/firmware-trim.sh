#!/bin/bash
# firmware-trim.sh - Cut a linux-firmware tree down to exactly what a release
# ships: whitelist at top level (drivers enabled in config/minimize.sh), then
# prune every kept directory to the firmware files the shipped kernel modules
# actually request (modinfo -F firmware). Runtime-loaded Bluetooth familes and
# GPU blobs are kept whole on purpose - their filenames are chosen by the
# device at run time, not by modinfo.
#
# Usage:
#   firmware-trim.sh <firmware-dir> [--modules <modules-dir>] [--dry-run]
#
#   <firmware-dir>  a linux-firmware checkout, or an extracted lib/firmware
#   --modules       pointer to the module tree this release ships
#                   (e.g. stage/lib/modules/<kver> or /lib/modules/<kver>);
#                   when given, every non-exempt firmware file is dropped
#                   unless a shipped module requests it by name
#   --dry-run       report what would be deleted without touching anything
#
# Kept whole by whitelist (top level):
#   amdgpu / radeon / i915 / amdnpu   GPU firmware (+ nvram/cap .txt)
#   brcm / cypress                    Broadcom-Cypress WiFi+BT (+ nvram .txt)
#   rtl_bt / qca / ar3k               runtime-loaded Bluetooth families
#   intel/ibt-*                       Intel runtime-loaded Bluetooth
#
# Kept only-if-requested instead (pruned by modinfo):
#   intel/iwlwifi                     64 files for a modern kernel vs ~600 in-tree
#   ath6k ath10k ath11k ath12k mediatek mwifiex rtw88 rtw89 rtlwifi
#   rtl_nic e100 e1000                wired NIC blobs
#   top-level blobs                   rt73/rt2870/htc_9271/ar9170/mt76*/wil6210
#
# Note: CPU microcode and Sound Open Firmware are NOT kept - add separately.

set -euo pipefail

FW=""
MODULES=""
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --modules) MODULES="${2:?--modules needs a path}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) FW="$1"; shift ;;
    esac
done

[ -n "$FW" ] || {
    echo "usage: firmware-trim.sh <firmware-dir> [--modules <dir>] [--dry-run]" >&2
    exit 1
}
# Resolve paths to absolute BEFORE cd'ing into the firmware tree, since the
# modules dir is usually given relative to the release root.
case "$FW" in /*) ;; *) FW="$(pwd -P)/$FW" ;; esac
[ -d "$FW" ] || { echo "not a directory: $FW" >&2; exit 1; }
if [ -n "$MODULES" ]; then
    case "$MODULES" in /*) ;; *) MODULES="$(pwd -P)/$MODULES" ;; esac
fi
cd "$FW"

if [ ! -f WHENCE ]; then
    echo "WARNING: no WHENCE - this does not look like a full linux-firmware tree"
fi

echo ">>> firmware size before: $(du -sh . | cut -f1)"

# ── Step 1: whitelist the top level (mirrors config/minimize.sh) ─────
KEEP_DIRS=(
    amdgpu         # AMD GPU
    radeon         # legacy AMD GPU
    amdnpu         # AMD NPU
    i915           # Intel GPU
    intel          # pruned below -> iwlwifi + intel/ibt-* (BT) only
    rtw89          # Realtek WiFi 7 (rtw89 family)
    rtw88          # Realtek WiFi 6 (rtw88 family)
    rtlwifi        # older Realtek WiFi
    rtl_bt         # Realtek Bluetooth (runtime-loaded names)
    ath6k          # Qualcomm Atheros ath6kl WiFi
    ath10k         # Qualcomm WiFi (QCA61xx/QCA99xx...)
    ath11k         # Qualcomm WiFi (WCN6750/WCN6855/QCA6390...)
    ath12k         # Qualcomm WiFi (QCN9274/WCN7850...)
    ar3k           # Qualcomm Atheros Bluetooth (ath3k)
    qca            # Qualcomm Bluetooth (runtime-loaded names)
    mwifiex        # Marvell WiFi (mwifiex_sdio/mwifiex_pcie)
    mrvl           # Marvell WiFi firmware (requested by mwifiex)
    nvidia         # nouveau GPU firmware
    sof            # Sound Open Firmware (runtime-named -> kept whole)
    mediatek       # MediaTek WiFi + BT (mt76 family)
    brcm           # Broadcom WiFi + Bluetooth (+ nvram .txt)
    cypress        # Cypress WiFi + Bluetooth
    rtl_nic        # Realtek r8169/rtl815x ethernet
    e100           # Intel PRO/100 ethernet
    e1000          # Intel gigabit ethernet
)
# Dir trees kept whole (bitmap above excludes runtime-named file families).
KEEP_WHOLE=(
    amdgpu radeon amdnpu i915 nvidia sof
    brcm cypress rtl_bt qca ar3k
)

echo ">>> Removing unneeded top-level directories"
rm_dirs=0
dirs=()
for d in */; do
    dirs+=("${d%/}")
done
for d in "${dirs[@]}"; do
    keep=0
    for k in "${KEEP_DIRS[@]}"; do
        [ "$d" = "$k" ] && keep=1
    done
    if [ "$keep" != 1 ]; then
        rm_dirs=$((rm_dirs+1))
        [ "$DRY" = 1 ] || rm -rf "$d"
    fi
done
[ "$DRY" = 1 ] && echo "    (dry-run: would remove ${rm_dirs} top-level directories)"

echo ">>> Pruning intel/ -> iwlwifi + Bluetooth (ibt-*) only"
if [ "$DRY" = 1 ]; then
    extras=$(find intel -mindepth 1 -maxdepth 1 \
        \( -name iwlwifi -o -name 'ibt-*' \) -prune -o -print | wc -l)
    echo "    (dry-run: would remove ${extras} entries from intel/)"
else
    find intel -mindepth 1 -maxdepth 1 \
        \( -name iwlwifi -o -name 'ibt-*' \) -prune -o -exec rm -rf {} +
fi

echo ">>> Removing legacy top-level blobs (ancient drivers)"
shopt -s nullglob
for f in *; do
    [ -d "$f" ] && continue
    case "$f" in
        WHENCE|GIT-INFO|README*)                : ;;
        LICENCE*|LICENSE*|COPYING|GPL*)          : ;;
        regulatory.db|regulatory.db.p7s)         : ;;  # wireless regdb (loaded by kernel directly)
        iwlwifi-*.ucode|iwlegacy-*)              : ;;  # not under intel/ in some trees
        mt76*.bin)                              : ;;  # mt76 USB/PCI (mt7601u/mt76x0/mt76x2...)
        rt73.bin|rt2870.bin)                    : ;;  # rt2x00 USB (rt73usb/rt2800usb)
        htc_9271.fw|htc_7010.fw)                : ;;  # ath9k_htc USB
        ar9170_*.fw)                            : ;;  # carl9170 USB
        wil6210-*)                              : ;;  # wil6210 60GHz
        *) [ "$DRY" = 1 ] || rm -f "$f" ;;
    esac
done

if [ -n "$MODULES" ]; then
    command -v modinfo >/dev/null 2>&1 || {
        echo "ERROR: --modules given but modinfo not found" >&2; exit 1; }
    [ -d "$MODULES" ] || {
        echo "ERROR: --modules path not found: $MODULES" >&2; exit 1; }
    echo ">>> Collecting firmware references from modules: $MODULES"
    needed=$(mktemp)
    find "$MODULES" \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' \
        -o -name '*.ko.gz' \) -print0 2>/dev/null |
        xargs -0 -P"$(nproc 2>/dev/null || echo 8)" -n1 \
            modinfo -F firmware 2>/dev/null |
        while IFS= read -r f; do basename "$f"; done |
        sort -u > "$needed"
    total=$(wc -l < "$needed")
    echo "    ${total} distinct firmware files requested"

    is_whole() { # $1 = top-level dir
        local d=$1
        for k in "${KEEP_WHOLE[@]}"; do [ "$d" = "$k" ] && return 0; done
        return 1
    }

    rm_count=0
    rm_bytes=0
    while IFS= read -r -d '' p; do
        rel=${p#./}
        base=${p##*/}
        top=${rel%%/*}
        case "$base" in
            WHENCE|GIT-INFO|README*)  continue ;;
            LICENCE*|LICENSE*|COPYING|GPL*) continue ;;
            regulatory.db|regulatory.db.p7s) continue ;;
        esac
        [ "$top" = intel ] && [[ "$rel" =~ ^intel/ibt- ]] && continue
        is_whole "$top" && continue
        grep -qxF "$base" "$needed" && continue
        rm_count=$((rm_count+1))
        rm_bytes=$((rm_bytes + $(stat -c%s "$p" 2>/dev/null || echo 0)))
        [ "$DRY" = 1 ] || rm -f "$p"
    done < <(find . -type f -print0)

    find . -depth -type d -empty -delete 2>/dev/null || true

    if [ "$DRY" = 1 ]; then
        echo ">>> dry-run: would delete ${rm_count} files (~$((rm_bytes/1048576)) MiB)"
    else
        echo ">>> deleted ${rm_count} firmware files (~$((rm_bytes/1048576)) MiB)"
    fi
    rm -f "$needed"
else
    echo ">>> --modules not given - skipping requested-fw prune"
fi

echo ">>> firmware size after:  $(du -sh . | cut -f1)"