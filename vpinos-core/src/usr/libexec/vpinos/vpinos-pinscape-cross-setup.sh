#!/bin/sh
# Installs Pinscape-Cross on demand -- called via `sudo` from vpinos-menu's
# Tools > Pinscape-Cross when it isn't installed yet. Not in the ISO and
# not a vpinos-core dependency, same as VPX Editor: it's the configuration
# and firmware tool for a Pinscape Pico controller board, which only some
# cabinets have, and upstream only builds a .deb for amd64 (vpinos-core is
# Architecture: all, so a hard Depends would be unsatisfiable on arm64).
# Comes from the VPinOS deb-repo (upstream's own .deb, republished as-is
# by github.com/vpinos/deb-package-builder). Its WebKitGTK/GTK 3
# dependencies aren't in the image either, so the first install pulls
# those from Debian too. The package's udev rule opens the Pico's USB
# interfaces to non-root users, so nothing else needs setting up. Needs
# internet; on the live USB it's lost on reboot, same as any other apt
# install into the overlay.
#
# root-only: apt needs root -- see /etc/sudoers.d/vpinos-core, scoped
# to this one script specifically, same narrow-scope reasoning as every
# other rule there.
#
# Usage: vpinos-pinscape-cross-setup.sh install|status
set -e

log() {
    echo "$(date -Is): vpinos-pinscape-cross-setup: $*" >>/var/log/vpinos-menu.log
}

case "$1" in
    status)
        if dpkg-query -W -f='${Status}' pinscape-cross 2>/dev/null | grep -q 'install ok installed'; then
            echo installed
        else
            echo "not installed"
        fi
        ;;
    install)
        arch=$(dpkg --print-architecture)
        log "install started ($arch)"
        if [ "$arch" != amd64 ]; then
            log "not available for $arch"
            echo "Pinscape-Cross is only available for amd64, not $arch."
            exit 1
        fi

        echo "Updating package lists..."
        apt-get update || {
            log "apt-get update failed"
            echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
            exit 1
        }

        echo "Installing Pinscape-Cross..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends pinscape-cross || {
            log "apt-get install failed"
            echo "Install failed -- see the output above."
            exit 1
        }

        log "install finished, pinscape-cross $(dpkg-query -W -f='${Version}' pinscape-cross 2>/dev/null)"
        echo "Pinscape-Cross installed."
        ;;
    *)
        echo "usage: vpinos-pinscape-cross-setup.sh install|status" >&2
        exit 1
        ;;
esac
