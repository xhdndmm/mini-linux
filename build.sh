#!/usr/bin/env bash
set -euo pipefail

trap 'echo "ERROR at line $LINENO" >&2' ERR

ROOT="$(pwd)"
WORK="${ROOT}/work"
OUT="${ROOT}/out"
JOBS="$(nproc)"

KERNEL_VERSION="6.18.34"
BUSYBOX_VERSION="1.37.0"

KERNEL_TAR="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TAR}"

BUSYBOX_TAR="busybox-${BUSYBOX_VERSION}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TAR}"

CMDLINE='console=ttyS0,115200 console=tty0 init=/init'

echo "==> install dependencies"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential bc bison flex libssl-dev libelf-dev dwarves pahole \
  cpio xz-utils gzip curl tar fakeroot kmod libncurses-dev binutils gcc make \
  file zstd bzip2 perl rsync

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

# static binary
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config

# trim a little
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

mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp

echo
echo "=================================="
echo "Mini-Linux"
echo "https://github.com/xhdndmm/mini-linux"
uname -a
busybox
echo "=================================="
echo

exec setsid cttyhack /bin/sh
EOF
chmod +x "${WORK}/rootfs/init"

# fallback device nodes, in case devtmpfs is not available early enough
sudo mknod -m 600 "${WORK}/rootfs/dev/console" c 5 1 || true
sudo mknod -m 666 "${WORK}/rootfs/dev/null" c 1 3 || true

echo "==> pack initramfs"
cd "${WORK}/rootfs"
find . -print0 \
  | cpio --null -ov --format=newc \
  | gzip -9n \
  > "${WORK}/initramfs.cpio.gz"

echo "==> verify initramfs contents"
zcat "${WORK}/initramfs.cpio.gz" | cpio -t | grep -E '(^init$|^bin/busybox$|^bin/sh$)' || true

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
make defconfig

scripts/config --enable EFI
scripts/config --enable EFI_STUB

scripts/config --enable BLK_DEV_INITRD
scripts/config --enable RD_GZIP

scripts/config --enable DEVTMPFS
scripts/config --enable DEVTMPFS_MOUNT

scripts/config --enable TMPFS
scripts/config --enable TMPFS_POSIX_ACL

scripts/config --enable BINFMT_ELF
scripts/config --enable BINFMT_SCRIPT
scripts/config --enable UNIX

scripts/config --enable TTY
scripts/config --enable VT
scripts/config --enable VT_CONSOLE

scripts/config --enable FRAMEBUFFER
scripts/config --enable FB_EFI
scripts/config --enable FRAMEBUFFER_CONSOLE
scripts/config --enable FONT_SUPPORT

scripts/config --enable SERIAL_8250
scripts/config --enable SERIAL_8250_CONSOLE

# Built-in kernel command line: critical for direct EFI boot.
scripts/config --enable CMDLINE_BOOL
scripts/config --set-str CMDLINE "${CMDLINE}"
scripts/config --enable CMDLINE_OVERRIDE

# Embed initramfs
scripts/config --set-str INITRAMFS_SOURCE "${WORK}/initramfs.cpio.gz"

make olddefconfig

echo "==> build kernel"
make -j"${JOBS}" bzImage

KERNEL_IMAGE="${WORK}/linux-${KERNEL_VERSION}/arch/x86/boot/bzImage"

if [[ ! -f "${KERNEL_IMAGE}" ]]; then
  echo "ERROR: bzImage missing" >&2
  exit 1
fi

echo "==> prepare EFI output"
cp "${KERNEL_IMAGE}" "${OUT}/BOOTX64.EFI"

# Optional: ready-to-boot ESP layout for local testing
mkdir -p "${OUT}/esp/EFI/BOOT"
cp "${OUT}/BOOTX64.EFI" "${OUT}/esp/EFI/BOOT/BOOTX64.EFI"

echo
echo "========================================"
echo " BUILD SUCCESS"
echo "========================================"

echo "==> verify"
file "${OUT}/BOOTX64.EFI"
ls -lh "${OUT}/BOOTX64.EFI"
sha256sum "${OUT}/BOOTX64.EFI"
md5sum "${OUT}/BOOTX64.EFI"