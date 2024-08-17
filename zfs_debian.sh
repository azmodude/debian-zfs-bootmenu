#!/bin/bash

source ./zfs_config.sh

BOOT_DEVICE=${BOOT_DISK}-part${BOOT_PART}
SWAP_DEVICE=${POOL_DISK}-part${SWAP_PART}
POOL_DEVICE=${POOL_DISK}-part${POOL_PART}

set -x
source /etc/os-release
export ID
export VERSION_CODENAME

cat <<EOF >/etc/apt/sources.list
deb http://deb.debian.org/debian ${VERSION_CODENAME} main contrib
deb http://deb.debian.org/debian ${VERSION_CODENAME}-updates main
deb-src http://deb.debian.org/debian ${VERSION_CODENAME} main contrib
EOF

apt update

apt-get install --yes debootstrap gdisk dkms "linux-headers-$(uname -r)"
apt-get install --yes zfsutils-linux
zgenhostid -f

swapoff --all

blkdiscard -f "${POOL_DISK}"
zpool labelclear -f "${POOL_DISK}"
wipefs -a "${BOOT_DISK}"
wipefs -a "${POOL_DISK}"
sgdisk --zap-all "{$POOL_DISK}"
sgdisk --zap-all "{$BOOT_DISK}"

sgdisk -n "${BOOT_PART}:1m:+2G" -t "${BOOT_PART}:ef00" "$BOOT_DISK"
sgdisk -n "${SWAP_PART}:0:+${SWAP_SIZE}G" -t "${SWAP_PART}:8200" "${POOL_DISK}"
sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$POOL_DISK"

echo "${ENCRYPTION_KEY}" >/etc/zfs/zroot.key
chmod 000 /etc/zfs/zroot.key

udevadm trigger && sleep 2

zpool create -f -o ashift=12 \
  -O compression=zstd \
  -O acltype=posixacl \
  -O dnodesize=auto \
  -O normalization=formD \
  -O xattr=sa \
  -O relatime=on \
  -O encryption=aes-256-gcm \
  -O keylocation=file:///etc/zfs/zroot.key \
  -O keyformat=passphrase \
  -o autotrim=on \
  -m none zroot "$POOL_DEVICE"

zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto "zroot/ROOT/${ID}"
zfs create -o mountpoint=/home zroot/home

zpool set "bootfs=zroot/ROOT/${ID}" zroot

zpool export zroot
zpool import -N -R /mnt zroot
zfs load-key -L prompt zroot

zfs mount "zroot/ROOT/${ID}"
zfs mount zroot/home

udevadm trigger && sleep 2

debootstrap --variant=buildd \
  --include dialog,sudo,init,network-manager,systemd,less,bash-completion,ca-certificates,netbase,lsb-release,gnupg2,apt-utils,apt-transport-https \
  "${TARGET_CODENAME}" /mnt

cp /etc/hostid /mnt/etc/hostid
cp /etc/resolv.conf /mnt/etc/
mkdir /mnt/etc/zfs
cp /etc/zfs/zroot.key /mnt/etc/zfs

mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -B /dev /mnt/dev
mount -t devpts pts /mnt/dev/pts

cp "./zfs_initial_config_${ID}.sh" /mnt && chmod +x "/mnt/zfs_initial_config_${ID}.sh"

chroot /mnt /usr/bin/env HOSTNAME="${HOSTNAME}" \
  BOOT_DEVICE="${BOOT_DEVICE}" \
  BOOT_DISK="${BOOT_DISK}" \
  BOOT_PART="${BOOT_PART}" \
  SWAP_DEVICE="${SWAP_DEVICE}" \
  TARGET_CODENAME="${TARGET_CODENAME}" \
  bin/bash --login -c "/zfs_initial_config_${ID}.sh"
rm "/mnt/zfs_initial_config_${ID}.sh"

umount -n -R /mnt
zpool export zroot
