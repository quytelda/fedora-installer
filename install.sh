#!/bin/bash

set -eux

SYS_HOSTNAME=${SYS_HOSTNAME:-fedora}
LUKS_KEYFILE=${LUKS_KEYFILE:-"$(mktemp)"}

# Sanity Checks
[[ -f "$LUKS_KEYFILE" ]] || { echo "Missing LUKS key file: $LUKS_KEYFILE" 1>&2; exit 1; }

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
openssl rand -base64 16 > "$LUKS_KEYFILE"

# Set up disk encryption with LUKS.
cryptsetup luksFormat \
	   --verbose \
	   --type=luks2 \
	   --key-file="$LUKS_KEYFILE" \
	   --batch-mode \
	   /dev/disk/by-partlabel/crypt_system

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
    @standard \
    btrfs-progs \
    dosfstools \
    langpacks-en

# Generate an fstab file
# Use genfstab from the Arch Linux install scripts.
./genfstab -L /mnt >> /mnt/etc/fstab

# Create a crypttab file.
cat > /mnt/etc/crypttab <<EOF
system PARTLABEL=crypt_system none discard
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
systemd-nspawn -D /mnt bootctl install

# Install the Kernel
systemd-nspawn -D /mnt dnf -y install kernel

# The boot entries generated when installing the kernel reuse the live system's
# boot flags, which aren't applicable.
# Overwrite those with something sensible.
sed -i 's/\(^options[[:space:]]\+\).*/\1ro root=LABEL=system quiet/g' /mnt/boot/loader/entries/*.conf

# Schedule an SELinux relabeling at next boot.
touch /mnt/.autorelabel

# Clean up
umount -R /mnt
