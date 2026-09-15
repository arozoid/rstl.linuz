#!/bin/bash
# minimize.sh - Strip CachyOS BORE config to lean desktop essentials
# Run from the kernel source directory (where .config lives)
#
# What stays:
#   i915 / amdgpu / nouveau, USB/BT/webcams, NVMe/AHCI/USB-storage,
#   ext4/btrfs/xfs/f2fs/squashfs/overlayfs, Intel+AMD microcode,
#   iwlwifi/rtw/mt76/ath WiFi, common ethernet, KVM/VFIO, ZSTD compression
#
# What goes:
#   Infiniband, Firewire, Token Ring, ISDN, IIO, most TV tuners,
#   obscure SCSI/RAID, industrial IO, debug/selftest, Xen, and other
#   non-essential subsystems

set -euo pipefail

if [ ! -f .config ]; then
    echo "ERROR: .config not found. Run from kernel source directory." >&2
    exit 1
fi

cfg() { scripts/config "$@"; }
disable() { cfg -d "$@"; }

echo ">>> Enabling BORE scheduler + CachyOS tweaks"
cfg -e SCHED_BORE
cfg -e CACHY

echo ">>> Ensuring ZSTD kernel compression"
cfg -e KERNEL_ZSTD
for c in GZIP BZIP2 LZMA XZ LZO LZ4; do
    cfg -d "KERNEL_${c}"
done

# ── Subsystems to nuke entirely ───────────────────────────────────────

echo ">>> Nuking: Infiniband"
disable INFINIBAND

echo ">>> Nuking: Firewire"
disable FIREWIRE

echo ">>> Nuking: Industrial I/O"
disable IIO

echo ">>> Nuking: CAN bus"
disable CAN

echo ">>> Nuking: NFC"
disable NFC

echo ">>> Nuking: WWAN"
disable WWAN

echo ">>> Nuking: Phonet"
disable PHONET

echo ">>> Nuking: ATM"
disable ATM

echo ">>> Nuking: 6LoWPAN"
disable 6LOWPAN

# Already removed from modern kernels but be safe
disable ISDN
disable TR

# ── Networking extras ─────────────────────────────────────────────────

echo ">>> Nuking: exotic network protocols"
for p in TIPC RDS SMC MPTCP NET_DSA IP_VS ATM ATALK DECnet X25 LAPB \
         PHONET ECONET; do
    disable "$p"
done

# ── Obscure SCSI / RAID controllers ──────────────────────────────────

echo ">>> Nuking: obscure SCSI/RAID"

# Legacy / server-only RAID
for scsi in \
    SCSI_AACRAID SCSI_MEGARAID SCSI_MEGARAID_NEWGEN SCSI_MEGARAID_LEGACY \
    SCSI_HPSA SCSI_SMARTPQI SCSI_MPI3SAS \
    SCSI_MPT2SAS SCSI_MPT3SAS \
    SCSI_QLA_ISCSI SCSI_LPFC SCSI_BNX2X_FCOE SCSI_BNX2_ISCSI \
    SCSI_BFA_FC SCSI_BFC SCSI_QEDF SCSI_QED \
    SCSI_CXGB3_ISCSI SCSI_CXGB4_ISCSI SCSI_CXGB3 SCSI_CXGB4 SCSI_CXGB \
    BE2ISCSI \
    SCSI_MYRB SCSI_MYRS \
    SCSI_3W_9XXX SCSI_3W_SAS SCSI_3W_X \
    SCSI_ACARD SCSI_AHA152X SCSI_AHA1542 SCSI_AHA1740 \
    SCSI_AIC79XX SCSI_AIC7XXX SCSI_AIC94XX \
    SCSI_ARCMSR SCSI_ESAS2R \
    SCSI_MVSAS SCSI_MVUMI SCSI_PM8001 \
    SCSI_SRP SCSI_SVRIONS SCSI_SRM40 \
    SCSI_STEX SCSI_ISCI \
    SCSI_GDTH SCSI_INIA100 SCSI_INITIO SCSI_IPS \
    SCSI_SYM53C8XX_2 \
    SCSI_IBMVFC SCSI_IBMVFCOS \
    SCSI_BHB \
    VMWARE_PVSCSI \
    SCSI_TCM_QLA2XXX SCSI_TCM_IBMVFC SCSI_TCM_IBMVFCOS SCSI_TCM_S390 \
    SCSI_CNQFC \
    ; do
    disable "$scsi"
done

# ── TV tuners / DVB ──────────────────────────────────────────────────

echo ">>> Nuking: DVB + analog/digital TV (keeping V4L2 for webcams)"
disable DVB
disable MEDIA_ANALOG_TV_SUPPORT
disable MEDIA_DIGITAL_TV_SUPPORT
disable MEDIA_SDR_SUPPORT
disable MEDIA_TEST_SUPPORT
# MEDIA_CAMERA_SUPPORT stays on (needed for webcams)

# ── GPU trimming ──────────────────────────────────────────────────────

echo ">>> Trimming GPU drivers"

# Drop GMA500 / Poulsbo
disable DRM_GMA500

# Drop Radeon (keep only amdgpu)
disable DRM_RADEON

# Drop other old/obscure GPU drivers
for oldgpu in DRM_VIA DRM_SAVAGE DRM_SIS DRM_TDFX \
              DRM_VMWGFX DRM_QXL DRM_BOCHS DRM_CIRRUS_QEMU DRM_VBOXVIDEO \
              DRM_AST DRM_MGAG200 DRM_NOUVEAU_DEBUG DRM_NOUVEAU_GPUDISABLE; do
    disable "$oldgpu"
done

# i915: drop error capture / compression (saves bloat, not needed on desktop)
cfg -d DRM_I915_CAPTURE_ERROR
cfg -d DRM_I915_COMPRESS_ERROR

# amdgpu: keep but disable legacy Southern Islands / Sea Islands if not needed
# (these are for GCN1-3 era AMD GPUs, ~2012-2015)
# Comment these out if you still have old AMD GPUs:
# cfg -d DRM_AMDGPU_SI
# cfg -d DRM_AMDGPU_CIK

# ── Debug / selftest ──────────────────────────────────────────────────

echo ">>> Nuking: debug & selftest"

cfg -d DEBUG_KERNEL
cfg -d DEBUG_INFO
cfg -d DEBUG_INFO_DWARF5
cfg -d DEBUG_INFO_DWARF4
cfg -d DEBUG_INFO_NONE
cfg -d DEBUG_INFO_SPLIT
cfg -d DEBUG_INFO_BTF
cfg -d DEBUG_INFO_BTF_MODULES
cfg -d DEBUG_INFO_REDUCED
cfg -d DEBUG_INFO_MINIMAL
cfg -d COMPILE_TEST
cfg -d WERROR

# Tracing
for t in FTRACE FUNCTION_TRACER FUNCTION_GRAPH_TRACER \
         STACK_TRACER IRQSOFF_TRACER PREEMPTOFF_TRACER \
         TRACER_SNAPSHOT TRACER_SNAPSHOT_PER_CPU_SWAP \
         KPROBES UPROBES KPROBE_EVENTS UPROBE_EVENTS \
         FTRACE_SYSCALLS DYNAMIC_FTRACE DYNAMIC_EVENTS \
         FILTER_TRACER_FUNCTION_TRACER_DEFAULT; do
    disable "$t"
done

# Lock debug
for ld in LOCKDEP PROVE_LOCKING LOCK_STAT \
          DEBUG_LOCK_ALLOC DEBUG_SPINLOCK DEBUG_MUTEXES \
          DEBUG_RT_MUTEXES DEBUG_WW_MUTEX_SLOWPATH; do
    disable "$ld"
done

# Runtime debug
for rd in DEBUG_ATOMIC_SLEEP DEBUG_OBJECTS \
          DEBUG_LIST DEBUG_SG DEBUG_NOTIFIERS DEBUG_CREDENTIALS \
          KCOV KCSAN KFENCE DEBUG_KFENCE \
          SCHED_DEBUG SCHEDSTATS \
          DEBUG_SHRINKER \
          DEBUG_PAGEALLOC DEBUG_PER_CPU_MAPS \
          DEBUG_VM DEBUG_VM_MAPLE_TREE DEBUG_VM_PGTABLE \
          DEBUG_NMI_PANIC \
          RCU_TRACE RCU_CPU_STALL_INFO; do
    disable "$rd"
done

# Kselftest
cfg -d KUNIT
cfg -d RUNTIME_TESTING_MENU
cfg -d TEST_LIST_SORT
cfg -d TEST_LKM
cfg -d TEST_BLACKHOLE_DEV
cfg -d TEST_KSTRTOX

# ── Hypervisor guests to drop ────────────────────────────────────────

echo ">>> Nuking: Xen, Jailhouse, ACRN, Bhyve"
disable XEN
disable JAILHOUSE_GUEST
disable ACRN_GUEST
disable BHYVE_GUEST
disable PCI_XEN

# ── Experimental / non-essential ──────────────────────────────────────

echo ">>> Nuking: experimental & non-essential"

# Live Update
disable LIVEUPDATE
disable LIVEUPDATE_MEMFD
disable KEXEC_HANDOVER

# DAMON
disable DAMON

# Rust (simplifies build, not needed for desktop)
cfg -d RUST

# SMB server (ksmbd)
disable SMB_SERVER

# ── Hard trims (safe for modern desktop/laptop) ───────────────────────

echo ">>> Nuking: dead-end / legacy subsystems"

# Legacy OSS ALSA emulation (PulseAudio/PipeWire don't need it)
for oss in SND_OSSEMUL SND_MIXER_OSS SND_PCM_OSS; do
    disable "$oss"
done

# Legacy BSD pty, ancient WAN cards, Sony Memory Stick
disable LEGACY_PTYS
disable WAN
disable MEMSTICK

# Server-grade NICs (bnx2x/mlx5) - not present on consumer desktops/laptops
disable BNX2X
disable MLX5_CORE

# ── Obscure filesystems ──────────────────────────────────────────────

echo ">>> Nuking: obscure filesystems"
for fs in \
    NFS_FS NFSD \
    CEPH_FS GFS2_FS OCFS2_FS \
    REISERFS_FS JFS_FS NILFS2_FS \
    NTFS_FS \
    CODA_FS AFS_FS ECRYPT_FS \
    NCPFS ORANGEFS_FS \
    EROFS_FS \
    ADFS_FS \
    AFFS_FS \
    BEFS_FS \
    BFS_FS \
    EFS_FS \
    EXT2_FS \
    HPFS_FS \
    QNX4FS_FS \
    QNX6FS_FS \
    SYSV_FS \
    UDF_FS \
    CRAMFS_FS \
    UBIFS_FS \
    ; do
    disable "$fs"
done

# ── Make sure critical options stay ON / OFF correctly ───────────────

echo ">>> Verifying essential drivers"

# ── Boot-essential =y: must be in the kernel image ──────────────────
# No initramfs is shipped, so anything needed to reach the root filesystem
# has to be built in: root filesystems, loop (for the live squashfs), and
# the storage + USB controllers that back the root drive. Everything else is
# a module (=m) that udev loads once userspace is up.

cfg -e EXT4_FS
cfg -e BTRFS_FS
cfg -e SQUASHFS
cfg -e OVERLAY_FS
cfg -e BLK_DEV_LOOP

cfg -e BLK_DEV_NVME
cfg -e SATA_AHCI
cfg -e USB_STORAGE
cfg -e UAS

cfg -e USB
cfg -e USB_XHCI_HCD
cfg -e USB_EHCI_HCD
cfg -e USB_OHCI_HCD
cfg -e INPUT

# Microcode must be applied before any module exists
cfg -e MICROCODE

# Bool subsystem gates (not drivers): keep the feature, load drivers as =m
cfg -e MMC
cfg -e USB_NET_DRIVERS
cfg -e USB_SERIAL
cfg -e USB4
cfg -e MEDIA_CAMERA_SUPPORT

# ── Everything else =m (loadable after boot) ─────────────────────────
# scripts/config accepts exactly one symbol per invocation, so iterate.
cm() {
    local sym
    for sym in "$@"; do cfg -m "$sym"; done
}

# Alternate root filesystems (not usually the boot root)
cm XFS_FS F2FS_FS

# GPU (built in only if you need early-kernel console on a specific GPU)
cm DRM_I915 DRM_AMDGPU DRM_NOUVEAU

# Input / HID peripherals (keyboard, mouse, touchscreens, webcams)
cm HID USB_HID HID_GENERIC HID_MULTITOUCH I2C_HID USB_VIDEO_CLASS

# USB gadgets: ethernet dongles, 3D printers / Arduinos, printers, card
# readers, SD/MMC slots, USB4 docks
cm R8152 AX88179_178A
cm USB_SERIAL_ACM USB_SERIAL_CH341 USB_SERIAL_CP210X USB_SERIAL_FTDI_SIO USB_SERIAL_PL2303
cm USB_PRINTER
cm MISC_RTSX_PCI MISC_RTSX_USB MMC_SDHCI MMC_SDHCI_PCI MMC_SDHCI_ACPI

# Bluetooth (USB + UART controllers and PCI/ACPI devices)
cm BT BT_HCIBTUSB BT_HCIUART BT_ATH3K

# WiFi
cm IWLWIFI RTW88 RTW89 MT76 ATH
cm ATH9K ATH10K ATH11K ATH12K

# Cheap USB WiFi dongles
cm RT2500USB RT73USB RT2800USB RT8XXXU

# Legacy Realtek PCI/PCIe + Broadcom/Marvell WiFi
cm RTL8188EE RTL8192CE RTL8192CU RTL8723AE RTL8723BE RTL8821AE RTL8822BE
cm BRCMSMAC MWIFIEX MWIFIEX_SDIO MWIFIEX_PCIE

# Ethernet (consumer/workstation + USB ethernet dongles)
cm E1000E E100 IGB IGC R8169 TG3 ALX

# KVM / Virtualization
cm KVM KVM_INTEL KVM_AMD VIRTIO VIRTIO_PCI VFIO

# Sound (ALSA core as a module; userspace loads codecs)
cm SND

echo ">>> Done modifying config. Run 'make olddefconfig' next."
