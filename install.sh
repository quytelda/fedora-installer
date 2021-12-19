#!/bin/bash

set -eux

SYS_HOSTNAME=${SYS_HOSTNAME:-fedora}
SYS_PASSWORD=${SYS_PASSWORD:-'*'}

# Partitions
parted -a optimal --script -- /dev/vda \
       mklabel gpt \
       \
       mkpart primary 1MiB 1025MiB \
       mkpart primary 1025MiB -1 \
       \
       set 1 boot on \
       \
       name 1 boot \
       name 2 system

# Filesystems
mkfs.fat -F 32 -n boot /dev/vda1
mkfs.btrfs -L system /dev/vda2

# Mount
mount /dev/vda2 /mnt
mkdir /mnt/boot
mount /dev/vda1 /mnt/boot

# Bootstrap system
dnf -y --installroot=/mnt --releasever=35 install \
    @core \
    btrfs-progs \
    dosfstools \
    langpacks-en

# fstab
./genfstab -L /mnt >> /mnt/etc/fstab

# Configuration
systemd-firstboot --root=/mnt \
		  --locale='en_US.UTF-8' \
		  --timezone='America/Los_Angeles' \
		  --hostname="$SYS_HOSTNAME" \
		  --setup-machine-id \
		  --root-password-hashed="$SYS_PASSWORD"

# Bootloader
systemd-nspawn -D /mnt bootctl install

# Kernel
systemd-nspawn -D /mnt dnf -y install kernel

# Boot Entry
sed -i 's/\(^options[[:space:]]\+\).*/\1ro root=\/dev\/vda2 quiet/g' /mnt/boot/loader/entries/*.conf

# SELinux
touch /mnt/.autorelabel

# Clean up
umount -R /mnt
