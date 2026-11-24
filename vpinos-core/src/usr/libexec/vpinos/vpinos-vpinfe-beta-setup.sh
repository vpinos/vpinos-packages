#!/bin/sh
# Joins or leaves the VPinFE beta -- called via `sudo` from vpinos-menu's
# Setup > VPinFE 3.0 Beta. VPinFE betas are published to the apt repo's
# beta channel (the apt-beta release of github.com/vpinos/deb-repo, signed
# with the same key as the stable channel), which only a cabinet that
# joined has as a source. A beta's version (3.0.0~beta.4-1) is higher than
# any 2.x and lower than 3.0.0, so once joined, Update VPinOS keeps the
# cabinet on the newest beta, and moves it to 3.0.0 when that's released.
# Same package and same settings folder as the stable VPinFE: VPinFE 3.0
# converts ~/.config/vpinfe/vpinfe.ini to vpinfe.json on its first start
# and keeps the ini, so leaving goes back to 2.x with the settings from
# before the beta. Needs internet; on the live USB it's lost on reboot,
# same as any other apt install into the overlay.
#
# root-only: apt needs root -- see /etc/sudoers.d/vpinos-core, scoped to
# this one script specifically, same narrow-scope reasoning as every
# other rule there.
#
# Usage: vpinos-vpinfe-beta-setup.sh join|leave|status
set -e

SOURCE=/etc/apt/sources.list.d/vpinos-beta.list

log() {
    echo "$(date -Is): vpinos-vpinfe-beta-setup: $*" >>/var/log/vpinos-menu.log
}

vpinfe_version() {
    dpkg-query -W -f='${Version}' vpinfe 2>/dev/null || true
}

case "$1" in
    status)
        if [ -e "$SOURCE" ]; then
            echo joined
        else
            echo off
        fi
        ;;
    join)
        log "join started ($(dpkg --print-architecture), vpinfe $(vpinfe_version))"
        cat >"$SOURCE" <<'EOF'
# VPinOS beta channel -- written by Setup > VPinFE 3.0 Beta (Join), removed
# by Leave. Only beta builds are here; everything else still comes from
# vpinos.list. Same signing key.
deb [signed-by=/etc/apt/keyrings/vpinos.asc] https://github.com/vpinos/deb-repo/releases/download/apt-beta ./
EOF

        echo "Updating package lists..."
        if ! apt-get update; then
            rm -f "$SOURCE"
            log "apt-get update failed"
            echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
            exit 1
        fi

        candidate=$(apt-cache policy vpinfe | awk '/Candidate:/ { print $2 }')
        case "$candidate" in
            *~*) ;;
            *)
                rm -f "$SOURCE"
                apt-get update >/dev/null 2>&1 || true
                log "no beta published (candidate ${candidate:-none})"
                echo "No VPinFE beta is published right now. Nothing was changed."
                exit 1
                ;;
        esac

        echo "Installing VPinFE $candidate..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends vpinfe || {
            log "apt-get install failed"
            echo "Install failed -- see the output above. Still joined: Update VPinOS"
            echo "tries again, or Leave goes back to VPinFE 2.x."
            exit 1
        }

        log "join finished, vpinfe $(vpinfe_version)"
        echo
        echo "VPinFE $(vpinfe_version) installed."
        echo
        echo "Next:"
        echo " 1. Start VPinFE once. It converts your settings to 3.0 and downloads"
        echo "    the 3.0 version of the Revolution theme (needs internet)."
        echo " 2. With more than one screen, open Setup > VPinOS Configuration and"
        echo "    Save, so VPinFE's windows go to the right screens."
        echo
        echo "Update VPinOS keeps you on the newest beta. Setup > VPinFE 3.0 Beta >"
        echo "Leave goes back to VPinFE 2.x."
        ;;
    leave)
        log "leave started (vpinfe $(vpinfe_version))"
        rm -f "$SOURCE"

        echo "Updating package lists..."
        if ! apt-get update; then
            log "apt-get update failed"
            echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
            echo "The beta source is already removed: run Leave again once the network is up."
            exit 1
        fi

        # The newest version the remaining (stable) sources offer. Lower
        # than the installed beta, so it takes an explicit version and
        # --allow-downgrades.
        stable=$(apt-cache madison vpinfe | awk -F'|' '{ gsub(/ /, "", $2); print $2; exit }')
        if [ -z "$stable" ]; then
            log "no stable vpinfe found"
            echo "No stable VPinFE found in the package lists."
            exit 1
        fi
        if [ "$(vpinfe_version)" = "$stable" ]; then
            log "leave finished, already on vpinfe $stable"
            echo "Left the beta. VPinFE $stable is already installed."
            exit 0
        fi

        echo "Installing VPinFE $stable..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --allow-downgrades "vpinfe=$stable" || {
            log "apt-get install failed"
            echo "Install failed -- see the output above. The beta source is removed:"
            echo "run Leave again to retry."
            exit 1
        }

        log "leave finished, vpinfe $(vpinfe_version)"
        echo
        echo "Left the beta. VPinFE $(vpinfe_version) is back, with your settings from"
        echo "before the beta. Changes made in the beta stay with the beta's settings"
        echo "file, ready if you join again."
        ;;
    *)
        echo "usage: vpinos-vpinfe-beta-setup.sh join|leave|status" >&2
        exit 1
        ;;
esac
