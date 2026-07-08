#!/usr/bin/env bash
set -euo pipefail

trap 'echo "ERROR at line $LINENO" >&2' ERR

ROOT="$(pwd)"
WORK="${ROOT}/work"
OUT="${ROOT}/out"
JOBS="$(nproc)"

# =============================================================================
# architecture selection  (ARCH=x86_64  or  ARCH=arm64,  default: x86_64)
# =============================================================================
ARCH="${ARCH:-x86_64}"

case "${ARCH}" in
  x86_64)
    CROSS_COMPILE=""
    KERNEL_IMAGE_REL="arch/x86/boot/bzImage"
    KERNEL_TARGET="bzImage"
    KERNEL_DEFCONFIG="defconfig"
    EFI_OUTPUT_NAME="BOOTX64.EFI"
    ;;
  arm64)
    CROSS_COMPILE="aarch64-linux-gnu-"
    KERNEL_IMAGE_REL="arch/arm64/boot/Image"
    KERNEL_TARGET="Image"
    KERNEL_DEFCONFIG="defconfig"
    EFI_OUTPUT_NAME="BOOTAA64.EFI"
    ;;
  *)
    echo "ERROR: unsupported ARCH='${ARCH}'" >&2
    exit 1
    ;;
esac

KERNEL_MAKE="make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE}"

echo "==> building for ARCH=${ARCH}"

KERNEL_VERSION="6.18.38"
BUSYBOX_VERSION="1.38.0"

KERNEL_TAR="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TAR}"

BUSYBOX_TAR="busybox-${BUSYBOX_VERSION}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TAR}"

CMDLINE='console=ttyS0,115200n8 console=tty0 loglevel=8 init=/init'

echo "==> install dependencies"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential bc bison flex libssl-dev libelf-dev dwarves pahole \
  cpio xz-utils gzip curl tar fakeroot kmod libncurses-dev binutils gcc make \
  file zstd bzip2 perl rsync

# cross-compilation toolchain for arm64
if [[ "${ARCH}" == "arm64" ]]; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    crossbuild-essential-arm64
fi

echo "==> clean"
rm -rf "${WORK}" "${OUT}"
mkdir -p "${WORK}" "${OUT}"

###############################################################################
# BusyBox
###############################################################################

cd "${WORK}"

echo "==> download busybox"
curl -o "${BUSYBOX_TAR}" "${BUSYBOX_URL}"

echo "==> extract busybox"
tar xf "${BUSYBOX_TAR}"

cd "busybox-${BUSYBOX_VERSION}"

echo "==> configure busybox"
make defconfig

sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config

sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
sed -i 's/^CONFIG_FEATURE_IPV6=y/# CONFIG_FEATURE_IPV6 is not set/' .config

echo "==> build busybox"
make -j"${JOBS}"

echo "==> create rootfs"
mkdir -p "${WORK}/rootfs"/{bin,sbin,etc,proc,sys,dev,tmp,usr/bin,usr/sbin}

echo "==> install busybox"
make CONFIG_PREFIX="${WORK}/rootfs" install

echo "==> write init"
cat > "${WORK}/rootfs/init" <<'EOF'
#!/bin/sh
set -eu

mount -t devtmpfs devtmpfs /dev 2>/dev/null  
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp

[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1  
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3  

echo
echo "=================================="
echo "Mini-Linux"
echo "https://github.com/xhdndmm/mini-linux"
uname -a
echo "=================================="
echo

exec setsid cttyhack /bin/sh
EOF
chmod +x "${WORK}/rootfs/init"

sudo mknod -m 600 "${WORK}/rootfs/dev/console" c 5 1  
sudo mknod -m 666 "${WORK}/rootfs/dev/null" c 1 3  

echo "==> pack initramfs"
cd "${WORK}/rootfs"
find . -print0 \
  | cpio --null -ov --format=newc \
  | gzip -9n \
  > "${WORK}/initramfs.cpio.gz"

echo "==> verify initramfs contents"
zcat "${WORK}/initramfs.cpio.gz" | cpio -t | grep -E '(^init$|^bin/busybox$|^bin/sh$)'  

###############################################################################
# Kernel
###############################################################################

cd "${WORK}"

echo "==> download kernel"
curl -o "${KERNEL_TAR}" "${KERNEL_URL}"

echo "==> extract kernel"
tar xf "${KERNEL_TAR}"

cd "${WORK}/linux-${KERNEL_VERSION}"

echo "==> configure kernel"
${KERNEL_MAKE} ${KERNEL_DEFCONFIG}

# ---- common options (all architectures) ------------------------------------
scripts/config --enable EFI
scripts/config --enable EFI_STUB

scripts/config --enable BLK_DEV_INITRD
scripts/config --enable RD_GZIP
scripts/config --set-str INITRAMFS_SOURCE "${WORK}/initramfs.cpio.gz"

scripts/config --enable DEVTMPFS
scripts/config --enable DEVTMPFS_MOUNT
scripts/config --enable TMPFS
scripts/config --enable TMPFS_POSIX_ACL
scripts/config --enable UNIX

scripts/config --enable BINFMT_ELF
scripts/config --enable BINFMT_SCRIPT

scripts/config --enable TTY
scripts/config --enable VT
scripts/config --enable VT_CONSOLE

scripts/config --enable DRM
scripts/config --enable DRM_KMS_HELPER
scripts/config --enable DRM_SIMPLEDRM
scripts/config --enable DRM_FBDEV_EMULATION

scripts/config --enable SYSFB
scripts/config --enable SYSFB_SIMPLEFB

scripts/config --enable FB
scripts/config --enable FB_CORE
scripts/config --enable FB_CFB_FILLRECT
scripts/config --enable FB_CFB_COPYAREA
scripts/config --enable FB_CFB_IMAGEBLIT
scripts/config --enable FB_EFI

scripts/config --enable FRAMEBUFFER_CONSOLE
scripts/config --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY

scripts/config --enable SERIAL_8250
scripts/config --enable SERIAL_8250_CONSOLE

scripts/config --enable INPUT
scripts/config --enable INPUT_KEYBOARD
scripts/config --enable INPUT_MOUSEDEV
scripts/config --enable HID
scripts/config --enable HID_GENERIC
scripts/config --enable USB_HID

scripts/config --enable USB
scripts/config --enable USB_XHCI_HCD
scripts/config --enable USB_EHCI_HCD
scripts/config --enable USB_OHCI_HCD

scripts/config --enable CMDLINE_BOOL
scripts/config --set-str CMDLINE "${CMDLINE}"
scripts/config --enable CMDLINE_OVERRIDE
scripts/config --enable CMDLINE_FORCE

# ---- pci / nvme (fixed: added SCSI, BLK_DEV_SD, PCI_MSI, PCIEPORTBUS) -----
scripts/config --enable PCI
scripts/config --enable PCI_MSI
scripts/config --enable PCIEPORTBUS
scripts/config --enable BLK_DEV_NVME
scripts/config --enable NVME_CORE
scripts/config --enable NVME_PCI

# ---- scsi / block (required for full block-layer init) ---------------------
scripts/config --enable SCSI
scripts/config --enable BLK_DEV_SD

# ---- virtio (useful for virtual machines) ----------------------------------
scripts/config --enable VIRTIO
scripts/config --enable VIRTIO_PCI
scripts/config --enable VIRTIO_BLK
scripts/config --enable VIRTIO_NET
scripts/config --enable VIRTIO_CONSOLE

# ---- architecture-specific options -----------------------------------------
case "${ARCH}" in
  x86_64)
    scripts/config --enable EFI_VARS
    scripts/config --enable DUMMY_CONSOLE
    scripts/config --enable VGA_CONSOLE
    scripts/config --enable FB_VESA
    scripts/config --enable SERIO
    scripts/config --enable SERIO_I8042
    scripts/config --enable KEYBOARD_ATKBD
    scripts/config --enable MOUSE_PS2
    ;;
  arm64)
    # arm64-specific console / serial
    scripts/config --enable SERIAL_AMBA_PL011
    scripts/config --enable SERIAL_AMBA_PL011_CONSOLE
    # generic PCI host (common on arm64 platforms)
    scripts/config --enable PCI_HOST_GENERIC
    scripts/config --enable PCI_HOST_COMMON
    ;;
esac

${KERNEL_MAKE} olddefconfig

echo "==> build kernel"
${KERNEL_MAKE} -j"${JOBS}" ${KERNEL_TARGET}

KERNEL_IMAGE="${WORK}/linux-${KERNEL_VERSION}/${KERNEL_IMAGE_REL}"

if [[ ! -f "${KERNEL_IMAGE}" ]]; then
  echo "ERROR: kernel image missing at ${KERNEL_IMAGE}" >&2
  exit 1
fi

echo "==> prepare EFI output"
cp "${KERNEL_IMAGE}" "${OUT}/${EFI_OUTPUT_NAME}"

echo
echo "========================================"
echo " BUILD SUCCESS  (ARCH=${ARCH})"
echo "========================================"

echo "==> verify"
file "${OUT}/${EFI_OUTPUT_NAME}"
echo
ls -lh "${OUT}/${EFI_OUTPUT_NAME}"
echo
sha256sum "${OUT}/${EFI_OUTPUT_NAME}" >> "${OUT}/${EFI_OUTPUT_NAME}.sha256"
echo
md5sum "${OUT}/${EFI_OUTPUT_NAME}" >> "${OUT}/${EFI_OUTPUT_NAME}.md5"