#!/bin/sh
# Restarts kmscon on tty1 (kmsconvt@tty1.service), so a new Console
# Rotation or GPU Driver choice takes effect without a reboot: kmscon
# reads its rotation only at startup (see vpinos-kmscon), and the GPU
# driver switch runs just before it starts, while nothing holds the GPU
# open (the unit's vpinos.conf drop-in).
#
# Ends the session it's called from -- vpinos-menu's -- and autologin
# brings the menu straight back. --no-block, so this returns before
# the stop reaches the caller.
#
# Runs as root via `sudo` from vpinos-menu. Takes no arguments on
# purpose, so the sudoers rule for it (see /etc/sudoers.d/vpinos-core)
# can only ever restart this one unit. Does nothing on the getty@tty1
# fallback (fbcon), where kmscon isn't running.
set -e

systemctl is-active --quiet kmsconvt@tty1.service || exit 0
exec systemctl restart --no-block kmsconvt@tty1.service
