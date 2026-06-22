## How to use

构建脚本支持两种软件包族,**按构建主机自动判定**(检测有无 `apt`):
- 有 `apt`(Debian 主机):走 debootstrap + apt。
- 无 `apt`(openEuler 主机):走 dnf。

### Debian 版(FAMILY=deb)

#### clean and build

```
apt install debootstrap squashfs-tools  xorriso -y
bash build.sh clean 
```

####  build without clean
```
bash build.sh
```

### openEuler / RPM 版(FAMILY=rpm)

在 openEuler 主机上构建(脚本检测到无 `apt` 即走 dnf)。先在 `.cd-info` 配好
`oeversion`/`oemirrors`/`pxvmirrors`。pxvirt 产品源带鉴权,**用户名/密码通过环境变量传入,
不写进文件**:

```
dnf install -y dnf squashfs-tools xorriso grub2-tools
export PXVIRT_REPO_USER='你的用户名'
export PXVIRT_REPO_PASS='你的密码'
bash build.sh clean
```

> Live initramfs 由构建脚本**手动**把 `pxvirt-dracut/` 模块装进 dracut 模块目录后
> `dracut --add pxvirt-live` 生成(不打 rpm 包)。脚本在 ISO 上放 `boot/rpm` 标记文件,
> grub.cfg 据此把安装项内核参数切成 `rd.pxvirt.live=1`。

## install other package

edit build.sh

```
extra_pkg="ceph-common ceph-fuse iperf3 net-sriov-tools your_pkg"  #if you want install other package
```

add ceph

edit .cd-info

```
RELEASE='8.3'
ISORELEASE='3'
ISONAME='pxvirt'
PRODUCT='pxvirt'
PRODUCTLONG='pxvirt'
main_kernel="pve-kernel-6.6-openeuler"
extra_kernel=""
mirrors="https://mirrors.ustc.edu.cn" #debian mirror
pvemirrors="https://mirrors.ustc.edu.cn/proxmox/debian" #pve mirrors.
portmirrors="https://download.lierfang.com/pxcloud" #port mirrors
ceph="reef" # [  cephversion reef| squid | quincy ] see https://docs.pxvirt.lierfang.com/zh/repo.html
```
