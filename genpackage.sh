#!/bin/bash
pveversion -v|grep -v kernel|grep -v "ifupdown:"|sed "s/://g"|awk '{print $1"="$2}' >proxmox/pve-packages.list
echo > proxmox/pve-packages.list.line
for i in `cat proxmox/pve-packages.list`;
do
	echo -n $i" " >>proxmox/pve-packages.list.line;
done
