#!/bin/sh
# Installs the SSF Speaker Test table on demand -- called via `sudo` from
# vpinos-menu's Testing > SSF Speaker Test when it isn't installed yet.
# Not in the ISO and not a vpinos-core dependency, same as VPX Editor:
# it's only useful on a cabinet with a 7.1 Surround Sound Feedback (SSF)
# speaker setup. The vpx-ssf-test-table package (Architecture: all, so
# amd64 and arm64) comes from the VPinOS deb-repo: the table folder of
# github.com/superhac/vpx-ssf-test-table's release, repacked by
# github.com/vpinos/deb-package-builder into
# /usr/share/vpx-ssf-test-table/SSF_Speaker_Test/. Needs internet; on the
# live USB it's lost on reboot, same as any other apt install into the
# overlay.
#
# root-only: apt needs root -- see /etc/sudoers.d/vpinos-core, scoped
# to this one script specifically, same narrow-scope reasoning as every
# other rule there.
#
# Usage: vpinos-ssf-test-table-setup.sh install|status
set -e

log() {
    echo "$(date -Is): vpinos-ssf-test-table-setup: $*" >>/var/log/vpinos-menu.log
}

case "$1" in
    status)
        if dpkg-query -W -f='${Status}' vpx-ssf-test-table 2>/dev/null | grep -q 'install ok installed'; then
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

        echo "Installing the SSF Speaker Test table (~9 MB download)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends vpx-ssf-test-table || {
            log "apt-get install failed"
            echo "Install failed -- see the output above."
            exit 1
        }

        log "install finished, vpx-ssf-test-table $(dpkg-query -W -f='${Version}' vpx-ssf-test-table 2>/dev/null)"
        echo "SSF Speaker Test table installed."
        ;;
    *)
        echo "usage: vpinos-ssf-test-table-setup.sh install|status" >&2
        exit 1
        ;;
esac
