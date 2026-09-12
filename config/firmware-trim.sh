#!/bin/bash
# firmware-trim.sh - Reduce a linux-firmware checkout to only the firmware
# needed by the drivers we enable (see config/minimize.sh).
#
# Usage: bash config/firmware-trim.sh /path/to/linux-firmware
#
# Whitelist-based: every top-level directory NOT listed below is removed,
# so it always mirrors exactly what we keep (no stale leftover blobs).
#
# Keeps:
#   amdgpu / radeon / i915      GPU firmware
#   intel/iwlwifi (only)        Intel WiFi
#   iwlwifi (dir) / iwlegacy    legacy Intel WiFi (3945/4965/...)
#   rtw89 rtw88 rtlwifi rtl_bt  Realtek WiFi + Bluetooth
#   ath10k                      Qualcomm WiFi (older QCA)
#   mediatek                    MT79xx WiFi (+ BT)
#   brcm / cypress              Broadcom / Cypress WiFi + BT
#
# Note: CPU microcode (intel-ucode/amd-ucode) and Sound Open Firmware
# (sof/) are intentionally NOT kept - add them back if you need them.

set -euo pipefail

FW="${1:?usage: firmware-trim.sh <firmware-dir>}"
cd "$FW"

[ -f WHENCE ] || { echo "not a linux-firmware tree: $FW" >&2; exit 1; }

echo ">>> firmware size before: $(du -sh . | cut -f1)"

KEEP_DIRS=(
    amdgpu         # AMD GPU
    radeon         # legacy AMD GPU
    i915           # Intel GPU
    intel          # pruned below -> iwlwifi only
    iwlwifi        # legacy Intel WiFi (3945/4965/5000/6000...)
    iwlegacy       # iwl3945/iwl4965 ucode
    rtw89          # Realtek WiFi 7 (rtw89 family)
    rtw88          # Realtek WiFi 6 (rtw88 family)
    rtlwifi        # older Realtek WiFi
    rtl_bt         # Realtek Bluetooth
    ath10k         # Qualcomm WiFi (older QCA61xx/QCA99xx...)
    mediatek       # MediaTek WiFi (mt7915/mt7921/mt7925/mt7927/mt7996)
    brcm           # Broadcom WiFi + Bluetooth
    cypress        # Cypress WiFi + Bluetooth
)

echo ">>> Removing unneeded top-level directories"
dirs=()
for d in */; do
    dirs+=("${d%/}")
done
for d in "${dirs[@]}"; do
    keep=0
    for k in "${KEEP_DIRS[@]}"; do
        [ "$d" = "$k" ] && keep=1
    done
    [ "$keep" = 1 ] || rm -rf "$d"
done

echo ">>> Removing top-level firmware blobs (ancient drivers)"
shopt -s nullglob
for f in *; do
    [ -d "$f" ] && continue
    case "$f" in
        WHENCE|GIT-INFO|README*)                : ;;
        LICENCE*|LICENSE*|COPYING|GPL*)          : ;;
        iwlwifi-*.ucode|iwlegacy-*)              : ;;
        *)                                       rm -f "$f" ;;
    esac
done

echo ">>> Pruning intel/ -> iwlwifi only"
find intel -mindepth 1 -maxdepth 1 ! -name iwlwifi -exec rm -rf {} +

echo ">>> firmware size after:  $(du -sh . | cut -f1)"
