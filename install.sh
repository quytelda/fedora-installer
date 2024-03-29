#!/bin/bash

set -eux

DEV_TARGET=${DEV_TARGET:-/dev/vda}
SYS_HOSTNAME=${SYS_HOSTNAME:-fedora}
LUKS_KEYFILE=${LUKS_KEYFILE:-"$(mktemp)"}
ROOT_PW_FILE=${ROOT_PW_FILE:-"$(mktemp)"}

# Sanity Checks
[[ -b "$DEV_TARGET"   ]] || { echo "Not a valid block device: $DEV_TARGET" 1>&2; exit 1; }
[[ -f "$LUKS_KEYFILE" ]] || { echo "Missing LUKS key file: $LUKS_KEYFILE" 1>&2; exit 1; }
[[ -f "$ROOT_PW_FILE" ]] || { echo "Missing root password file: $ROOT_PW_FILE" 1>&2; exit 1; }

# Install dependancies.
dnf install -y \
    arch-install-scripts \
    pwgen

# Partition the Disk
parted -a optimal --script -- "$DEV_TARGET" \
       mklabel gpt \
       \
       mkpart primary 1MiB 1025MiB \
       mkpart primary 1025MiB -1 \
       \
       name 1 boot \
       name 2 crypt_system \
       \
       set 1 boot on

# Creating filesystems might fail if /dev hasn't updated yet.
# Sleep briefly while the kernel catches up.
sleep 1

# Generate disk encryption and root login passwords.
pwgen -s 16 1 | tr -d '\n' > "$LUKS_KEYFILE"
pwgen -s 16 1              > "$ROOT_PW_FILE"

# Set up disk encryption with LUKS.
cryptsetup luksFormat \
	   --verbose \
	   --type=luks2 \
	   --key-file="$LUKS_KEYFILE" \
	   --batch-mode \
	   /dev/disk/by-partlabel/crypt_system

uuid_crypt_system=$(blkid -s UUID -o value /dev/disk/by-partlabel/crypt_system)

cryptsetup open \
	   --key-file="$LUKS_KEYFILE" \
	   /dev/disk/by-partlabel/crypt_system \
	   system

# Filesystems
mkfs.fat -F 32 -n boot /dev/disk/by-partlabel/boot
mkfs.btrfs -L system /dev/mapper/system

# Mount Filesystems
mount -o compress=zstd /dev/mapper/system /mnt

mkdir -m 0755 /mnt/{boot,dev,etc,run}
mkdir -m 0555 /mnt/{proc,sys}
mkdir -m 1777 /mnt/tmp

mount proc     /mnt/proc                      -t proc     -o nosuid,noexec,nodev
mount sys      /mnt/sys                       -t sysfs    -o nosuid,noexec,nodev,ro
mount efivarfs /mnt/sys/firmware/efi/efivars  -t efivarfs -o nosuid,noexec,nodev
mount udev     /mnt/dev                       -t devtmpfs -o mode=0755,nosuid
mount devpts   /mnt/dev/pts                   -t devpts   -o mode=0620,gid=5,nosuid,noexec
mount shm      /mnt/dev/shm                   -t tmpfs    -o mode=1777,nosuid,nodev
mount tmp      /mnt/tmp                       -t tmpfs    -o mode=1777,strictatime,nodev,nosuid

mount /run /mnt/run --bind
mount /dev/disk/by-partlabel/boot /mnt/boot

# Disable SELinux Enforcement
setenforce 0

# Bootstrap system
unshare --fork --pid dnf -y --installroot=/mnt --releasever=36 install \
	@core \
	@hardware-support \
	@standard \
	emacs-nox \
	langpacks-en

# Generate an fstab file
# Use genfstab from the Arch Linux install scripts.
genfstab -L /mnt >> /mnt/etc/fstab

# Create a crypttab file.
cat > /mnt/etc/crypttab <<EOF
system UUID=${uuid_crypt_system} none discard
EOF

# Configuration
systemd-firstboot --root=/mnt \
		  --locale='en_US.UTF-8' \
		  --timezone='America/Los_Angeles' \
		  --hostname="$SYS_HOSTNAME" \
		  --setup-machine-id

# Set the root password.
{ echo -n 'root:'; cat "$ROOT_PW_FILE"; } | chpasswd --root=/mnt

# Unmount API filesystems
umount /mnt/run
umount /mnt/tmp
umount /mnt/dev/shm
umount /mnt/dev/pts
umount /mnt/dev
umount /mnt/sys/firmware/efi/efivars
umount /mnt/sys
umount /mnt/proc

# Install the Bootloader
arch-chroot /mnt bootctl install

# Install the Kernel
arch-chroot /mnt dnf -y install kernel

# The boot entries generated when installing the kernel reuse the live system's
# boot flags, which aren't applicable.
# Overwrite those with something sensible.
cmdline="rd.luks.name=${uuid_crypt_system}=system ro root=LABEL=system quiet"
sed -i "s/\(^options[[:space:]]\+\).*/\1${cmdline}/g" /mnt/boot/loader/entries/*.conf

# Schedule an SELinux relabeling at next boot.
touch /mnt/.autorelabel

# Fix the hardware database's SELinux label.
# systemd-hwdb-update.service fails on boot if this label isn't corrected.
chcon -t systemd_hwdb_etc_t /mnt/etc/udev/hwdb.bin

# Clean up
setenforce 1
umount -R /mnt
cryptsetup close system

# Installation Summary
set +x
echo "The installation is complete."
echo    "Hostname:      ${SYS_HOSTNAME}"
echo -n "LUKS key:      " && cat "$LUKS_KEYFILE" && echo
echo -n "Root password: " && cat "$ROOT_PW_FILE"
