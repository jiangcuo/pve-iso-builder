#!/bin/bash
#proxmox arm64 iso builder
script_path=$(readlink -f "$0")
script_dir=$(dirname "$script_path")
extra_pkg="ceph-common ceph-fuse iperf3 net-sriov-tools"  #if you want install other package
hostarch=`arch`     # This scripts only allow the same arch build.
codename="bookworm"  # proxmox version. bookworm->pve8 ,bullseye->pve7
targetdir="/data/targetdir" # tmpdir
modules="hfs hfsplus cdrom sd_mod sr_mod loop squashfs iso9660 drm overlay uas hibmc-drm dw_drm_dsi kirin_drm amdgpu nouveau ast radeon virtio-gpu mgag200"

# iso info
source $script_dir/.cd-info

# 软件包族:按构建主机自动判定 —— 有 apt 走 Debian,否则走 openEuler/dnf
if command -v apt >/dev/null 2>&1; then
    FAMILY="deb"
else
    FAMILY="rpm"
fi

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
elif [ "$hostarch" == "loongarch64" ];then
    target_arch="loong64"
    grub_prefix="loongarch64"
    grub_file="BOOTLOONGARCH64.EFI"
    grub_pkg="grub-common  grub-efi-loong64-bin grub-efi-loong64 grub2-common"
    if [ "$PRODUCT" == "pbs" ];then
        main_kernel="pve-kernel-6.12-4k-pve"  #pbs need 4k kernel
    fi
elif [ "$hostarch" == "riscv64" ];then
    target_arch="riscv64"
    grub_prefix="riscv64"
    grub_file="BOOTRISCV64.EFI"
    grub_pkg="grub-common  grub-efi-riscv64-bin grub-efi-riscv64 grub2-common"
    codename="sid"
fi

# FAMILY=rpm:换成 openEuler/RPM 的包名。顶部 extra_pkg/grub_pkg 是 Debian 名,这里覆盖。
if [ "$FAMILY" == "rpm" ];then
    case "$hostarch" in
        x86_64)  grub_pkg="grub2-pc grub2-pc-modules grub2-efi-x64 grub2-efi-x64-modules grub2-tools shim-x64" ;;
        aarch64) grub_pkg="grub2-efi-aa64 grub2-efi-aa64-modules grub2-tools shim-aa64" ;;
        loongarch64) grub_pkg="grub2-efi-loong64 grub2-efi-loong64-modules grub2-tools" ;;
        riscv64) grub_pkg="grub2-efi-riscv64 grub2-efi-riscv64-modules grub2-tools" ;;
    esac
    # Debian 专属的 extra_pkg 默认值在 rpm 下不适用;需要时在 .cd-info 用 rpm 包名覆盖
    extra_pkg="${rpm_extra_pkg:-}"
fi


errlog(){
	if [ $? != 0 ];then
		echo $1
        umount_proc
		exit 1
	fi
}

# chroot 内做 apt/dnf/包脚本时需要 DNS;把宿主机的 resolv.conf 拷进 <root>。
# debootstrap 会自带,但 dnf --installroot 拉的 base 和 squashfs base 里没有。
setup_resolv(){
    local root="$1"
    mkdir -p $root/etc
    cp -L /etc/resolv.conf $root/etc/resolv.conf 2>/dev/null \
        || echo "nameserver 223.5.5.5" > $root/etc/resolv.conf
}

remove_pxvirt_repo(){
    local root="$1"
    rm -f "$root/etc/yum.repos.d/pxvirt.repo"
}

# 删掉 SSH 主机密钥,避免被烤进 squashfs 导致所有 Live/装机共用同一对密钥。
# openEuler 靠 sshd-keygen@.service 首次启动 sshd 时重新生成,这里只是兜底清掉。
clean_ssh_hostkeys(){
    local root="$1"
    rm -f $root/etc/ssh/ssh_host_*key $root/etc/ssh/ssh_host_*key.pub 2>/dev/null
}

# 在脚本入口处调一次,把构建期的全局变量 export 给 hook 子 shell。
# HOOK_NAME 每个 hook 各异,留在 run_hook 里设置。
export_hook_env(){
    export TARGETDIR="$targetdir"
    export SCRIPT_DIR="$script_dir"
    export TARGET_ARCH="$target_arch"
    export HOST_ARCH="$hostarch"
    export PRODUCT="$PRODUCT"
    export CODENAME="$codename"
    export GRUB_PKG="$grub_pkg"
    export EXTRA_PKG="$extra_pkg"
    export MAIN_PKG="$main_pkg"
    export MAIN_KERNEL="$main_kernel"
    export EXTRA_KERNEL="$extra_kernel"
    export MODULES="$modules"
    export PVEUUID="$pveuuid"
    export ISODATE="$isodate"
    export MIRRORS="$mirrors"
    export PORTMIRRORS="$portmirrors"
}

# 简化Hook系统
run_hook(){
    local hook_name="$1"
    local hook_dir="$script_dir/hooks/$hook_name"

    if [ -d "$hook_dir" ]; then
        echo "Running hooks: $hook_name"
        export HOOK_NAME="$hook_name"
        for hook_script in "$hook_dir"/*.sh; do
            chmod +x $hook_script
            if [ -x "$hook_script" ]; then
                echo "  -> Executing: $(basename $hook_script)"
                # 执行hook脚本，先加载通用变量
                (
                    # 在子shell中执行，避免污染主脚本环境
                    if [ -f "$script_dir/hooks/common.sh" ]; then
                        source "$script_dir/hooks/common.sh"
                    fi
                    "$hook_script"
                ) || errlog "Hook $(basename $hook_script) failed"
            else
                echo "脚本无权限"
            fi
        done
    fi
}

# Create isofs
isofs(){
    if [ ! -f "$targetdir/.isofs.lock" ];then
    rm $targetdir/iso/ -rf
    mkdir $targetdir/iso/boot/ -p
    mkdir $targetdir/iso/{.installer,.base,.installer-mp,.workdir} -p
    cp $script_dir/.cd-info $script_dir/Release.txt $script_dir/COPYING $script_dir/COPYRIGHT $script_dir/EULA  $targetdir/iso/  ||errlog "do copy elua to iso dir failed"
    cp -r $script_dir/proxmox $targetdir/iso/  ||errlog "do proxmox dir to iso dir failed"
    echo "" >  $targetdir/iso/auto-installer-capable
    touch  $targetdir/.isofs.lock
    fi
}

# Crate Proxmox VE iso info
# .pxvirt-cd-id.txt:Live 启动期 probe 脚本按内容比对(deb 的 PVE init / rpm 的 pxvirt-dracut 都用)
# .pxvirt-medium-<uuid>:EFI grub.cfg 用 search --file 寻根的随机标记。
#   每次构建唯一,多介质同插不撞;ISO9660/FAT/任何文件系统都能命中,
#   软碟通这类工具解压到 FAT U 盘后也能保留并启动。
isoinfo(){
    echo $pveuuid > $targetdir/iso/.pxvirt-cd-id.txt
    : > $targetdir/iso/.pxvirt-medium-$pveuuid
}


mount_proc(){
    mount -t proc /proc  $targetdir/rootfs/proc
    mount -t sysfs /sys  $targetdir/rootfs/sys
    mount -o bind /dev  $targetdir/rootfs/dev
    mount -o bind /dev/pts  $targetdir/rootfs/dev/pts
}

# 入口处和 errlog 都会调,可能挂载根本不存在,所以每条都 || true 保持幂等
umount_proc(){
    umount    $targetdir/rootfs/dev/pts     2>/dev/null || true
    umount    $targetdir/rootfs/dev         2>/dev/null || true
    umount    $targetdir/rootfs/sys         2>/dev/null || true
    umount    $targetdir/rootfs/proc        2>/dev/null || true
    umount -l $targetdir/overlay/mount      2>/dev/null || true
    umount -l $targetdir/overlay/base       2>/dev/null || true
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

# 往 overlay 装 Live 安装环境(Debian/apt)
install_installer_deb(){
    curl -L https://mirrors.lierfang.com/pxcloud/lierfang.gpg -o $targetdir/overlay/mount/etc/apt/trusted.gpg.d/lierfang.gpg ||errlog "download apt key failed"
    echo "deb $portmirrors/$PRODUCT $codename main" > $targetdir/overlay/mount/etc/apt/sources.list.d/pxvirt-sources.list  ||errlog "create apt mirrors failed"
    chroot $targetdir/overlay/mount apt update || errlog "apt update failed"
    debconfig_set
    debconfig_write
    LC_ALL=C DEBIAN_FRONTEND=noninteractive chroot $targetdir/overlay/mount apt -o DPkg::Options::="--force-confnew" install $grub_pkg openssh-client openssh-server tigervnc-standalone-server tigervnc-common locales locales-all traceroute squashfs-tools spice-vdagent pci.ids pciutils gettext-base fonts-liberation eject ethtool efibootmgr dmeventd dnsutils lvm2 libstring-shellquote-perl console-setup wget curl vim iputils-* locales busybox initramfs-tools xorg openbox proxmox-installer pve-firmware zfsutils-linux zfs-zed spl btrfs-progs gdisk bash-completion zfs-initramfs dosfstools -y || errlog "install pveinstaller failed"
    fix_console_setup
    clean_ssh_hostkeys $targetdir/overlay/mount
}

# 往 overlay 装 Live 安装环境(openEuler/dnf)。kernel 由 mainkernel_rpm 在干净的
# rootfs 里安装并跑 dracut,这里只装安装器 GUI 及其依赖,modules 由 overlayfs() 抄过来
install_installer_rpm(){
    write_oe_repo $targetdir/overlay/mount
    write_pxvirt_repo $targetdir/overlay/mount
    dnf -y --installroot=$targetdir/overlay/mount --releasever=$oeversion --nogpgcheck install \
        $grub_pkg openssh-clients openssh-server tigervnc-server glibc-langpack-en squashfs-tools spice-vdagent \
        hwdata pciutils gettext liberation-fonts util-linux ethtool efibootmgr \
        google-noto-sans-fonts xorg-x11-xinit xorg-x11-xauth \
        lvm2 bind-utils kbd iputils dracut wget curl vim-minimal busybox \
        xorg-x11-server-Xorg  xorg-x11-drv-libinput xorg-x11-drv-evdev xorg-x11-drv-wacom openbox pve-installer linux-firmware perl-String-ShellQuote \
        zfs zfs-dracut btrfs-progs gdisk bash-completion dosfstools \
        || errlog "install pve-installer failed"
    # 取代 debconf/console-setup
    echo "LANG=en_US.UTF-8" > $targetdir/overlay/mount/etc/locale.conf
    echo "KEYMAP=us"        > $targetdir/overlay/mount/etc/vconsole.conf
    clean_ssh_hostkeys $targetdir/overlay/mount
    remove_pxvirt_repo $targetdir/overlay/mount
}

# Create pxvirt-installer.squashfs
overlayfs(){
    if [ ! -f "$targetdir/.overlay.lock" ];then
        rm $targetdir/overlay/ -rf
        mkdir $targetdir/overlay/{base,upper,work,mount} -p
        mount -t squashfs -o ro $targetdir/pxvirt-base.squashfs  $targetdir/overlay/base || errlog "mount pxvirt-base.squashfs filesystem failed"
        mount -t overlay -o lowerdir=$targetdir/overlay/base,upperdir=$targetdir/overlay/upper,workdir=$targetdir/overlay/work  none $targetdir/overlay/mount || errlog "mount squashfs filesystem failed"

        # 装 installer 时 chroot apt/dnf 要解析 DNS
        setup_resolv $targetdir/overlay/mount

        if [ "$FAMILY" == "rpm" ];then
            install_installer_rpm
        else
            install_installer_deb
        fi
        # kernel 装在干净的 rootfs 里(create_pkg 里的 mainkernel_*),modules 抄到 overlay
        mkdir $targetdir/overlay/mount/usr/lib/modules/
        cp -r $targetdir/rootfs/lib/modules/* $targetdir/overlay/mount/usr/lib/modules/

        # addmodules_hook - 用于添加额外的模块
        run_hook "addmodules"

        # overlayfs hook - 用于添加overlay的脚本
        run_hook "overlayfs"

        #create grub use overlay binary
        grub_install
        mkefi_img
        if [ "$FAMILY" == "rpm" ];then
            dnf -y --installroot=$targetdir/overlay/mount clean all
            #rm -rf $targetdir/overlay/mount/var/cache/dnf
        else
            chroot $targetdir/overlay/mount/ apt clean
            rm -rf $targetdir/overlay/mount/var/cache/apt/archives/
        fi
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
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        uuidgen
    fi
}


# Check env
env_test(){
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run as root."
        exit 1
    fi
    if [ "$FAMILY" == "rpm" ];then
        command -v dnf >/dev/null            || errlog "dnf not found, build rpm iso on an openEuler host"
        command -v grub2-mkimage >/dev/null  || errlog "grub2-mkimage not found, use 'dnf install grub2-tools' to install"
    else
        command -v debootstrap >/dev/null || errlog "debootstrap not found, use 'apt install debootstrap' to install"
    fi
    command -v mksquashfs >/dev/null || errlog "squasfs-tools not found, use 'apt install squashfs-tools || dnf install squashfs-tools' to install"
    command -v xorriso >/dev/null || errlog "xorriso not found, use 'apt install xorriso || dnf install xorriso' to install"
}

# 写 openEuler base 源(rpm),供 buildroot/create_pkg/overlayfs 复用
write_oe_repo(){
    local root="$1"
    mkdir -p $root/etc/yum.repos.d
    cat > $root/etc/yum.repos.d/openEuler.repo <<EOF
[OS]
name=openEuler-OS
baseurl=$oemirrors/$oeversion/OS/\$basearch/
enabled=1
gpgcheck=0
[everything]
name=openEuler-everything
baseurl=$oemirrors/$oeversion/everything/\$basearch/
enabled=1
gpgcheck=0
[EPOL]
name=openEuler-EPOL
baseurl=$oemirrors/$oeversion/EPOL/main/\$basearch/
enabled=1
gpgcheck=0
[update]
name=openEuler-update
baseurl=$oemirrors/$oeversion/update/\$basearch/
enabled=1
gpgcheck=0
EOF
}

# 写 pxvirt 产品 rpm 源(带鉴权)。用户名/密码从环境变量 PXVIRT_REPO_USER/PXVIRT_REPO_PASS 取
write_pxvirt_repo(){
    local root="$1"
    mkdir -p $root/etc/yum.repos.d
    cat > $root/etc/yum.repos.d/pxvirt.repo <<EOF
[pxvirt]
name=Lierfang PxVirt Repo
baseurl=$pxvmirrors/\$basearch
enabled=1
gpgcheck=0
username=$PXVIRT_REPO_USER
password=$PXVIRT_REPO_PASS
EOF
}

# debootstrap 拉 Debian base
buildroot_deb(){
	if [  "$hostarch" == "loongarch64" ];then
		debootstrap --arch=$target_arch  --include=debian-ports-archive-keyring --exclude="exim4,exim4-base,usr-is-merged" --include="usrmerge,perl" --no-check-gpg sid $targetdir/rootfs https://debianports.mirrors.lierfang.com/$codename || errlog "debootstrap failed"
		chroot $targetdir/rootfs apt install usr-is-merged -y
		echo 'APT { Get { AllowUnauthenticated "1"; }; };' > $targetdir/rootfs/etc/apt/apt.conf.d/99allow_unauth
		chroot $targetdir/rootfs apt clean
        chroot $targetdir/rootfs passwd -d root
	else
		debootstrap --arch=$target_arch $codename $targetdir/rootfs $mirrors/debian || errlog "debootstrap failed"
		echo "deb $mirrors/debian/ $codename main contrib non-free non-free-firmware" > $targetdir/rootfs/etc/apt/sources.list
		echo "deb $mirrors/debian/ "$codename"-updates main contrib non-free non-free-firmware" >> $targetdir/rootfs/etc/apt/sources.list
		echo "deb $mirrors/debian/ "$codename"-backports main contrib non-free non-free-firmware" >> $targetdir/rootfs/etc/apt/sources.list
		echo "deb $mirrors/debian-security "$codename"-security main contrib non-free non-free-firmware" >> $targetdir/rootfs/etc/apt/sources.list
	fi
}

# dnf --installroot 拉 openEuler base(RPM 库落在 rootfs 内,便于离线升级)
buildroot_rpm(){
    write_oe_repo $targetdir/rootfs
    dnf -y --installroot=$targetdir/rootfs --releasever=$oeversion \
        --setopt=install_weak_deps=False \
        --setopt=group_package_types=mandatory \
        --nogpgcheck \
        --exclude='kernel*,linux-firmware,NetworkManager*,tuned,systemtap*,firewalld' \
        install openEuler-release dnf nano net-tools @core tar || errlog "dnf installroot base failed"
    dnf -y --installroot=$targetdir/rootfs clean all

    # create subid
    touch $targetdir/rootfs/etc/subuid $targetdir/rootfs/etc/subgid
    grep -q '^root:100000:65536$' $targetdir/rootfs/etc/subuid || echo 'root:100000:65536' >> $targetdir/rootfs/etc/subuid
    grep -q '^root:100000:65536$' $targetdir/rootfs/etc/subgid || echo 'root:100000:65536' >> $targetdir/rootfs/etc/subgid
    chmod 0644 $targetdir/rootfs/etc/subuid $targetdir/rootfs/etc/subgid
    
    chroot $targetdir/rootfs systemctl disable firewalld || errlog "disable firewalld failed"
    rm -rf $targetdir/rootfs/var/cache/dnf
}

# Build pxvirt-base.squashfs
buildroot(){
    if [ ! -f "$targetdir/pxvirt-base.squashfs" ];then
    if [ "$FAMILY" == "rpm" ];then
        buildroot_rpm
    else
        buildroot_deb
    fi

    # chroot/包脚本要解析 DNS,确保 base 里有 resolv.conf
    setup_resolv $targetdir/rootfs

    # buildroot hook - 用于处理root镜像
    run_hook "buildroot"

    mksquashfs $targetdir/rootfs $targetdir/pxvirt-base.squashfs
    fi
}


# apt --download-only:把产品 deb + 依赖塞进 iso/proxmox/packages
create_pkg_deb(){
    curl -L https://mirrors.lierfang.com/pxcloud/lierfang.gpg -o $targetdir/rootfs/etc/apt/trusted.gpg.d/lierfang.gpg ||errlog "download apt key failed"
    echo "deb $portmirrors/$PRODUCT $codename main" > $targetdir/rootfs/etc/apt/sources.list.d/pxvirt-sources.list  ||errlog "create apt mirrors failed"
    if [ ! -z "$ceph" ];then
    	if [ "$ceph"  == "reef" ] || [ "$ceph"  == "squid" ] || [ "$ceph"  == "quincy" ];then
	    echo "add ceph mirror"
	    echo "deb $portmirrors/$PRODUCT $codename ceph-$ceph" >> $targetdir/rootfs/etc/apt/sources.list.d/pxvirt-sources.list  ||errlog "create apt mirrors failed"
	    ceph="ceph"
	else
	    ceph=""
	fi
    fi
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

    chroot $targetdir/rootfs apt --download-only install -y  $ceph  $main_pkg  $main_kernel $extra_kernel postfix squashfs-tools traceroute net-tools pci.ids pciutils efibootmgr xfsprogs fonts-liberation dnsutils $extra_pkg $grub_pkg gettext-base sosreport ethtool dmeventd eject chrony locales locales-all systemd rsyslog ifupdown2 ksmtuned zfsutils-linux zfs-zed spl btrfs-progs gdisk bash-completion zfs-initramfs dosfstools||errlog "download proxmox-ve package failed"

    mkdir $targetdir/iso/proxmox/packages/ -p
    cp -r $targetdir/rootfs/var/cache/apt/archives/*.deb $targetdir/iso/proxmox/packages/  ||errlog "do copy pkg failed"
}

# dnf install --downloadonly:把产品 rpm + 依赖塞进 iso/proxmox/packages(对着 base 只取增量)
create_pkg_rpm(){
    write_pxvirt_repo $targetdir/rootfs

    main_pkg="pxvirt"

    mkdir $targetdir/iso/proxmox/packages/ -p
    # 先下到临时目录,再搬到 iso 包目录。dnf 在 --installroot 上后续做 install 收
    # 尾清缓存时会把 --downloaddir 也清掉,直接下到 iso 包目录会丢失。
    local rpm_tmp=$targetdir/rpm-download
    rm -rf $rpm_tmp && mkdir -p $rpm_tmp
    dnf -y --installroot=$targetdir/rootfs --releasever=$oeversion --nogpgcheck \
        --setopt=install_weak_deps=False \
        install --downloadonly --downloaddir=$rpm_tmp \
        $main_pkg $main_kernel $extra_kernel $extra_pkg $grub_pkg \
        postfix net-tools pciutils efibootmgr xfsprogs liberation-fonts bind-utils apparmor-parser apparmor-abstractions\
        ethtool chrony glibc-langpack-en systemd rsyslog ifupdown2 lvm2 rsync perl-String-ShellQuote \
        btrfs-progs gdisk dosfstools bash-completion zfs zfs-dracut dracut  kmod linux-firmware ceph \
        || errlog "download pxvirt rpm package failed"
    mv $rpm_tmp/*.rpm $targetdir/iso/proxmox/packages/ || errlog "move rpm to iso packages dir failed"
    rmdir $rpm_tmp 2>/dev/null
}

# 装机内核 + Live initrd 拷到 iso/boot
mainkernel_deb(){
    chroot $targetdir/rootfs apt install initramfs-tools -y
    initramfs_hook
    chroot $targetdir/rootfs apt install pve-firmware $main_kernel -y ||errlog "kernel installed failed"
    echo "copy main kernel"
    cp $targetdir/rootfs/boot/initrd.img-* $targetdir/iso/boot/initrd.img  ||errlog "do copy initrd failed"
    cp $targetdir/rootfs/boot/vmlinuz-*  $targetdir/iso/boot/linux26  ||errlog "do copy kernel failed"
}

# 手动把 pxvirt-dracut 模块装进 <root> 的 dracut 模块目录(不做 rpm 包)
install_pxvirt_dracut(){
    echo "Install Dracut Hook"
    local root="$1"
    local moddir="$root/usr/lib/dracut/modules.d/90pxvirt-live"
    local src="$script_dir/pxvirt-dracut"
    mkdir -p $moddir || errlog "mkdir dracut module dir failed"
    cp $src/* $moddir/ || errlog "copy dracut module files failed"
    chmod +x $moddir/*.sh $moddir/pxvirt-live-root
}

# 过滤出目标内核里真实存在的模块。$modules 是按 Debian/PVE 内核调的,openEuler 内核
# 缺少 hibmc-drm/dw_drm_dsi/kirin_drm 等;dracut --add-drivers 只要有一个找不到就整批失败,
# 故先用 modinfo 剔除缺失项(initramfs-tools 本就静默跳过,deb 路径无需此步)。
filter_modules(){
    local kver="$1" root="$2" out="" m
    for m in $modules; do
        if chroot "$root" modinfo -k "$kver" "$m" >/dev/null 2>&1; then
            out="$out $m"
        else
            echo "skip missing kernel module: $m" >&2
        fi
    done
    echo "$out"
}

filter_grub_modules(){
    local root="$1" platform="$2" out="" m
    shift 2

    for m in "$@"; do
        if [ -f "$root/usr/lib/grub/$platform/$m.mod" ] || [ -f "$root/boot/grub/$platform/$m.mod" ]; then
            out="$out $m"
        else
            echo "skip missing grub module: $platform/$m.mod" >&2
        fi
    done

    echo "$out"
}

# 装机内核 + Live initrd 拷到 iso/boot
# 装在 rootfs(干净环境,create_pkg 里 mount_proc 已经挂好 /proc /sys /dev,
# 内核 post-install 跑 dracut 不会因为缺挂载而失败)
mainkernel_rpm(){
    dnf -y --installroot=$targetdir/rootfs --releasever=$oeversion --nogpgcheck \
        install $main_kernel dracut linux-firmware kmod ||errlog "kernel installed failed"
    install_pxvirt_dracut $targetdir/rootfs
    local kver=$(ls $targetdir/rootfs/lib/modules | head -n1)
    local addmods=$(filter_modules "$kver" "$targetdir/rootfs")
    chroot $targetdir/rootfs dracut --force --no-hostonly \
        --add pxvirt-live --add-drivers "$addmods" \
        /boot/initrd-pxvirt-live.img $kver ||errlog "dracut build pxvirt-live initramfs failed"
    cp $targetdir/rootfs/boot/initrd-pxvirt-live.img $targetdir/iso/boot/initrd.img ||errlog "do copy initrd failed"
    cp $targetdir/rootfs/boot/vmlinuz-$kver          $targetdir/iso/boot/linux26    ||errlog "do copy kernel failed"
}

# Download Proxmox VE Packages
create_pkg(){
    mount_proc
    if [ ! -f  "$targetdir/.package.lock" ];then
        if [ "$FAMILY" == "rpm" ];then
            create_pkg_rpm
        else
            create_pkg_deb
        fi
        touch $targetdir/.package.lock
    fi

    if [ ! -f "$targetdir/.mainkernel.lock" ];then
        if [ "$FAMILY" == "rpm" ];then
            mainkernel_rpm
        else
            mainkernel_deb
        fi
        touch $targetdir/.mainkernel.lock
    fi

    umount_proc
}

build_iso(){
    rm $targetdir/iso/*.iso -rf
    isodate2=`echo $isodate|sed  "s/-//g"`
    pushd $targetdir/iso/ >/dev/null
    cp $script_dir/boot.cat $targetdir/iso/boot  ||errlog "do copy boot.cat failed"
    cp $script_dir/iso.mbr $targetdir/iso/boot  ||errlog "do copy iso.mbr failed"
    cp $script_dir/eltorito.img $targetdir/iso/boot  ||errlog "do copy eltorito failed"

    # build_iso hook - 用于添加文件到iso
    run_hook "build_iso"

    xorriso -as mkisofs  \
    -V 'PXVIRT' \
    -o $targetdir/$ISONAME-$RELEASE-$ISORELEASE-$target_arch.iso \
    --grub2-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt,zero_apm:'./boot/iso.mbr' \
    --modification-date=$isodate2 \
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
    . || errlog "build iso failed"
    popd >/dev/null
}


# Create efi.img
mkefi_img(){
    dd if=/dev/zero of=$targetdir/iso/boot/grub/efi.img bs=512 count=20480
    mkfs.fat -F 16 -n 'EFI' $targetdir/iso/boot/grub/efi.img
    # mktemp 避免与残留挂载或并发构建冲突;同名 EFI_MOUNT 透传给 hook(common.sh 已用 ${EFI_MOUNT:-...})
    export EFI_MOUNT=$(mktemp -d)
    mount $targetdir/iso/boot/grub/efi.img $EFI_MOUNT
    cp -r $targetdir/iso/EFI  $EFI_MOUNT  ||errlog "do EFI file failed"

    # mkefi_img hook - 用于添加efi文件
    run_hook "mkefi_img"

    umount -l $EFI_MOUNT
    rmdir $EFI_MOUNT 2>/dev/null || true
}


# Install ISO Grub
grub_install(){

if [ ! -f "$targetdir/.grub.lock" ];then
    rm $targetdir/iso/boot/grub/ -rf
    rm $targetdir/iso/EFI -rf
    mkdir $targetdir/iso/EFI/BOOT/ -p
    mkdir $targetdir/iso/boot/grub -p
    echo "do grub install"
    # host/overlay 工具名:Debian=grub-mkimage,openEuler=grub2-mkimage
    if [ "$FAMILY" == "rpm" ];then gmkimage="grub2-mkimage"; else gmkimage="grub-mkimage"; fi
    local grub_platform="$grub_prefix-efi"
    local grub_modules=$(filter_grub_modules "$targetdir/overlay/mount" "$grub_platform" \
        boot linux chain normal configfile \
        part_gpt part_msdos fat iso9660 udf \
        test true keystatus loopback regexp probe \
        efi_gop all_video gfxterm font \
        echo read help ls cat halt reboot lvm ext2 xfs hfsplus hfs \
        acpi search_label search search_fs_file search_fs_uuid \
        serial terminfo terminal zfs btrfs efifwsetup \
        usbserial_pl2303 usbserial_usbdebug usbserial_ftdi usbserial_common usb smbios)
    mkdir $targetdir/overlay/mount/efi
    mount -o bind $targetdir/iso/EFI/BOOT/ $targetdir/overlay/mount/efi
    chroot $targetdir/overlay/mount/ $gmkimage -o /efi/$grub_file -O $grub_platform -p /EFI/BOOT/ \
        $grub_modules || errlog "grub mkimage failed"

    umount $targetdir/overlay/mount/efi
    rm -rf $targetdir/overlay/mount/efi

    if [ "$FAMILY" == "rpm" ];then
        # openEuler:grub 模块在 /usr/lib/grub,字体在 /usr/share/grub
        cp -r $targetdir/overlay/mount/usr/lib/grub/$grub_prefix-efi $targetdir/iso/boot/grub/  ||errlog "do grub dir failed"
        cp $targetdir/overlay/mount/usr/share/grub/unicode.pf2 $targetdir/iso/boot/grub/ 2>/dev/null
    else
        cp -r $targetdir/overlay/mount/boot/grub/ $targetdir/iso/boot/  ||errlog "do grub dir failed"
    fi
    
    if [ -d "$targetdir/overlay/mount/usr/lib/grub/i386-pc" ]; then
        cp -r $targetdir/overlay/mount/usr/lib/grub/i386-pc $targetdir/iso/boot/grub/  ||errlog "do grub i386-pc failed"
    fi

    cp $script_dir/grub.cfg $targetdir/iso/boot/grub/  ||errlog "do copy grub cfg  failed"
    cp -r $script_dir/pvetheme  $targetdir/iso/boot/grub/  ||errlog "do copy grub pvethem failed"
    touch $targetdir/.grub.lock
fi
cat > $targetdir/iso/EFI/BOOT/grub.cfg << EOF
search --file --set=root /.pxvirt-medium-$pveuuid
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
export_hook_env
isofs
isoinfo
# rpm 标记:grub.cfg 据此显示 openEuler/RPM 的 Live 菜单项
if [ "$FAMILY" == "rpm" ];then
    touch $targetdir/iso/boot/rpm
else
    rm -f $targetdir/iso/boot/rpm
fi
buildroot
create_pkg
overlayfs
copy_squ

build_iso
