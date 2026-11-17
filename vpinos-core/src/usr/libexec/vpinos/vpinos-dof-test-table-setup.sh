#!/bin/sh
# Installs the DOF Test table on demand -- called via `sudo` from
# vpinos-menu's Testing > DOF Test when it isn't installed yet. Not in
# the ISO and not a vpinos-core dependency, same as VPX Editor: it's only
# useful on a cabinet with DirectOutput Framework (DOF) toys. The
# vpx-dof-test-table package (Architecture: all, so amd64 and arm64)
# comes from the VPinOS deb-repo: the table folder of
# github.com/superhac/vpx-dof-test-table's release, repacked by
# github.com/vpinos/deb-package-builder into
# /usr/share/vpx-dof-test-table/DOF_test/. Needs internet; on the
# live USB it's lost on reboot, same as any other apt install into the
# overlay.
#
# root-only: apt needs root -- see /etc/sudoers.d/vpinos-core, scoped
# to this one script specifically, same narrow-scope reasoning as every
# other rule there.
#
# Usage: vpinos-dof-test-table-setup.sh install|status
set -e

log() {
    echo "$(date -Is): vpinos-dof-test-table-setup: $*" >>/var/log/vpinos-menu.log
}

case "$1" in
    status)
        if dpkg-query -W -f='${Status}' vpx-dof-test-table 2>/dev/null | grep -q 'install ok installed'; then
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

        echo "Installing the DOF Test table (~8 MB download)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends vpx-dof-test-table || {
            log "apt-get install failed"
            echo "Install failed -- see the output above."
            exit 1
        }

        log "install finished, vpx-dof-test-table $(dpkg-query -W -f='${Version}' vpx-dof-test-table 2>/dev/null)"
        echo "DOF Test table installed."
        ;;
    *)
        echo "usage: vpinos-dof-test-table-setup.sh install|status" >&2
        exit 1
        ;;
esac
