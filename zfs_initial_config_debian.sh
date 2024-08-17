#!/bin/bash

set -x

echo "${HOSTNAME}" >/etc/hostname
echo -e "127.0.1.1\t${HOSTNAME}" >>/etc/hosts

passwd

rm -f /etc/apt/sources.list

cat <<EOF >/etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${TARGET_CODENAME} ${TARGET_CODENAME}-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: ${TARGET_CODENAME}-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

if [[ ! ${TARGET_CODENAME} =~ testing ]] && [[ ! ${TARGET_CODENAME} =~ unstable ]]; then
  cat <<EOF >/etc/apt/sources.list.d/debian-backports.sources
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${TARGET_CODENAME}-backports
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
fi

apt update && apt upgrade --yes

apt install --yes locales keyboard-configuration console-setup

dpkg-reconfigure locales tzdata keyboard-configuration console-setup

apt install --yes linux-headers-amd64 linux-image-amd64 zfs-initramfs dosfstools
echo "REMAKE_INITRD=yes" >/etc/dkms/zfs.conf
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target

echo "UMASK=0077" >/etc/initramfs-tools/conf.d/umask.conf

update-initramfs -c -k all

zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT
zfs set org.zfsbootmenu:keysource="zroot/ROOT/${ID}" zroot

apt install --yes curl efibootmgr
mkfs.vfat -F32 "$BOOT_DEVICE"
mkdir -p /boot/efi
mount "${BOOT_DEVICE}" /boot/efi
mkdir -p /boot/efi/EFI/ZBM
curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

mount -t efivarfs efivarfs /sys/firmware/efi/efivars

efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu (Backup)" \
  -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI' \
  --unicode "zbm.timeout=5"

efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu" \
  -l '\EFI\ZBM\VMLINUZ.EFI' \
  --unicode "zbm.timeout=3"

cat <<EOF >"/etc/systemd/system/$(systemd-escape -p --suffix=mount /boot/efi)"
[Mount]
What=${BOOT_DEVICE}
Where=/boot/efi
Type=vfat

[Install]
WantedBy=multi-user.target
EOF

# create new encrypted swap on every boot
# this breaks hibernation, but I don't really care
cat <<EOF >/etc/crypttab
swap ${SWAP_DEVICE} /dev/urandom swap,cipher=aes-xts-plain64,size=512
EOF

cat <<EOF >"/etc/systemd/system/$(systemd-escape -p --suffix=swap /dev/mapper/swap)"
[Swap]
What=/dev/mapper/swap

[Install]
WantedBy=multi-user.target
EOF

sudo apt-get install --yes systemd-zram-generator

systemctl daemon-reload &&
  systemctl enable systemd-zram-setup@zram0.service &&
  systemctl enable "$(systemd-escape -p --suffix=mount /boot/efi)" &&
  systemctl enable "$(systemd-escape -p --suffix=swap /dev/mapper/swap)"

echo "You might want to do a 'zpool upgrade -a' after reboot."
