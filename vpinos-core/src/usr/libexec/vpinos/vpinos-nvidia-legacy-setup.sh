#!/bin/sh
# NVIDIA's legacy 580 driver for Maxwell, Pascal and Volta cards (GTX 900
# and 10 series, Titan V) -- installed on demand from vpinos-menu's
# Setup > NVIDIA Legacy Driver, called via `sudo`. The image's own NVIDIA
# driver (615, open kernel module) only supports Turing and newer: it
# refuses these cards at probe ("not supported by open nvidia.ko ... GPU
# System Processor"), and 590+ dropped them from the closed module too.
# 580 is NVIDIA's last branch for them.
#
# vpinos-nvidia-legacy-<kernel> (built by vpinos-packages' build-platform.sh)
# holds the closed 580 modules for exactly the VPinOS kernel, with a
# depmod.d override so `modprobe nvidia` picks them over the 615 ones,
# and the matching 580 userspace in its own directory
# (/usr/lib/vpinos-nvidia-legacy), which vpinos-launch selects when the
# loaded nvidia module is that version. Nothing of the 615 packages is
# replaced, so vpinos-kernel's exact-version Depends stay satisfied.
#
# Not in the ISO: ~200 MB that only these cards need. Needs internet; on
# the live USB it's lost on reboot, same as any other apt install into
# the overlay.
#
# root-only for install: apt needs root -- see /etc/sudoers.d/vpinos-core,
# scoped to this one script, same as the other on-demand installers.
#
# Usage: vpinos-nvidia-legacy-setup.sh status|needed|install
#   needed: "legacy" (Maxwell/Pascal/Volta), "unsupported" (Kepler and
#   older NVIDIA), or "no" (Turing+ or no NVIDIA GPU).
set -e

pkg="vpinos-nvidia-legacy-$(uname -r)"

log() {
    echo "$(date -Is): vpinos-nvidia-legacy-setup: $*" >>/var/log/vpinos-menu.log
}

# By PCI device ID of the first NVIDIA display controller: 0x1340 is the
# first Maxwell (GM108), 0x1e00 the first Turing (TU102); everything in
# between is Maxwell, Pascal or Volta. Below 0x1340 is Kepler and older,
# which 580 doesn't support either (470 was their last branch).
generation() {
    for dev in /sys/bus/pci/devices/*; do
        [ "$(cat "$dev/vendor" 2>/dev/null)" = 0x10de ] || continue
        case "$(cat "$dev/class" 2>/dev/null)" in 0x03*) ;; *) continue ;; esac
        id=$(($(cat "$dev/device")))
        if [ "$id" -ge $((0x1e00)) ]; then
            echo no
        elif [ "$id" -ge $((0x1340)) ]; then
            echo legacy
        else
            echo unsupported
        fi
        return
    done
    echo no
}

case "$1" in
    status)
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            echo installed
        else
            echo "not installed"
        fi
        ;;
    needed)
        generation
        ;;
    install)
        log "install started ($pkg)"
        if [ "$(dpkg --print-architecture)" != amd64 ]; then
            echo "The NVIDIA legacy driver is only available for amd64."
            exit 1
        fi
        if [ "$(generation)" != legacy ]; then
            log "not needed: GPU generation $(generation)"
            echo "This GPU doesn't need the legacy driver."
            exit 1
        fi

        echo "Updating package lists..."
        apt-get update || {
            log "apt-get update failed"
            echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
            exit 1
        }

        echo "Installing $pkg..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" || {
            log "apt-get install failed"
            echo "Install failed -- see the output above."
            exit 1
        }

        log "install finished, $pkg $(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
        echo "NVIDIA legacy driver installed."
        ;;
    *)
        echo "usage: vpinos-nvidia-legacy-setup.sh status|needed|install" >&2
        exit 1
        ;;
esac
