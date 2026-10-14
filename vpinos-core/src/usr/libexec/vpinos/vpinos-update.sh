#!/bin/sh
# Updates the whole system from its apt sources -- called via `sudo`
# from vpinos-menu's Main > Update VPinOS (installed systems only; on the
# live USB an update is lost on reboot). Never runs on its own; only
# when picked.
#
# Exactly what `sudo apt update && sudo apt upgrade` does, nothing
# excluded: the kernel (exact ABI package name), Mesa/firmware (frozen
# backports snapshot) and the NVIDIA driver (exact-version pin in
# /etc/apt/preferences.d/vpinos-nvidia-repo.pref) are already held where
# the image put them by apt pinning, not by this script.
# --with-new-pkgs is what makes this match `apt upgrade` rather than
# `apt-get upgrade`: an update that adds a new dependency (e.g. a new
# vpinos-core Depends) installs it instead of being held back.
#
# root-only: apt needs root -- see /etc/sudoers.d/vpinos-core, scoped to
# this one script specifically, same narrow-scope reasoning as every
# other rule there.
#
# Usage: vpinos-update.sh
set -e

log() {
    echo "$(date -Is): vpinos-update: $*" >>/var/log/vpinos-menu.log
}

log "update started"
echo "Updating package lists..."
apt-get update || {
    log "apt-get update failed"
    echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
    exit 1
}

# confdef/confold: a conffile question must never stall a kiosk; keep
# the cabinet's own copy.
DEBIAN_FRONTEND=noninteractive apt-get -y --with-new-pkgs \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    upgrade || {
    log "apt-get upgrade failed"
    echo "Update failed -- see the output above."
    exit 1
}

log "update finished, vpinos-core $(dpkg-query -W -f='${Version}' vpinos-core 2>/dev/null)"
echo
echo "Update finished."
if [ -e /run/reboot-required ]; then
    log "reboot required"
    echo "A reboot is needed to finish this update."
fi
