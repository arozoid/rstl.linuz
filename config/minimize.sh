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

# ── Make sure critical options stay ON ────────────────────────────────

echo ">>> Verifying essential drivers"

# Filesystems
cfg -e EXT4_FS
cfg -e BTRFS_FS
cfg -e XFS_FS
cfg -e F2FS_FS
cfg -e SQUASHFS
cfg -e OVERLAY_FS

# Storage
cfg -e BLK_DEV_NVME
cfg -e SATA_AHCI
cfg -e USB_STORAGE
cfg -e UAS

# DRM
cfg -e DRM_I915
cfg -e DRM_AMDGPU
cfg -e DRM_NOUVEAU

# USB / Bluetooth / Webcams
cfg -e USB
cfg -e USB_VIDEO_CLASS
cfg -e MEDIA_CAMERA_SUPPORT
cfg -e BT

# WiFi
cfg -e IWLWIFI
cfg -e RTW88
cfg -e RTW89
cfg -e MT76
cfg -e ATH

# Ethernet (common)
cfg -e E1000E
cfg -e IGB
cfg -e IGC
cfg -e R8169
cfg -e BNX2X
cfg -e MLX5_CORE

# KVM / Virtualization
cfg -e KVM
cfg -e KVM_INTEL
cfg -e KVM_AMD
cfg -e VIRTIO
cfg -e VIRTIO_PCI
cfg -e VFIO

# Microcode
cfg -e MICROCODE

# Sound
cfg -e SND

echo ">>> Done modifying config. Run 'make olddefconfig' next."
