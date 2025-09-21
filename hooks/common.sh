#!/bin/bash

export OVERLAYROOT="$TARGETDIR/overlay/mount"
export OVERLAYUPPER="$TARGETDIR/overlay/upper"
export ROOTFSDIR="$TARGETDIR/rootfs"
export ISODIR="$TARGETDIR/iso"
export PROJECT_DIR="$SCRIPT_DIR"
export PACKAGE_DIR="$TARGETDIR/iso/proxmox/packages"

export TARGET_MODULE_DIR="$OVERLAYROOT/lib/modules"
export ROOTFS_MODULE_DIR="$ROOTFSDIR/lib/modules"

export EFI_MOUNT="/tmp/efi"
export EFI_DIR="$ISODIR/EFI"
export GRUB_DIR="$ISODIR/boot/grub"


