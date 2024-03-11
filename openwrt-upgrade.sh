#!/usr/bin/env bash

VERSION="$1"

UPGRADE_DIR="/tmp/sysupgrade"

mkdir -p "$UPGRADE_DIR"
cd "$UPGRADE_DIR" || exit

curl -s https://downloads.openwrt.org/releases/ |\
    grep -E ">[2-9][0-9]\.[0-1][0-9]\." |\
    cut -d ">" -f 4 |\
    cut -d "<" -f 1 > available-versions.list

if ! grep -q "$VERSION" available-versions.list; then
  echo -e "# $VERSION not found!"
  exit 1
fi


echo -e "\n# Upgrading to OpenWRT $VERSION"
echo -e "# Generating installed packages list"
opkg list-installed | cut -d " " -f 1 | grep -E "20[0-9]{2,}" -v > "packages.list"
sleep 1s

echo -e "# Generating config list"
sysupgrade -l > "configs.list"
sleep 1s

echo -e "# Downloading OpenWRT rootfs ext4 image"
wget "https://downloads.openwrt.org/releases/$VERSION/targets/x86/64/openwrt-$VERSION-x86-64-generic-ext4-rootfs.img.gz" \
    -O "openwrt.img.gz" -q --show-progress

echo -e "\n# Downloading OpenWRT kernel"
wget "https://downloads.openwrt.org/releases/$VERSION/targets/x86/64/openwrt-$VERSION-x86-64-generic-kernel.bin" \
    -O "kernel.bin" -q --show-progress

echo -e "\n# Detecting desired A/B partition"
TARGET_PART=$(lsblk -lo NAME,LABEL,MOUNTPOINT | grep -E "sda.*openwrt" | grep "/" -v)
AB_PART=$(echo "$TARGET_PART" | cut -d "-" -f 2)
AB_PART=${AB_PART:0:1}
TARGET_PART=$(echo "$TARGET_PART" | cut -d " " -f 1)

# Find boot partition
BOOT_PART="$(lsblk -lo NAME,LABEL | grep -E "sda.*kernel"  | cut -d " " -f 1)"
mkdir -p boot
mount "/dev/$BOOT_PART" boot

# Detect current grub default entry and calculate it's new value
DEFAULT=$(grep default < boot/boot/grub/grub.cfg | cut -d " " -f 2)
NEW_DEFAULT="1"
[[ $DEFAULT =~ "1" ]] && NEW_DEFAULT="0"
umount boot

echo -e "\n# !!! Upgrade confirmation !!!"
echo -e "# New OpenWRT version:    $VERSION"
echo -e "# Target partition:       ${AB_PART^^} (/dev/$TARGET_PART)"
echo -e "# New default GRUB entry: $NEW_DEFAULT"

echo -e "# Continue? [y/N]"

read -rsn1 DO_UPGRADE
[[ $DO_UPGRADE =~ ^[Nn]$ ]] && exit 0

echo -e "\n# Targetting partition ${AB_PART^^} ($TARGET_PART)"
echo -e "# Writing OpenWRT image to /dev/$TARGET_PART"
gzip -kcd openwrt.img.gz | dd bs=4M of="/dev/$TARGET_PART" status=progress && sync

# resize filesystem to partition size
echo -e "\n# Resizing filesystem to match partition size"
echo -e "# and relabelling it to openwrt-$AB_PART"
resize2fs "/dev/$TARGET_PART"
tune2fs -L "openwrt-$AB_PART" "/dev/$TARGET_PART" > /dev/null
sleep 1s

echo -e "\n# Mounting the new root"
mkdir -p newroot
mount "/dev/$TARGET_PART" newroot
mkdir -p newroot/var/lock

echo -e "\n# Installing packages on the new root"
chroot newroot opkg update
xargs -I {} -a packages.list chroot newroot opkg install {}

echo -e "\n# Copying configuration"
xargs -I {} -a configs.list cp -a --parents {} newroot

echo -e "\n# Copying OpenWRT kernel to the boot partition"
mount "/dev/$BOOT_PART" boot
cp kernel.bin "boot/boot/vmlinuz-${AB_PART}"

echo -e "\n# Changing default GRUB entry to OpenWRT ${AB_PART^^}"
sed -i "s/$DEFAULT/default=\"$NEW_DEFAULT\"/g" boot/boot/grub/grub.cfg

echo -e "\n# Upgrade done!"

umount "/dev/$TARGET_PART"
umount "/dev/$BOOT_PART"

echo -e "# Do you want to reboot? [Y/n]"
read -rsn1 DO_REBOOT
[[ $DO_REBOOT =~ ^[Yy]$ ]] && reboot

