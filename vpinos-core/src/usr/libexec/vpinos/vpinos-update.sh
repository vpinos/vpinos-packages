#!/bin/sh
# Updates the whole system from its apt sources -- called via `sudo`
# from vpinos-menu's Main > Update VPinOS (installed systems only; on the
# live USB an update is lost on reboot). Never runs on its own; only
# when picked.
#
# Exactly what `sudo apt update && sudo apt upgrade` does (twice, see
# below), nothing excluded: the kernel (exact ABI package name), Mesa/firmware (frozen
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

# Two rounds. apt picks versions using the pins already on this cabinet,
# so a kernel or NVIDIA driver release lands in two steps: round 1
# upgrades vpinos-platform, whose postinst rewrites the apt pins (and the
# backports snapshot source); round 2 re-reads the package lists under
# those new pins and upgrades vpinos-kernel (kernel + NVIDIA modules +
# NVIDIA userspace) together. When there's no such release, round 2
# simply finds nothing to do.
for round in 1 2; do
    echo "Updating package lists..."
    apt-get update || {
        log "apt-get update failed (round $round)"
        echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
        exit 1
    }

    # confdef/confold: a conffile question must never stall a kiosk;
    # keep the cabinet's own copy. --allow-downgrades: only VPinOS's own
    # priority-1001 pins (vpinos-platform) can make an older version the
    # candidate, and that is a deliberate rollback, e.g. back to an
    # earlier NVIDIA driver.
    DEBIAN_FRONTEND=noninteractive apt-get -y --with-new-pkgs --allow-downgrades \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        upgrade || {
        log "apt-get upgrade failed (round $round)"
        echo "Update failed -- see the output above."
        exit 1
    }
done

log "update finished, vpinos-core $(dpkg-query -W -f='${Version}' vpinos-core 2>/dev/null)"
echo
echo "Update finished."
if [ -e /run/reboot-required ]; then
    log "reboot required"
    echo "A reboot is needed to finish this update."
fi
