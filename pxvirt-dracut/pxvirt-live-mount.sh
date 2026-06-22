#!/bin/sh
# mount-phase hook: locate the PXVIRT medium, stack the two squashfs (installer
# over base) as an overlay, and mount it onto $NEWROOT. dracut switch_roots into
# $NEWROOT afterwards.
#
# Faithful port of pve-iso-builder/init lines 284-397, but driven by dracut:
#   - returning 0 without mounting $NEWROOT makes dracut retry this hook, which
#     replaces the hand-rolled "9 tries with growing sleep" device-wait loop.

# only act for our claimed root, and only once
[ "$root" = "pxvirt-live" ] || return 0
ismounted "$NEWROOT" && return 0

# The medium is identified by a per-build CD-ID *file* (labels can collide).
# The expected id comes from the kernel cmdline (grub.cfg writes it per build);
# falls back to a copy baked into the initramfs, or to "any medium that simply
# carries the file" when no id is known.
CDID_FN=".pxvirt-cd-id.txt"
reqid="$(getarg rd.pxvirt.cdid=)"
[ -z "$reqid" ] && [ -r "/$CDID_FN" ] && reqid="$(cat "/$CDID_FN")"

mkdir -p /run/cdrom /run/live/base /run/live/installer \
         /run/live/work/upper /run/live/work/work

# matches medium at /run/cdrom against reqid (or accepts any if reqid is empty)
cdid_matches() {
    [ -r "/run/cdrom/$CDID_FN" ] || return 1
    [ -z "$reqid" ] && return 0
    [ "$(cat "/run/cdrom/$CDID_FN")" = "$reqid" ]
}

cdrom=

# --- Case 1: ISO embedded in / fetched into the initramfs (PXE / netboot) -----
# Baked-in default path /pxvirt.iso (cf. PVE's /proxmox.iso); rd.pxvirt.isoimg=
# can point at a different location (e.g. an image fetched by dracut networking).
isoimg="$(getarg rd.pxvirt.isoimg=)"
: "${isoimg:=/pxvirt.iso}"
if [ -f "$isoimg" ]; then
    info "pxvirt-live: found embedded ISO image $isoimg (PXE/netboot)"
    if mount -t iso9660 -o ro,loop "$isoimg" /run/cdrom 2>/dev/null && cdid_matches; then
        cdrom="$isoimg"
    else
        umount /run/cdrom 2>/dev/null
    fi
fi

# --- Case 2: search physical block devices for the medium ---------------------
# Media can be written several ways, so we probe both whole devices and their
# partitions:
#   - dd / isohybrid (Rufus "DD mode", etc) -> whole device is iso9660
#   - UltraISO "USB-HDD" / Rufus "ISO mode" -> files on a FAT *partition*
#   - optical disc                          -> sr0, iso9660
if [ -z "$cdrom" ]; then
    for sysdev in /sys/block/sr* /sys/block/scd* /sys/block/sd* \
                  /sys/block/nvme* /sys/block/hd*; do
        [ -d "$sysdev" ] || continue
        base="${sysdev##*/}"
        size="$(cat "$sysdev/size" 2>/dev/null || echo 0)"
        rmb="$(cat "$sysdev/removable" 2>/dev/null || echo 0)"

        # whole device + each of its partitions
        devlist="/dev/$base"
        for partsys in "$sysdev/$base"*; do
            [ -d "$partsys" ] && devlist="$devlist /dev/${partsys##*/}"
        done

        for dev in $devlist; do
            [ -b "$dev" ] || continue
            fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null)"
            # always try mountable media types; for anything else only bother if
            # the disk is removable or small -- never mount big data/ZFS/LVM disks.
            case "$fstype" in
                iso9660|vfat|"") : ;;
                *) [ "$rmb" = 1 ] || [ "$size" -lt 68157440 ] || continue ;;
            esac

            mount -t auto -o ro "$dev" /run/cdrom 2>/dev/null || continue
            if cdid_matches; then
                cdrom="$dev"
                break
            fi
            umount /run/cdrom 2>/dev/null
        done
        [ -n "$cdrom" ] && { info "pxvirt-live: found medium on $cdrom"; break; }
    done
fi

# not found yet -> return 0 so dracut retries (devices may still be appearing)
[ -n "$cdrom" ] || { warn "pxvirt-live: medium not found yet, retrying"; return 0; }

# --- mount the two squashfs read-only -----------------------------------------
mount -t squashfs -o ro,loop /run/cdrom/pxvirt-base.squashfs /run/live/base \
    || die "pxvirt-live: mounting pxvirt-base.squashfs failed"
mount -t squashfs -o ro,loop /run/cdrom/pxvirt-installer.squashfs /run/live/installer \
    || die "pxvirt-live: mounting pxvirt-installer.squashfs failed"

# --- stack them: installer on top, base below, tmpfs writable layer -----------
# Equivalent to init:382 (lowerdir=.installer:.base).
mount -t overlay -o \
    lowerdir=/run/live/installer:/run/live/base,upperdir=/run/live/work/upper,workdir=/run/live/work/work \
    pxvirt-live "$NEWROOT" \
    || die "pxvirt-live: overlay mount failed"

# --- expose the medium at /cdrom inside the live root -------------------------
# The installer reads pxvirt-base.squashfs and proxmox/packages/*.rpm from there.
mkdir -p "$NEWROOT/cdrom"
mount --bind /run/cdrom "$NEWROOT/cdrom"

# --- carry over identity bits like the PVE init ------------------------------
# zfs(gethostid)用 /etc/hostid 记录"上次是谁导入了 pool",必须在 spl.ko 加载前就位。
# initramfs 里没有 hostid,这里随机生成一份(对应 PVE init 的 dd .../etc/hostid),
# 再拷进 $NEWROOT;装完由安装器(Install.pm)拷到目标系统,保证目标认得自己建的 pool。
[ -f /etc/hostid ] || dd if=/dev/urandom of=/etc/hostid bs=1 count=4 status=none
cp /etc/hostid "$NEWROOT/etc/" 2>/dev/null
[ -f /.cd-info ]   && cp /.cd-info "$NEWROOT/" 2>/dev/null

info "pxvirt-live: live root ready at $NEWROOT"
