# Proxmox-Port Kernel Note
ARM has different processors, and different vendors have different bios.
Therefore, some machines, such as Kunpeng, do not support kernel boot in earlier versions, and we cannot obtain kernel source code from vendors.
Therefore, openeuler 6.6 is used as the primary kernel and openeuler 5.10 is integrated as the secondary kernel.
Of course, we also integrated 6.1's mainline kernel.
If some manufacturers are willing to provide kernels, we may integrate their kernels.
So the Port version of Proxmox VE has multiple kernels,you will need to choose the right kernel for your machine at startup. 

## Kernel List

LoongArch:
	- Linux 6.12.x Lts

Arm64:
        - Linux 6.1.x LTS
        - Linux 5.10.0-openeuler

## Which kernel will be installed ?

All kernel will be installed as .deb file !

## Methods for Booting from the Desired Kernel

1. Install Proxmox VE

   When you enter the startup page, select the corresponding kenrel entry

2. Proxmox VE is installed
 
   - First boot:

	select the kernel entry on grub page

   - Pin kernel

	exec `proxmox-boot-kernel pin `uname -r`` on proxmox host ,This command pin the current kernel as the boot kernel and is not affected by the upgrade.
