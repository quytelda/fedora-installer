#!/bin/bash

set -eux

SYS_HOSTNAME=${SYS_HOSTNAME:-fedora}
LUKS_KEYFILE=${LUKS_KEYFILE:-"$(mktemp)"}

# Sanity Checks
[[ -f "$LUKS_KEYFILE" ]] || { echo "Missing LUKS key file: $LUKS_KEYFILE" 1>&2; exit 1; }

# Install dependancies.
dnf install -y \
    arch-install-scripts \
    pwgen

# Partition the Disk
parted -a optimal --script -- /dev/vda \
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

# Generate a disk encryption password.
pwgen -s 16 1 | tr -d '\n' > "$LUKS_KEYFILE"

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

# Mount
mount /dev/mapper/system /mnt
mkdir /mnt/boot
mount /dev/disk/by-partlabel/boot /mnt/boot

# Bootstrap system
dnf -y --installroot=/mnt --releasever=35 install \
    @core \
    @hardware-support \
    @standard \
    btrfs-progs \
    cryptsetup \
    dosfstools \
    emacs-nox \
    langpacks-en

# Generate an fstab file
# Use genfstab from the Arch Linux install scripts.
genfstab -L /mnt >> /mnt/etc/fstab

# Create a crypttab file.
cat > /mnt/etc/crypttab <<EOF
system UUID=${uuid_crypt_system} none discard
EOF

# DNF sets the wrong security context for the passwd and shadow files,
# which prevents setting the root password.
# Temporarily copy the live system's context for these files to fix the issue.
chcon --reference=/etc/passwd /mnt/etc/passwd
chcon --reference=/etc/shadow /mnt/etc/shadow

# Configuration
systemd-firstboot --root=/mnt \
		  --locale='en_US.UTF-8' \
		  --timezone='America/Los_Angeles' \
		  --hostname="$SYS_HOSTNAME" \
		  --setup-machine-id \
		  --prompt-root-password

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

# Clean up
umount -R /mnt
cryptsetup close system
