#!/bin/sh
# Installs vpxtool on demand -- called via `sudo` from vpinos-menu's
# Tools > vpxtool when it isn't installed yet. Not in the ISO and not a
# vpinos-core dependency, same as VPX Editor: it's a table-maintenance
# tool only some cabinet builders want. Unlike VPX Editor it's small
# (~6 MB) and built for both amd64 and arm64. Comes from the VPinOS
# deb-repo (upstream's static release binary, repacked by
# github.com/vpinos/deb-package-builder). Needs internet; on the live
# USB it's lost on reboot, same as any other apt install into the
# overlay.
#
# root-only: apt needs root -- see /etc/sudoers.d/vpinos-core, scoped
# to this one script specifically, same narrow-scope reasoning as every
# other rule there.
#
# Usage: vpinos-vpxtool-setup.sh install|status
set -e

log() {
    echo "$(date -Is): vpinos-vpxtool-setup: $*" >>/var/log/vpinos-menu.log
}

case "$1" in
    status)
        if dpkg-query -W -f='${Status}' vpxtool 2>/dev/null | grep -q 'install ok installed'; then
            echo installed
        else
            echo "not installed"
        fi
        ;;
    install)
        log "install started ($(dpkg --print-architecture))"

        echo "Updating package lists..."
        apt-get update || {
            log "apt-get update failed"
            echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
            exit 1
        }

        echo "Installing vpxtool..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends vpxtool || {
            log "apt-get install failed"
            echo "Install failed -- see the output above."
            exit 1
        }

        log "install finished, vpxtool $(dpkg-query -W -f='${Version}' vpxtool 2>/dev/null)"
        echo "vpxtool installed."
        ;;
    *)
        echo "usage: vpinos-vpxtool-setup.sh install|status" >&2
        exit 1
        ;;
esac
