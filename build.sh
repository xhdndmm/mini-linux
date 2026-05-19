#!/usr/bin/env bash
set -euo pipefail

############################################################
# config
############################################################

ROOT="$(pwd)"
WORK="${ROOT}/work"
OUT="${ROOT}/out"

JOBS="$(nproc)"

KERNEL_VERSION="6.18.32"
BUSYBOX_VERSION="1.37.0"

ARCH="x86_64"

KERNEL_TAR="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TAR}"

BUSYBOX_TAR="busybox-${BUSYBOX_VERSION}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TAR}"

############################################################
# banner
############################################################

echo "========================================"
echo " Build Minimal EFI Linux"
echo "========================================"

############################################################
# clean
############################################################

echo "==> clean"

rm -rf "${WORK}" "${OUT}"

mkdir -p "${WORK}"
mkdir -p "${OUT}"

############################################################
# deps
############################################################

echo "==> install dependencies"

sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    bc \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    dwarves \
    pahole \
    cpio \
    xz-utils \
    gzip \
    wget \
    tar \
    fakeroot \
    kmod \
    libncurses-dev \
    binutils \
    gcc \
    make \
    file \
    zstd \
    bzip2 \
    xz-utils \
    perl \
    rsync

############################################################
# busybox
############################################################

cd "${WORK}"

echo "==> download busybox"

wget -O "${BUSYBOX_TAR}" "${BUSYBOX_URL}"

echo "==> extract busybox"

tar xf "${BUSYBOX_TAR}"

cd "busybox-${BUSYBOX_VERSION}"

echo "==> configure busybox"

make defconfig

############################################################
# static busybox
############################################################

sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config

############################################################
# smaller binary
############################################################

sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
sed -i 's/^CONFIG_FEATURE_IPV6=y/# CONFIG_FEATURE_IPV6 is not set/' .config

############################################################
# build busybox
############################################################

echo "==> build busybox"

make -j"${JOBS}"

############################################################
# create rootfs
############################################################

echo "==> create rootfs"

mkdir -p "${WORK}/rootfs"/{
bin,sbin,etc,proc,sys,dev,tmp,usr/bin,usr/sbin
}

############################################################
# install busybox
############################################################

echo "==> install busybox"

make CONFIG_PREFIX="${WORK}/rootfs" install

############################################################
# init
############################################################

echo "==> write init"

cat > "${WORK}/rootfs/init" <<'EOF'
#!/bin/sh

mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

echo
echo "=================================="
echo " Mini-Linux"
echo " https://github.com/xhdndmm/mini-linux "
echo "=================================="
echo

exec /bin/sh
EOF

chmod +x "${WORK}/rootfs/init"

############################################################
# device nodes fallback
############################################################

mkdir -p "${WORK}/rootfs/dev"

sudo mknod -m 600 "${WORK}/rootfs/dev/console" c 5 1 || true
sudo mknod -m 666 "${WORK}/rootfs/dev/null" c 1 3 || true

############################################################
# kernel
############################################################

cd "${WORK}"

echo "==> download kernel"

wget -O "${KERNEL_TAR}" "${KERNEL_URL}"

echo "==> extract kernel"

tar xf "${KERNEL_TAR}"

cd "${WORK}/linux-${KERNEL_VERSION}"

############################################################
# kernel config
############################################################

echo "==> generate config"

make defconfig

############################################################
# EFI
############################################################

scripts/config --enable EFI
scripts/config --enable EFI_STUB

############################################################
# initramfs
############################################################

scripts/config --enable BLK_DEV_INITRD
scripts/config --set-str INITRAMFS_SOURCE "${WORK}/rootfs"

############################################################
# console
############################################################

scripts/config --enable VT
scripts/config --enable VT_CONSOLE
scripts/config --enable UNIX
scripts/config --enable TTY

############################################################
# devtmpfs
############################################################

scripts/config --enable DEVTMPFS
scripts/config --enable DEVTMPFS_MOUNT

############################################################
# filesystems
############################################################

scripts/config --enable TMPFS
scripts/config --enable TMPFS_POSIX_ACL

############################################################
# executable support
############################################################

scripts/config --enable BINFMT_ELF
scripts/config --enable BINFMT_SCRIPT

############################################################
# serial console
############################################################

scripts/config --enable SERIAL_8250
scripts/config --enable SERIAL_8250_CONSOLE

############################################################
# embedded
############################################################

scripts/config --enable EXPERT
scripts/config --enable EMBEDDED

############################################################
# smaller kernel
############################################################

scripts/config --disable DEBUG_INFO
scripts/config --disable DEBUG_KERNEL
scripts/config --disable MODULES
scripts/config --disable KALLSYMS
scripts/config --disable BPF
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable SYSTEM_REVOCATION_KEYS

############################################################
# builtin cmdline
############################################################

scripts/config --enable CMDLINE_BOOL

scripts/config --set-str CMDLINE \
"console=ttyS0 console=tty1 loglevel=3 rdinit=/init"

############################################################
# finalize config
############################################################

yes "" | make oldconfig

############################################################
# build kernel
############################################################

echo "==> build kernel"

make -j"${JOBS}"

############################################################
# verify
############################################################

KERNEL_IMAGE="${WORK}/linux-${KERNEL_VERSION}/arch/x86/boot/bzImage"

if [[ ! -f "${KERNEL_IMAGE}" ]]; then
    echo
    echo "ERROR: bzImage missing"
    echo
    exit 1
fi

############################################################
# output
############################################################

echo "==> prepare EFI"

cp "${KERNEL_IMAGE}" "${OUT}/BOOTX64.EFI"

############################################################
# verify efi
############################################################

echo "==> verify"

file "${OUT}/BOOTX64.EFI"

ls -lh "${OUT}/BOOTX64.EFI"

############################################################
# done
############################################################

echo
echo "========================================"
echo " BUILD SUCCESS"
echo "========================================"

echo
echo "EFI:"
echo "${OUT}/BOOTX64.EFI"
echo