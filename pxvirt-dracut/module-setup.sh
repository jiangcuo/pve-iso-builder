#!/bin/bash
# PXVIRT live-installer dracut module.
#
# Replaces the Debian initramfs-tools `init` + `pve_init_hook` approach: instead
# of overriding the initramfs /init, we hook into dracut's boot phases.
#
# Build the live initramfs with:
#   dracut --force --no-hostonly --add pxvirt-live \
#          --add-drivers "<gpu/storage drivers>" /boot/initrd.img-<kver> <kver>

# Always available; gate the actual work on the rd.pxvirt.live cmdline flag.
check() {
    return 0
}

# No special module dependencies; squashfs/overlay are kernel modules (below).
depends() {
    return 0
}

# Kernel modules needed to find the medium and stack the squashfs overlay.
installkernel() {
    instmods squashfs hfs hfsplus loop overlay iso9660 sr_mod sd_mod usb-storage uas
}

install() {
    # cmdline phase: claim the root so dracut doesn't wait for a root= block dev.
    inst_hook cmdline 30 "$moddir/parse-pxvirt-live.sh"
    # mount phase: find the CD, stack the two squashfs, mount onto $NEWROOT.
    inst_hook mount 99 "$moddir/pxvirt-live-mount.sh"

    # Userspace tools the mount hook needs (most are already pulled in by the
    # base dracut modules; listed explicitly to be safe). losetup is required for
    # the loop-mounted squashfs / embedded ISO.
    inst_multiple mount umount mkdir cp cat dd blkid losetup switch_root sleep readlink udevadm
}
