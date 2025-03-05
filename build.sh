#!/bin/bash
#proxmox arm64 iso builder
script_path=$(readlink -f "\$0")
script_dir=$(dirname "$script_path")
extra_pkg="ceph-common ceph-fuse iperf3"  #if you want install other package
hostarch=`arch`     # This scripts only allow the same arch build.
codename="bookworm"  # proxmox version. bookworm->pve8 ,bullseye->pve7
targetdir="/tmp/targetdir" # tmpdir
modules="hfs hfsplus cdrom sd_mod sr_mod loop squashfs iso9660 drm overlay uas hibmc-drm dw_drm_dsi kirin_drm amdgpu nouveau ast radeon virtio-gpu mgag200"

# iso info
source $script_dir/.cd-info

# Handling of different architectures
if [ "$hostarch" == "aarch64" ];then
    target_arch="arm64";
    grub_prefix="arm64"
    grub_file="BOOTAA64.EFI"
    grub_pkg="grub-common grub-efi-arm64-bin systemd-boot grub-efi-arm64-signed shim-signed grub-efi-arm64 grub2-common"
elif [ "$hostarch" == "x86_64" ];then
    target_arch="amd64"
    grub_prefix="x86_64"
    grub_file="BOOTX64.EFI"
    grub_pkg="grub-common grub-pc-bin grub-efi-amd64-bin systemd-boot grub-efi-amd64-signed shim-signed  grub-efi-amd64 grub2-common"
    main_kernel="proxmox-kernel-6.8"
elif [ "$hostarch" == "loongarch64" ];then
    target_arch="loong64"
    grub_prefix="loongarch64"
    grub_file="BOOTLOONGARCH64.EFI"
    grub_pkg="grub-common  grub-efi-loong64-bin grub-efi-loong64 grub2-common"
    portmirrors="https://mirrors.lierfang.com/proxmox/debian"
    if [ "$PRODUCT" == "pbs" ];then
        main_kernel="pve-kernel-6.12-4k-pve"  #pbs need 4k kernel
    else
	main_kernel="pve-kernel-6.12-pve"     #for loongarch kernel 6.12  works fine
    fi
    extra_kernel=""
elif [ "$hostarch" == "riscv64" ];then
    target_arch="riscv64"
    grub_prefix="riscv64"
    grub_file="BOOTRISCV64.EFI"
    grub_pkg="grub-common  grub-efi-riscv64-bin grub-efi-riscv64 grub2-common"
    codename="sid"
fi


errlog(){
	if [ $? != 0 ];then
		echo $1
        umount_proc
		exit 1
	fi
}

# Create isofs
isofs(){
    if [ ! -f "$targetdir/.isofs.lock" ];then
    rm $targetdir/iso/ -rf
    mkdir $targetdir/iso/boot/ -p
    mkdir $targetdir/iso/{.installer,.base,.installer-mp,.workdir} -p
    cp $script_dir/.cd-info $script_dir/Release.txt $script_dir/COPYING $script_dir/COPYRIGHT $script_dir/EULA   $targetdir/iso/  ||errlog "do copy elua to iso dir failed"
    cp -r $script_dir/proxmox $targetdir/iso/  ||errlog "do proxmox dir to iso dir failed"
    echo "" >  $targetdir/iso/auto-installer-capable
    touch  $targetdir/.isofs.lock
    fi
}

# Crate Proxmox VE iso info
isoinfo(){
echo $pveuuid > $targetdir/iso/.pxvirt-cd-id.txt
}


mount_proc(){
    mount -t proc /proc  $targetdir/rootfs/proc
    mount -t sysfs /sys  $targetdir/rootfs/sys
    mount -o bind /dev  $targetdir/rootfs/dev
    mount -o bind /dev/pts  $targetdir/dev/pts
}

umount_proc(){
    umount   $targetdir/rootfs/proc
    umount   $targetdir/rootfs/sys
    umount   $targetdir/rootfs/dev
    umount   $targetdir/dev/rootfs/pts
    umount -l $targetdir/overlay/mount
    umount -l $targetdir/overlay/base
}

# Create proxmox installer initrd hook
initramfs_hook(){
    cp $targetdir/iso/.pxvirt-cd-id.txt $targetdir/rootfs/ || errlog "copy .pxvirt-cd-id.txt  failed"
    cp $targetdir/iso/.cd-info $targetdir/rootfs/ || errlog "copy .cd-info   failed"
    cp $script_dir/init $targetdir/rootfs/usr/share/initramfs-tools || errlog "copy initpve   failed"
    cp $script_dir/pve_init_hook $targetdir/rootfs/usr/share/initramfs-tools/hooks/ || errlog "copy pve_init_hook   failed"
    for module in $modules; do
    	echo "$module" >> $targetdir/rootfs/etc/initramfs-tools/modules
    done
    chmod +x $targetdir/rootfs/usr/share/initramfs-tools/hooks/pve_init_hook
}

debconfig_set(){
	echo "locales locales/default_environment_locale select en_US.UTF-8" > $targetdir/overlay/mount/tmp/debconfig.txt
	echo "locales locales/locales_to_be_generated select en_US.UTF-8 UTF-8" >> $targetdir/overlay/mount/tmp/debconfig.txt
}
debconfig_write(){
	chroot $targetdir/overlay/mount/ debconf-set-selections /tmp/debconfig.txt
	chroot $targetdir/overlay/mount/ rm /tmp/debconfig.txt
}

fix_console_setup(){
cat > $targetdir/overlay/mount/etc/default/console-setup << 'EOF'
# CONFIGURATION FILE FOR SETUPCON

# Consult the console-setup(5) manual page.

ACTIVE_CONSOLES="/dev/tty[1-6]"

CHARMAP="UTF-8"

CODESET="Lat15"
FONTFACE="Fixed"
FONTSIZE="8x16"

VIDEOMODE=

# The following is an example how to use a braille font
# FONT='lat9w-08.psf.gz brl-8x8.psf'
EOF
}

# Create pxvirt-installer.squashfs
overlayfs(){
    if [ ! -f "$targetdir/.overlay.lock" ];then
        rm $targetdir/overlay/ -rf
        mkdir $targetdir/overlay/{base,upper,work,mount} -p
        mount -t squashfs -o ro $targetdir/pxvirt-base.squashfs  $targetdir/overlay/base || errlog "mount pxvirt-base.squashfs filesystem failed"
        mount -t overlay -o lowerdir=$targetdir/overlay/base,upperdir=$targetdir/overlay/upper,workdir=$targetdir/overlay/work  none $targetdir/overlay/mount || errlog "mount squashfs filesystem failed"

        curl -L https://mirrors.lierfang.com/proxmox/debian/pveport.gpg -o $targetdir/overlay/mount/etc/apt/trusted.gpg.d/pveport.gpg ||errlog "download apt key failed"
        echo "deb $portmirrors/$PRODUCT $codename main" > $targetdir/overlay/mount/etc/apt/sources.list.d/pveport.list  ||errlog "create apt mirrors failed"
        chroot $targetdir/overlay/mount apt update || errlog "apt update failed"
        debconfig_set
        debconfig_write
        LC_ALL=C DEBIAN_FRONTEND=noninteractive chroot $targetdir/overlay/mount apt -o DPkg::Options::="--force-confnew" install $grub_pkg openssh-client locales locales-all traceroute squashfs-tools spice-vdagent pci.ids pciutils gettext-base fonts-liberation eject ethtool efibootmgr dmeventd dnsutils lvm2 libstring-shellquote-perl console-setup wget curl vim iputils-* locales busybox initramfs-tools xorg openbox proxmox-installer pve-firmware zfsutils-linux zfs-zed spl btrfs-progs gdisk bash-completion zfs-initramfs dosfstools -y || errlog "install pveinstaller failed"
        fix_console_setup
        mkdir $targetdir/overlay/mount/usr/lib/modules/
        cp -r $targetdir/rootfs/lib/modules/* $targetdir/overlay/mount/usr/lib/modules/
        chroot $targetdir/overlay/mount/ apt clean
        rm -rf $targetdir/overlay/mount/var/cache/apt/archives/
        umount $targetdir/overlay/mount   || errlog "umount overlayfs failed"
        umount $targetdir/overlay/base  || errlog "umount pvebase overlayfs failed"
        touch $targetdir/.overlay.lock
    fi

    rm -rf $targetdir/overlay/upper/tmp/  $targetdir/pxvirt-installer.squashfs
    cp $targetdir/iso/.pxvirt-cd-id.txt $targetdir/overlay/upper/ || errlog "copy .pxvirt-cd-id.txt  failed"
    cp $targetdir/iso/.cd-info $targetdir/overlay/upper/ || errlog "copy .cd-info  failed"
    mkdir  $targetdir/overlay/upper/cdrom -p
    mksquashfs $targetdir/overlay/upper/ $targetdir/pxvirt-installer.squashfs || errlog "create pxvirt-installer.squashfs failed"
    touch $targetdir/.pve-installer.lock
}


copy_squ(){
    cp $targetdir/pxvirt-installer.squashfs $targetdir/iso/pxvirt-installer.squashfs
    cp $targetdir/pxvirt-base.squashfs $targetdir/iso/pxvirt-base.squashfs
}


generate_uuid() {
    local N B T

    for (( N=0; N < 8; N++ )); do
        B=$(( RANDOM%16 ))
        printf '%x' $B
    done

    printf '-'

    for (( N=0; N < 3; N++ )); do
        for (( i=0; i < 4; i++ )); do
            B=$(( RANDOM%16 ))
            printf '%x' $B
        done
        printf '-'
    done

    printf '4'
    for (( N=0; N < 3; N++ )); do
        B=$(( RANDOM%16 ))
        printf '%x' $B
    done

    T=$(( RANDOM%4+8 ))
    printf '%x' $T

    for (( N=0; N < 3; N++ )); do
        B=$(( RANDOM%16 ))
        printf '%x' $B
    done
}


# Check env
env_test(){
    if [ "$EUID" -ne 0 ]; then
        errlog "This script must be run as root."
    fi
    test -f "/usr/sbin/debootstrap" || errlog "debootstrap not found, use 'apt install debootstrap' to install"
    test -f "/usr/bin/mksquashfs" || errlog "squasfs-tools not found, use 'apt install squashfs-tools' to install"
    test -f "/usr/bin/xorriso" || errlog "xorriso not found, use 'apt install xorriso' to install"
}

# Build pxvirt-base.squashfs
buildroot(){
    if [ ! -f "$targetdir/pxvirt-base.squashfs" ];then
	if [  "$hostarch" == "loongarch64" ];then
		debootstrap --arch=$target_arch  --include=debian-ports-archive-keyring --exclude="exim4,exim4-base,usr-is-merged" --include="usrmerge,perl" --no-check-gpg $codename $targetdir/rootfs https://mirrors.lierfang.com/debian-ports/debian || errlog "debootstrap failed"
		chroot $targetdir/rootfs apt install usr-is-merged -y
		echo 'APT { Get { AllowUnauthenticated "1"; }; };' > $targetdir/rootfs/etc/apt/apt.conf.d/99allow_unauth
		chroot $targetdir/rootfs apt clean
	else
		debootstrap --arch=$target_arch $codename $targetdir/rootfs $mirrors/debian || errlog "debootstrap failed"
		echo "deb $mirrors/debian/ $codename main contrib non-free non-free-firmware" > $targetdir/rootfs/etc/apt/sources.list
		echo "deb $mirrors/debian/ "$codename"-updates main contrib non-free non-free-firmware" >> $targetdir/rootfs/etc/apt/sources.list
		echo "deb $mirrors/debian/ "$codename"-backports main contrib non-free non-free-firmware" >> $targetdir/rootfs/etc/apt/sources.list
		echo "deb $mirrors/debian-security "$codename"-security main contrib non-free non-free-firmware" >> $targetdir/rootfs/etc/apt/sources.list
	fi
    mksquashfs $targetdir/rootfs $targetdir/pxvirt-base.squashfs
    fi
}


# Download Proxmox VE Packages
create_pkg(){
    mount_proc
    if [ ! -f  "$targetdir/.package.lock" ];then
    curl -L https://mirrors.lierfang.com/proxmox/debian/pveport.gpg -o $targetdir/rootfs/etc/apt/trusted.gpg.d/pveport.gpg ||errlog "download apt key failed"
    echo "deb $portmirrors/$PRODUCT $codename main" > $targetdir/rootfs/etc/apt/sources.list.d/pveport.list  ||errlog "create apt mirrors failed"
    chroot $targetdir/rootfs apt clean
    rm -rf $targetdir/rootfs/var/cache/apt/archives/
    chroot $targetdir/rootfs apt update ||errlog "do apt update failed"

    if [ "$PRODUCT" == "pxvirt" ];then
	main_pkg="proxmox-ve"
    else
	main_pkg="proxmox-backup-server"
    fi

    if [ -f "proxmox/$PRODUCT-packages.list.line" ];then
        main_pkg=`cat proxmox/$PRODUCT-packages.list.line`
    fi

    chroot $targetdir/rootfs apt --download-only install -y  $main_pkg postfix squashfs-tools traceroute net-tools pci.ids pciutils efibootmgr xfsprogs fonts-liberation dnsutils $extra_pkg $grub_pkg gettext-base sosreport ethtool dmeventd eject chrony locales locales-all systemd rsyslog ifupdown2 ksmtuned zfsutils-linux zfs-zed spl btrfs-progs gdisk bash-completion zfs-initramfs dosfstools||errlog "download proxmox-ve package failed"

    if [ ! -z "$extra_kernel" ] && [ "$PRODUCT" != "pbs" ] ;then
	if [ "$target_arch" == "arm64"  ]  || [ "$target_arch" == "loong64"  ] ;then
        	chroot $targetdir/rootfs apt --download-only install -y  $extra_kernel ||errlog "kernel installed failed"
    	fi
    fi

    if [ "$target_arch" != "amd64" ];then
        chroot $targetdir/rootfs apt --download-only install -y $main_kernel  ||errlog "kernel installed failed"
    fi

    mkdir $targetdir/iso/proxmox/packages/ -p
    cp -r $targetdir/rootfs/var/cache/apt/archives/*.deb $targetdir/iso/proxmox/packages/  ||errlog "do copy pkg failed"
    touch $targetdir/.package.lock
    fi

    if [ ! -f "$targetdir/.mainkernel.lock" ];then
        chroot $targetdir/rootfs apt install initramfs-tools -y
	    initramfs_hook
	    chroot $targetdir/rootfs apt install pve-firmware $main_kernel -y ||errlog "kernel installed failed"
	    echo "copy main kernel"
	    cp $targetdir/rootfs/boot/initrd.img-* $targetdir/iso/boot/initrd.img  ||errlog "do copy initrd failed"
	    cp $targetdir/rootfs/boot/vmlinuz-*  $targetdir/iso/boot/linux26  ||errlog "do copy kernel failed"
	    touch $targetdir/.mainkernel.lock
    fi


    if [ ! -z "$extra_kernel"  ] && [ "$target_arch" != "amd64"  ] ;then

	chroot $targetdir/rootfs apt install $extra_kernel -y ||errlog "Extra kernel installed failed"

        if [[ "$extra_kernel" =~ "openeuler" ]];then
            cp $targetdir/rootfs/boot/initrd.img-*-openeuler $targetdir/iso/boot/initrd.img-openeuler  ||errlog "do copy initrd failed"
            cp $targetdir/rootfs/boot/vmlinuz-*-openeuler  $targetdir/iso/boot/linux26-openeuler  ||errlog "do copy kernel failed"
        fi

        if [[ "$extra_kernel" =~ -pve ]]; then
                cp $targetdir/rootfs/boot/initrd.img-*-pve $targetdir/iso/boot/initrd.img-pve  ||errlog "do copy initrd failed"
                cp $targetdir/rootfs/boot/vmlinuz-*-pve  $targetdir/iso/boot/linux26-pve  ||errlog "do copy kernel failed"
        fi

        if [[ "$extra_kernel" =~ -generic ]]; then
                cp $targetdir/rootfs/boot/initrd.img-*-generic $targetdir/iso/boot/initrd.img-generic  ||errlog "do copy initrd failed"
                cp $targetdir/rootfs/boot/vmlinuz-*-generic  $targetdir/iso/boot/linux26-generic  ||errlog "do copy kernel failed"
        fi

        if [[ "$extra_kernel" =~ phytium ]]; then
                cp $targetdir/rootfs/boot/initrd.img-*-phytium $targetdir/iso/boot/initrd.img-phytium  ||errlog "do copy initrd failed"
                cp $targetdir/rootfs/boot/vmlinuz-*-phytium  $targetdir/iso/boot/linux26-phytium  ||errlog "do copy kernel failed"
        fi
    fi

    if [ "$target_arch" == "amd64" ];then
	echo "copy x86_64 init"
        cp $targetdir/rootfs/boot/initrd.img* $targetdir/iso/boot/initrd.img  ||errlog "do copy initrd failed"
        cp $targetdir/rootfs/boot/vmlinuz*  $targetdir/iso/boot/linux26  ||errlog "do copy kernel failed"
    fi

    umount_proc
}

build_iso(){
    rm $targetdir/iso/*.iso -rf
    isodate2=`echo $isodate|sed  "s/-//g"`
    cd $targetdir/iso/
    cp $script_dir/boot.cat $targetdir/iso/boot  ||errlog "do copy boot.cat failed"
    cp $script_dir/iso.mbr $targetdir/iso/boot  ||errlog "do copy iso.mbr failed"
    cp $script_dir/eltorito.img $targetdir/iso/boot  ||errlog "do copy eltorito failed"
    xorriso -as mkisofs  \
    -V 'PVE' \
    -o $targetdir/$ISONAME-$RELEASE-$ISORELEASE-$target_arch-$isodate2.iso \
    --grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt,zero_apm:'./boot/iso.mbr' \
    --modification-date=$isodate2 \
    -partition_cyl_align off \
    -partition_offset 0 \
    -partition_hd_cyl 67 \
    -partition_sec_hd 32 \
    -apm-block-size 2048 \
    -hfsplus \
    -efi-boot-part --efi-boot-image \
    -c '/boot/boot.cat' \
    -b '/boot/eltorito.img' \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --grub2-boot-info \
    -eltorito-alt-boot \
    -iso-level 3 \
    -e '/boot/grub/efi.img' \
    -no-emul-boot \
    -boot-load-size 16384 \
    .
}


# Create efi.img
mkefi_img(){
    dd if=/dev/zero of=$targetdir/iso/boot/grub/efi.img bs=512 count=20480
    mkfs.fat -F 16 -n 'EFI' $targetdir/iso/boot/grub/efi.img
    rm /tmp/efi -rf
    mkdir /tmp/efi/
    mount $targetdir/iso/boot/grub/efi.img /tmp/efi
    cp -r $targetdir/iso/EFI  /tmp/efi  ||errlog "do EFI file failed"
    umount -l /tmp/efi
}


# Install ISO Grub
grub_install(){

if [ ! -f "$targetdir/.grub.lock" ];then
    rm $targetdir/iso/boot/grub/ -rf
    rm $targetdir/iso/EFI -rf
    mkdir $targetdir/iso/EFI/BOOT/ -p
    mkdir $targetdir/iso/boot/grub -p
    echo "do grub install"
    grub-mkimage -o $targetdir/iso/EFI/BOOT/$grub_file -O $grub_prefix-efi -p /EFI/BOOT/ \
	boot linux chain normal configfile \
	part_gpt part_msdos fat iso9660 udf \
	test true keystatus loopback regexp probe \
	efi_gop all_video gfxterm font \
	echo read help ls cat halt reboot lvm ext2 xfs  hfsplus hfs \
    acpi search_label search search_fs_file search_fs_uuid \
    serial terminfo terminal zfs btrfs efifwsetup

    cp -r /boot/grub/ $targetdir/iso/boot/  ||errlog "do grub dir failed"
    cp $script_dir/grub.cfg $targetdir/iso/boot/grub/  ||errlog "do copy grub cfg  failed"
    cp -r $script_dir/pvetheme  $targetdir/iso/boot/grub/  ||errlog "do copy grub pvethem failed"
    touch $targetdir/.grub.lock
fi
cat > $targetdir/iso/EFI/BOOT/grub.cfg << EOF
search --fs-uuid --set=root $isodate
set prefix=(\${root})/boot/grub
source \${prefix}/grub.cfg
insmod part_acorn
insmod part_amiga
insmod part_apple
insmod part_bsd
insmod part_dfly
insmod part_dvh
insmod part_gpt
insmod part_msdos
insmod part_plan
insmod part_sun
insmod part_sunpc
EOF


}

# Main Start
umount_proc

if [ "$1" == "clean" ];then
    rm $targetdir -rf
    mkdir $targetdir/rootfs -p
fi
pveuuid=$(generate_uuid)
isodate=`date +"%Y-%m-%d-%H-%M-%S-00"`
env_test
isofs
isoinfo
buildroot
create_pkg
grub_install
mkefi_img
overlayfs
copy_squ

build_iso
