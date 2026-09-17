#!/bin/bash
# live-trim.sh - Trim a modules/firmware tree or 00modules.sfs against a LIVE
# system, and apply.
#
# The keep-set is computed from reality, not from build-time guesses:
#   - every /sys/bus/*/devices/*/modalias on the box, resolved through
#     modprobe -R, so anything physically attached today survives even if it
#     never loaded a driver
#   - modules currently loaded (lsmod)
#   - a persistent history DB of modules seen on earlier sessions
#   - an always-keep list: boot/release-critical modules PLUS common WiFi /
#     bluetooth dongle drivers and peripherals that are cheap to keep and make
#     the trimmed image still usable when new USB kit is plugged in later
#   - dependency closure via modules.dep
#
# Firmware is handled the way the wifi bug taught us: it loads at hotplug, so
# we take the union of modinfo -F firmware for every MODULE FILE we keep (not
# just loaded ones) plus firmware requested at boot (dmesg). Dongle modules we
# keep-but-dont-own therefore pull their firmware in automatically.
#
# Targets:
#   default   -> running kernel's /lib/modules + /lib/firmware
#   --dir X   -> X/lib/modules/<kver> + X/lib/firmware   (staged tree)
#   --sfs F   -> unsquashfs 00modules.sfs to a temp tree, trim, re-pack as
#               F-trimmed.sfs
#
# Usage:
#   bash config/live-trim.sh                                  dry-run
#   bash config/live-trim.sh --sfs ./00modules.sfs            dry-run the sfs
#   bash config/live-trim.sh --sfs ./00modules.sfs --apply --fw
#   bash config/live-trim.sh --apply --fw --force             trim live + fw
#   bash config/live-trim.sh --history /var/cache/live-trim.db
#
# Options:
#   --apply        actually delete (default is report only)
#   --fw           also prune firmware (needs modinfo; refused on the live,
#                  kernel-shared /lib/firmware unless --force)
#   --force        allow trimming the live /lib/firmware
#   --dir <root>   target tree containing lib/modules + lib/firmware
#   --sfs <file>   target is a squashfs image (00modules.sfs) to unsquash,
#                  trim and re-pack
#   --sfs-comp <c> mksquashfs compression for the re-packed sfs (default zstd)
#   --kver <ver>   version under lib/modules (default: running kernel)
#   --history <db> merge previously recorded modules; appended on --apply
#   --static      config-driven generic keep (minimize.sh set + dongles),
#                 NO machine inputs (lsmod/modalias). For staged release
#                 trees, not live boxes.

set -euo pipefail

DIR=""
SFS=""
SFS_COMP="zstd"
APPLY=0
TRIM_FW=0
FORCE=0
HISTORY=""
KVER="$(uname -r)"
EXTRACT=""
FLOOR=150
STATIC=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)     APPLY=1 ;;
        --fw)        TRIM_FW=1 ;;
        --force)     FORCE=1 ;;
        --dir)       DIR="${2:?--dir needs an argument}"; shift ;;
        --sfs)       SFS="${2:?--sfs needs an argument}"; shift ;;
        --sfs-comp)  SFS_COMP="${2:?--sfs-comp needs an argument}"; shift ;;
        --kver)      KVER="${2:?--kver needs an argument}"; shift ;;
        --history)   HISTORY="${2:?--history needs an argument}"; shift ;;
        --floor)     FLOOR="${2:?--floor needs an argument}"; shift ;;
        --static)    STATIC=1 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

cleanup() {
    [[ -n "$EXTRACT" && -d "$EXTRACT" ]] && rm -rf "$EXTRACT"
    return 0
}
trap cleanup EXIT

# ── resolve target tree ───────────────────────────────────────────────

if [[ -n "$SFS" ]]; then
    command -v unsquashfs >/dev/null || { echo "unsquashfs not found (squashfs-tools?)" >&2; exit 1; }
    command -v mksquashfs >/dev/null || { echo "mksquashfs not found (squashfs-tools?)" >&2; exit 1; }
    [[ -f "$SFS" ]] || { echo "no such sfs: $SFS" >&2; exit 1; }
    EXTRACT="$(mktemp -d)"
    echo ">>> unsquashing $SFS"
    unsquashfs -d "$EXTRACT" "$SFS" >/dev/null
    if [[ -z "$KVER" || "$KVER" == "$(uname -r)" ]]; then
        KVER="$(ls "$EXTRACT/lib/modules" 2>/dev/null | head -1 || echo "$KVER")"
        echo ">>> detected kver in sfs: $KVER"
    fi
    DIR="$EXTRACT"
    echo "note: modalias resolution uses the running system's aliases;"
    echo "      version should match the release kernel being flashed."
fi

if [[ -n "$DIR" ]]; then
    MTREE="$DIR/lib/modules/$KVER"
    FTREE="$DIR/lib/firmware"
else
    MTREE="/lib/modules/$KVER"
    FTREE="/lib/firmware"
fi

[[ -d "$MTREE" ]] || { echo "no module tree: $MTREE" >&2; exit 1; }
ALIASES="$MTREE/modules.alias"
DEPS="$MTREE/modules.dep"
[[ -f "$ALIASES" ]] || { echo "missing $ALIASES (run depmod first)" >&2; exit 1; }
[[ -f "$DEPS" ]]    || { echo "missing $DEPS (run depmod first)" >&2; exit 1; }

echo ">>> live-trim tree: $MTREE"

# ── seed keep-set ─────────────────────────────────────────────────────

declare -A seen=()
declare -A keep_rel=()
queue=()

enqueue() {
    [[ -n "$1" ]] || return 0
    [[ -n "${seen[$1]:-}" ]] && return 0
    seen["$1"]=1
    queue+=("$1")
}

# ── always-keep lists ─────────────────────────────────────────────────

# relpath prefixes: boot-critical subtrees
KEEP_PREFIX=( 'crypto/' 'lib/crypto/' 'arch/x86/crypto/' 'arch/x86/lib/' )

# basename regexes: boot/release-critical modules
KEEP_BASE=(
    '^(loop|squashfs|overlayfs?|dm_[a-z0-9_]+|sd_mod|sr_mod|usb_storage|uas)'
    '^(ehci[a-z0-9_]*|xhci[a-z0-9_]*|usbhid|hid[-_]?(generic|multitouch)|psmouse)'
    '^(ext4|btrfs|xfs|f2fs|ntfs3|vfat|exfat|fat|nls_[a-z0-9_]+)'
    '^(crc32c_intel|libcrc32c|raid6_pq|xxhash|zlib_deflate|lz4[a-z0-9_]*|zstd[a-z0-9_]*)'
)

# basename regexes: common WiFi/BT dongles + peripherals, kept even when not
# attached at trim time, so the trimmed image still "just works" on hotplug
# (kernel module FILES spell many names with dashes: snd-usb-audio.ko,
# hid-apple.ko, sdhci-pci.ko - both spellings must match)
KEEP_EXTRA=(
    '^(rtl8xxxu|rtw88[a-z0-9_]*|rtw89[a-z0-9_]*)'                       # Realtek USB/PCI
    '^(rt2x00|rt2800[a-z0-9_]*|rt73usb|rt2500usb|rt2500pci|rt61pci|rt2800pci|rt2400pci)'
    '^(mt76[-_a-z0-9]*|mt79[a-z0-9_]*)'                                # MediaTek USB/PCI
    '^(ath9k[a-z0-9_]*|ath9k_htc|ath10k[a-z0-9_]*|ath11k[a-z0-9_]*|ath12k[a-z0-9_]*)'
    '^(brcmfmac|brcmsmac|brcmutil|mwifiex[a-z0-9_]*|mwl8k|wil6210|wfx|libertas[a-z0-9_]*)'
    '^(btusb|btsdio|btintel|btbcm|btmtk|btrtl|btqca|hci_uart|bnep|rfcomm|hidp)'
    '^(usbserial|ch341|pl2303|cp210x|ftdi_sio)'                        # arduino/3d-printer USB
    '^(rtsx[-_a-z0-9]*|sdhci[-_a-z0-9]*|mmc[-_a-z0-9]*)'               # card readers
    '^(uvcvideo|snd[-_a-z0-9]*)'                                       # webcams + audio
    '^hid[-_](apple|lenovo|logitech[a-z0-9_]*)'                        # input hw
)

# basename regexes: the rest of minimize.sh's generic =m contract - GPUs, Intel
# WiFi, wired NICs, and KVM/VIRTIO/VFIO. Kept by --static so the release still
# covers "most people" hardware instead of only this box's lsmod/modalias.
KEEP_RELEASE=(
    '^(i915|amdgpu|radeon|nouveau|qxl)'                                # GPU accel
    '^(iwlwifi|iwlmei)'                                                # Intel WiFi
    '^(e1000e|e1000|e100|igb|igc|r8169|tg3|alx)'                       # wired NICs
    '^(r8152|ax88179_178a|usblp)'                                      # USB NICs + printer
    '^(kvm|kvm_intel|kvm_amd|irqbypass|virtio[a-z0-9_]*|vfio[a-z0-9_]*)'
)

should_keep() {
    local rel="$1" base
    [[ -n "${keep_rel[$rel]:-}" ]] && return 0
    for p in "${KEEP_PREFIX[@]}"; do
        [[ "$rel" == "$p"* ]] && return 0
    done
    base="$(basename "$rel")"
    for p in "${KEEP_BASE[@]}" "${KEEP_EXTRA[@]}" "${KEEP_RELEASE[@]}"; do
        [[ "$base" =~ $p\. ]] && return 0
    done
    return 1
}

name_to_rel() {
    # module names come from /proc/modules and modprobe -R with underscores,
    # but kernel module FILES spell many of them with dashes (snd_usb_audio ->
    # snd-usb-audio.ko, snd_seq_dummy -> snd-seq-dummy.ko). Match both.
    local n="$1" pat
    pat="$(printf '%s\n' "$n" | sed 's/_/[-_]/g')"
    awk -F: -v p="$pat" '$1 ~ "^kernel/.*/" p "\\.ko" {print $1}' "$DEPS"
}

# tracked history
if [[ -n "$HISTORY" && -f "$HISTORY" ]]; then
    while IFS= read -r m; do enqueue "N:$m"; done < "$HISTORY"
fi

if [[ "$STATIC" == 1 ]]; then
    # generic release trim: no live lsmod/modalias. Keep every module whose
    # basename matches the release keep rules, plus dependency closure, so
    # the shipped set is "most people" wide but not the full modules tree.
    echo ">>> static keep (no machine inputs)"
    while IFS= read -r -d '' rel; do
        rel="${rel#$MTREE/}"
        if should_keep "$rel"; then enqueue "R:$rel"; fi
    done < <(find "$MTREE" \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print0)
else
    # modules loaded right now
    while IFS=' ' read -r m _; do enqueue "N:$m"; done < /proc/modules 2>/dev/null || true

    # every device's modalias on the live box (proper glob matching via kmod)
    shopt -s nullglob
    for mf in /sys/bus/*/devices/*/modalias; do
        [[ -r "$mf" ]] || continue
        m="$(cat "$mf" 2>/dev/null || true)"
        [[ -n "$m" ]] || continue
        for mod in $(modprobe -R "$m" 2>/dev/null || true); do
            enqueue "N:$mod"
        done
    done
fi

# names -> module files -> dependencies (closure)
declare -A keep_rel=()
while [[ ${#queue[@]} -gt 0 ]]; do
    item="${queue[0]}"
    queue=("${queue[@]:1}")
    if [[ "$item" == N:* ]]; then
        for rel in $(name_to_rel "${item#N:}"); do enqueue "R:$rel"; done
    else
        rel="${item#R:}"
        keep_rel["$rel"]=1
        for d in $(awk -F: -v r="$rel" '$1==r {print $2}' "$DEPS"); do
            for dd in $d; do enqueue "R:$dd"; done
        done
    fi
done

# ── phase 1: modules ──────────────────────────────────────────────────

mapfile -d '' KO_LIST < <(find "$MTREE" \( -name '*.ko' -o -name '*.ko.zst' -o -name '*.ko.xz' -o -name '*.ko.gz' \) -print0 | sort -z)
n_ko=${#KO_LIST[@]}
declare -A del_sz=()
for rel in "${KO_LIST[@]}"; do
    rel="${rel#$MTREE/}"
    if should_keep "$rel"; then continue; fi
    del_sz["$rel"]=$(stat -c%s "$MTREE/$rel" 2>/dev/null || echo 0)
done
n_del=${#del_sz[@]}
kept=$((n_ko - n_del))
n_del_bytes=0
for s in "${del_sz[@]}"; do n_del_bytes=$((n_del_bytes + s)); done

if (( ${#del_sz[@]} > 0 )) && [[ -z "$DIR" && -z "$SFS" ]]; then
    # the live box must keep this kernel bootable; refuse an insane trim
    if (( kept < FLOOR )); then
        echo "ABORT: live --apply would keep only ${kept}/${n_ko} modules (floor ${FLOOR})." >&2
        echo "       Something is wrong with the keep-set - nothing was deleted." >&2
        echo "       Adjust with --floor if you really mean it." >&2
        exit 1
    fi
fi

if [[ "$APPLY" == 1 ]]; then
    for rel in "${!del_sz[@]}"; do rm -f "$MTREE/$rel"; done
    find "$MTREE" -depth -type d -empty -delete 2>/dev/null || true
fi
echo ">>> modules: ${n_ko} total, keeping ${kept}, deleting ${n_del} ($((n_del_bytes/1024)) KiB)"

# ── phase 2: firmware (opt-in) ────────────────────────────────────────

if [[ "$TRIM_FW" == 1 ]]; then
    [[ -d "$FTREE" ]] || { echo "no firmware tree: $FTREE - skipping firmware trim" >&2; exit 1; }
    [[ "$FORCE" == 1 || -n "$DIR" ]] || {
        echo "refusing to trim $FTREE: it is the live, kernel-shared firmware." >&2
        echo "stage into --dir first, or pass --force." >&2; exit 1; }

    declare -A fw_needed=() fw_dir=()
    # firmware from every kept MODULE FILE (dongle modules whose firmware we
    # keep-but-dont-own are covered by the keep list, not by what is loaded)
    for rel in "${!keep_rel[@]}"; do
        [[ -f "$MTREE/$rel" ]] || continue
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            fw_needed["$f"]=1
            [[ "$f" == */* ]] && fw_dir["$(dirname "$f")"]=1
        done < <(modinfo -F firmware "$MTREE/$rel" 2>/dev/null || true)
    done
    # firmware requested by the running kernel at boot
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        fw_needed["$f"]=1
        [[ "$f" == */* ]] && fw_dir["$(dirname "$f")"]=1
    done < <(dmesg 2>/dev/null | sed -n "s/.*Direct firmware load for '\([^']*\)' failed.*/\1/p" | sort -u || true)
    # collapse to top-level dirs that contain at least one needed file
    for d in "${!fw_dir[@]}"; do
        [[ "$d" == */* ]] && fw_dir["${d%%/*}"]=1
    done

    mapfile -d '' FW_LIST < <(find "$FTREE" -type f -print0 | sort -z)
    fw_total=${#FW_LIST[@]}; fw_del=0
    for abs in "${FW_LIST[@]}"; do
        rel="${abs#$FTREE/}"
        base="$(basename "$rel")"
        case "$base" in
            WHENCE|GIT-INFO|README*|LICEN*|COPYING) continue ;;
        esac
        if [[ -n "${fw_needed[$rel]:-}" ]]; then continue; fi
        if [[ -n "${fw_dir[${rel%%/*}]:-}" ]]; then continue; fi
        fw_del=$((fw_del+1))
        [[ "$APPLY" == 1 ]] && rm -f "$abs"
    done
    echo ">>> firmware: ${fw_total} files, keeping $((fw_total-fw_del)), deleting ${fw_del}"
fi

# ── phase 3: finalize ─────────────────────────────────────────────────

if [[ "$APPLY" == 1 ]]; then
    if [[ -n "$DIR" ]]; then
        depmod -b "$DIR" "$KVER"
    else
        depmod -a
    fi
    echo ">>> regenerated depmod maps for $KVER"
    if [[ -n "$HISTORY" ]]; then
        mkdir -p "$(dirname "$HISTORY")"
        for rel in "${!keep_rel[@]}"; do basename "${rel%%.*}" >> "$HISTORY"; done
        sort -u "$HISTORY" -o "$HISTORY"
    fi
fi

# ── phase 4: re-pack sfs ──────────────────────────────────────────────

if [[ -n "$SFS" && "$APPLY" == 1 ]]; then
    out="${SFS%.sfs}-trimmed.sfs"
    # only include what was in the original (root of the sfs)
    mksquashfs "$EXTRACT" "$out" -comp "$SFS_COMP" -no-progress -noappend >/dev/null
    echo ">>> wrote $out"
    echo "    (mount it at boot instead of $SFS, or 'mv $out $SFS' to replace)"
fi

if [[ "$TRIM_FW" == 1 ]]; then
    echo "(dry-run: pass --apply to delete; firmware dirs containing needed files are kept)"
elif [[ "$APPLY" != 1 ]]; then
    echo "(dry-run only - pass --apply to delete modules)"
fi