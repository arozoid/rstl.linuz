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
#   intel/iwlwifi (only)        Intel WiFi (+ intel/ibt-* Bluetooth)
#   iwlwifi-*.ucode / iwlegacy  legacy Intel WiFi (3945/4965/...)
#   rtw89 rtw88 rtlwifi rtl_bt  Realtek WiFi + Bluetooth
#   rt73 / rt2870 blobs         rt2x00 USB dongles (rt73usb/rt2800usb)
#   ath6k ath9k ath10k/11k/12k  Qualcomm Atheros WiFi (+ htc/ar9170 top blobs)
#   mwifiex                     Marvell WiFi
#   mediatek                    MT76xx WiFi (+ BT)
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
    intel          # pruned below -> iwlwifi + intel/ibt-* (BT) only
    rtw89          # Realtek WiFi 7 (rtw89 family)
    rtw88          # Realtek WiFi 6 (rtw88 family)
    rtlwifi        # older Realtek WiFi
    rtl_bt         # Realtek Bluetooth
    ath6k          # Qualcomm Atheros ath6kl WiFi
    ath10k         # Qualcomm WiFi (QCA61xx/QCA99xx...)
    ath11k         # Qualcomm WiFi (WCN6750/WCN6855/QCA6390...)
    ath12k         # Qualcomm WiFi (QCN9274/WCN7850...)
    ar3k           # Qualcomm Atheros Bluetooth (ath3k)
    qca            # Qualcomm Bluetooth (btqca/WCN399x) + some QCA WiFi
    mwifiex        # Marvell WiFi (mwifiex_sdio/mwifiex_pcie)
    mediatek       # MediaTek WiFi + BT (mt7603/mt7615/mt7915/mt7921/mt7925/mt7927/mt7996)
    brcm           # Broadcom WiFi + Bluetooth
    cypress        # Cypress WiFi + Bluetooth
    rtl_nic        # Realtek r8169 ethernet (enabled in minimize.sh)
    e100           # Intel PRO/100 ethernet
    e1000          # Intel gigabit ethernet
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
        mt76*.bin)                              : ;;  # mt76 USB/PCI (mt7601u/mt76x0/mt76x2...)
        rt73.bin|rt2870.bin)                    : ;;  # rt2x00 USB (rt73usb/rt2800usb)
        htc_9271.fw|htc_7010.fw)                : ;;  # ath9k_htc USB
        ar9170_*.fw)                            : ;;  # carl9170 USB
        wil6210-*)                              : ;;  # wil6210 60GHz
        *)                                       rm -f "$f" ;;
    esac
done

echo ">>> Pruning intel/ -> iwlwifi + Bluetooth (ibt-*) only"
find intel -mindepth 1 -maxdepth 1 \
    \( -name iwlwifi -o -name 'ibt-*' \) -prune -o -exec rm -rf {} +

echo ">>> firmware size after:  $(du -sh . | cut -f1)"
