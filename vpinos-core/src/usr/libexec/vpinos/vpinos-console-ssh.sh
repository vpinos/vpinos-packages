#!/bin/sh
# Stops or starts kmscon on tty1 (kmsconvt@tty1.service) around a
# vpinos-launch run started over SSH. kmscon holds DRM master while it
# runs, and kmscon-launch-gui (which makes it step back for launches
# from the console) only works from kmscon's own terminal, so from SSH
# the console has to be stopped for Hyprland to get the display. See
# the SSH block near the top of /usr/bin/vpinos-launch.
#
# "stop" waits until kmscon has exited, so the display is free when
# this returns. It ends the cabinet's tty1 session (the menu, or
# whatever it was running). "start" brings the console back, and
# autologin brings the menu back with it.
#
# Runs as root via `sudo` from vpinos-launch. Takes only "stop" or
# "start", and the sudoers rules for it (see /etc/sudoers.d/vpinos-core)
# allow exactly those two, so it can only ever stop or start this one
# unit.
set -e

unit=kmsconvt@tty1.service

case "$1" in
    stop)
        exec systemctl stop "$unit"
        ;;
    start)
        exec systemctl start "$unit"
        ;;
    *)
        echo "usage: vpinos-console-ssh.sh stop|start" >&2
        exit 2
        ;;
esac
