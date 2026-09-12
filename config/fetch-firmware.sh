#!/bin/bash
# fetch-firmware.sh - Populate stage firmware from one of 4 sources.
#
# Usage: bash config/fetch-firmware.sh <set> <stage-dir>
#   sets: fdrv   - Puppy fdrv_large.sfs only (47MB, 2021 vintage)
#         blend  - fdrv base + modern overlay (missing dirs from linux-firmware)
#         vdpup  - Puppy vdpup SFS (set VDPUP_URL)
#         modern - full upstream linux-firmware (no trimming)
#
# Writes <stage-dir>/lib/firmware and echoes its size.

set -euo pipefail

SET="${1:?usage: fetch-firmware.sh <fdrv|blend|vdpup|modern> <stage-dir>}"
STAGE="${2:?usage: fetch-firmware.sh <fdrv|blend|vdpup|modern> <stage-dir>}"

FDRV_URL="https://downloads.sourceforge.net/project/lxpup/Other/huge-kernels/fdrv_large.sfs"
VDPUP_URL="${VDPUP_URL:-https://gitlab.com/firstrib/firstrib/-/raw/master/latest/build_system/huge_kernels/kernel_usrmerge_default/01firmware.sfs?ref_type=heads&inline=false}"
FW="$STAGE/lib/firmware"

case "$SET" in

fdrv)
    echo ">>> firmware set: fdrv (Puppy fdrv_large.sfs)"
    curl -sL "$FDRV_URL" -o /tmp/fdrv_large.sfs
    unsquashfs -f -d /tmp/fdrv_extract /tmp/fdrv_large.sfs >/dev/null
    mkdir -p "$FW"
    cp -a /tmp/fdrv_extract/lib/firmware/. "$FW/"
    ;;

vdpup)
    echo ">>> firmware set: vdpup (FirstRib 01firmware.sfs)"
    curl -sL "$VDPUP_URL" -o /tmp/vdpup.sfs
    unsquashfs -f -d /tmp/vdpup_extract /tmp/vdpup.sfs >/dev/null
    mkdir -p "$FW"
    if [ -d /tmp/vdpup_extract/usr/lib/firmware ]; then
        cp -a /tmp/vdpup_extract/usr/lib/firmware/. "$FW/"
    elif [ -d /tmp/vdpup_extract/lib/firmware ]; then
        cp -a /tmp/vdpup_extract/lib/firmware/. "$FW/"
    elif [ -d /tmp/vdpup_extract/firmware ]; then
        cp -a /tmp/vdpup_extract/firmware/. "$FW/"
    else
        echo "unknown vdpup layout: $(ls /tmp/vdpup_extract)" >&2
        exit 1
    fi
    ;;

blend)
    echo ">>> firmware set: blend (fdrv base + modern overlay)"
    curl -sL "$FDRV_URL" -o /tmp/fdrv_large.sfs
    unsquashfs -f -d /tmp/fdrv_extract /tmp/fdrv_large.sfs >/dev/null
    mkdir -p "$FW"
    cp -a /tmp/fdrv_extract/lib/firmware/. "$FW/"

    echo ">>> overlay modern linux-firmware dirs"
    git clone --depth 1 \
        https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
        /tmp/lfw
    OVERLAY=(
        amdgpu amdnpu radeon i915
        intel/iwlwifi iwlwifi
        sof
        rtw88 rtw89 rtlwifi rtl_bt rtl_nic
        ath10k ath11k ath12k qca ath3k
        mediatek brcm cypress
        bnx2x
    )
    for d in "${OVERLAY[@]}"; do
        if [ -d "/tmp/lfw/$d" ]; then
            mkdir -p "$FW/$(dirname "$d")"
            cp -a "/tmp/lfw/$d" "$FW/$d"
        else
            echo "    (skip $d - not in linux-firmware)"
        fi
    done
    ;;

modern)
    echo ">>> firmware set: modern (full linux-firmware)"
    git clone --depth 1 \
        https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
        /tmp/lfw
    mkdir -p "$FW"
    cp -a /tmp/lfw/. "$FW/"
    ;;

*)
    echo "unknown firmware set: $SET" >&2
    exit 1
    ;;
esac

echo ">>> firmware total: $(du -sh "$FW" | cut -f1)"