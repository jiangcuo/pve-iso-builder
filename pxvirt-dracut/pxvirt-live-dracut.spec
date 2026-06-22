Name:           pxvirt-live-dracut
Version:        1.0.0
Release:        1%{?dist}
Summary:        PXVIRT live-installer dracut module

License:        AGPL-3.0
URL:            https://www.lierfang.com
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       dracut
Requires:       util-linux
Requires:       squashfs-tools

%description
Dracut module that boots the PXVIRT installer ISO: it locates the install
medium (optical, USB written via dd/UltraISO/Rufus, or an embedded ISO for
PXE/HTTP boot), stacks the base and installer squashfs as an overlay, and
hands control to the installer. Build the live initramfs with:

    dracut --add pxvirt-live ...

%global moddir %{_prefix}/lib/dracut/modules.d/90pxvirt-live

%prep
%setup -q -n 90pxvirt-live

%build
# nothing to build (shell scripts only)

%install
install -d %{buildroot}%{moddir}
install -m 0755 module-setup.sh        %{buildroot}%{moddir}/module-setup.sh
install -m 0755 parse-pxvirt-live.sh   %{buildroot}%{moddir}/parse-pxvirt-live.sh
install -m 0755 pxvirt-live-mount.sh   %{buildroot}%{moddir}/pxvirt-live-mount.sh

%files
%dir %{moddir}
%{moddir}/module-setup.sh
%{moddir}/parse-pxvirt-live.sh
%{moddir}/pxvirt-live-mount.sh

%changelog
* Wed Jun 18 2026 Lierfang <itsupport@lierfang.com> - 1.0.0-1
- Initial packaging of the pxvirt-live dracut module
