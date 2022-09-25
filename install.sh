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

# Mount
mount -o compress=zstd /dev/mapper/system /mnt

mkdir -m 0755 /mnt/{boot,dev,etc,run}
mkdir -m 0555 /mnt/{proc,sys}
mkdir -m 1777 /mnt/tmp

mount /dev/disk/by-partlabel/boot /mnt/boot
mount /run /mnt/run --bind

mount -t proc     proc     /mnt/proc                     -o nosuid,noexec,nodev
mount -t sysfs    sys      /mnt/sys                      -o nosuid,noexec,nodev,ro
mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars -o nosuid,noexec,nodev
mount -t devtmpfs udev     /mnt/dev                      -o mode=0755,nosuid
mount -t devpts   devpts   /mnt/dev/pts                  -o mode=0620,gid=5,nosuid,noexec
mount -t tmpfs    shm      /mnt/dev/shm                  -o mode=1777,nosuid,nodev
mount -t tmpfs    tmp      /mnt/tmp                      -o mode=1777,strictatime,nodev,nosuid

# Disable SELinux Enforcement
setenforce 0

# Bootstrap system
dnf -y --installroot=/mnt --releasever=36 install \
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
setenforce 1
umount -R /mnt
cryptsetup close system
