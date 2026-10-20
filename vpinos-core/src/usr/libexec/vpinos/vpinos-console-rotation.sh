#!/bin/sh
# Rotates the Linux text console (fbcon -- where vpinos-menu runs) per
# /etc/vpinos/console-rotation, for a cabinet whose Table screen is
# mounted in portrait. Hyprland's own rotation (vpinos-config's Table
# Screen Rotation) can't reach the console: the console isn't a Wayland
# client, so it has its own separate setting, chosen in vpinos-menu's
# Setup > Console Rotation.
#
# Value is fbcon's own numbering (kernel Documentation/fb/fbcon.rst),
# which runs the OPPOSITE way to Hyprland's `transform`:
#   0 = normal, 1 = 90° clockwise (right), 3 = 90° counter-clockwise (left)
# 2 (upside down) is valid for fbcon but not offered -- not portrait.
#
# Runs as root: at boot from vpinos-console-rotation.service (sysfs
# isn't persistent, so it has to be re-applied every boot), via `sudo`
# from vpinos-menu right after the setting changes, and from
# vpinos-gpu-driver.sh after a driver switch (a freshly loaded driver
# registers a new framebuffer, which starts unrotated). Takes no
# arguments on purpose -- the sudoers rule for it (see
# /etc/sudoers.d/vpinos-core) can't then be used to write anything but
# a validated value from the setting file.
SETTING=/etc/vpinos/console-rotation
SYSFS=/sys/class/graphics/fbcon/rotate_all

value=$(cat "$SETTING" 2>/dev/null || true)
[ -z "$value" ] && exit 0
case "$value" in
    0|1|3) ;;
    *)
        echo "$(date -Is): vpinos-console-rotation: ignoring invalid value '$value' in $SETTING" >>/var/log/vpinos-menu.log
        exit 0
        ;;
esac

# No fbcon at all (e.g. a GPU driver with no fbdev console) -- nothing
# to rotate, and not an error.
[ -e "$SYSFS" ] || exit 0

if ! echo "$value" > "$SYSFS" 2>/dev/null; then
    echo "$(date -Is): vpinos-console-rotation: couldn't write $value to $SYSFS" >>/var/log/vpinos-menu.log
fi
exit 0
