#!/bin/sh
# Installs VPX Editor on demand -- called via `sudo` from vpinos-menu's
# Tools > VPX Editor when it isn't installed yet. Not in the ISO and not
# a vpinos-core dependency: it's ~530 MB to download (~900 MB
# installed), only some cabinet builders want a table editor on the
# cabinet itself, and upstream only builds it for amd64 (vpinos-core is
# Architecture: all, so a hard Depends would be unsatisfiable on arm64).
# Comes from the VPinOS deb-repo (upstream's own .deb, republished as-is
# by github.com/vpinos/deb-package-builder). Needs internet; on the live
# USB it's lost on reboot, same as any other apt install into the
# overlay.
#
# root-only: apt needs root -- see /etc/sudoers.d/vpinos-core, scoped
# to this one script specifically, same narrow-scope reasoning as every
# other rule there.
#
# Usage: vpinos-vpx-editor-setup.sh install|status
set -e

log() {
    echo "$(date -Is): vpinos-vpx-editor-setup: $*" >>/var/log/vpinos-menu.log
}

case "$1" in
    status)
        if dpkg-query -W -f='${Status}' vpx-editor 2>/dev/null | grep -q 'install ok installed'; then
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
            echo "VPX Editor is only available for amd64, not $arch."
            exit 1
        fi

        echo "Updating package lists..."
        apt-get update || {
            log "apt-get update failed"
            echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
            exit 1
        }

        echo "Installing VPX Editor (~530 MB download)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends vpx-editor || {
            log "apt-get install failed"
            echo "Install failed -- see the output above."
            exit 1
        }

        log "install finished, vpx-editor $(dpkg-query -W -f='${Version}' vpx-editor 2>/dev/null)"
        echo "VPX Editor installed."
        ;;
    *)
        echo "usage: vpinos-vpx-editor-setup.sh install|status" >&2
        exit 1
        ;;
esac
