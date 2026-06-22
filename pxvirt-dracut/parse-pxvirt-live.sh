#!/bin/sh
# cmdline-phase hook: when booted from the PXVIRT ISO (rd.pxvirt.live=1), tell
# dracut that root is handled by us, so it won't block waiting on a root= device.

if getargbool 0 rd.pxvirt.live; then
    info "pxvirt-live: claiming root handling"
    # marks root as resolvable so dracut proceeds to the mount phase
    rootok=1
    [ -z "$root" ] && root="pxvirt-live"
fi
