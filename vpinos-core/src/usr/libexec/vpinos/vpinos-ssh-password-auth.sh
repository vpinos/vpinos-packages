#!/bin/sh
# Toggles SSH password authentication on the live session, for
# debugging access from a machine that hasn't got this cabinet's SSH
# key set up -- called via `sudo` from vpinos-menu's Testing
# submenu (live CD only; see that script's own is_installed guard,
# same reasoning as "Boot on startup" being installed-only in reverse).
#
# A dedicated drop-in (/etc/ssh/sshd_config.d/*), not hand-editing
# /etc/ssh/sshd_config directly -- sshd reads sshd_config.d/*.conf
# after the main file, so a later file wins, and this stays reversible
# (just remove the drop-in) without needing to find/replace a specific
# commented-out line in a package-managed file. Matches this project's
# existing avoid-hand-editing-package-config preference (see e.g.
# vpinos-gpu-driver.sh's own history).
#
# root-only: writing into /etc/ssh/sshd_config.d/ and restarting
# ssh.service both need root -- see /etc/sudoers.d/vpinos, scoped to
# this one script specifically, same narrow-scope reasoning as every
# other rule there.
set -e

DROPIN=/etc/ssh/sshd_config.d/99-vpinos-live-testing.conf

case "$1" in
    on)
        echo "PasswordAuthentication yes" > "$DROPIN"
        chown root:root "$DROPIN"
        chmod 0644 "$DROPIN"
        ;;
    off)
        rm -f "$DROPIN"
        ;;
    *)
        echo "usage: vpinos-ssh-password-auth.sh on|off" >&2
        exit 1
        ;;
esac

systemctl restart ssh.service
