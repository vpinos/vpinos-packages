#!/bin/sh
# Installs VR (WiVRn) support on demand -- called via `sudo` from
# vpinos-menu's VR > Setup submenu. None of this is in the ISO:
# WiVRn, adb and the encoder libraries only matter to the few cabinets
# with a headset, so they're pulled at runtime instead of growing the
# image for everyone (needs internet; on the live USB it's lost on
# reboot, same as any other apt install into the overlay). See
# notes/vr-support.md for where each piece comes from and why.
#
# root-only: apt and /etc/xdg both need root -- see /etc/sudoers.d/vpinos,
# scoped to this one script specifically, same narrow-scope reasoning
# as every other rule there.
#
# Usage: vpinos-vr-setup.sh install|status
set -e

log() {
    echo "$(date -Is): vpinos-vr-setup: $*" >>/var/log/vpinos-menu.log
}

is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Every distinct GPU vendor present, same sysfs detection as vpinos-launch.
gpu_vendors() {
    for card in /sys/class/drm/card[0-9]*; do
        [ -e "$card/device/vendor" ] && cat "$card/device/vendor" 2>/dev/null
    done | sort -u
}

# The NVIDIA driver version baked into this image by
# 0120-install-nvidia-driver.hook.chroot -- read from what's installed,
# never hardcoded, so it follows the image when the driver changes.
# libcuda1/libnvidia-encode1 must be this exact version or NVENC fails;
# a bare `apt-get install libcuda1` would take NVIDIA's newest instead
# (drifts ahead of the image) or Debian's 550 build (libcuda1 isn't
# covered by vpinos-nvidia-repo.pref's libnvidia-* pin). That hook
# purges the nvidia-driver metapackage itself, so this reads core driver
# libraries it leaves installed instead -- not a libnvidia-* wildcard,
# which also matches libnvidia-egl-wayland1/-egl-gbm1/... (separate
# source packages with their own unrelated version numbers). Prints
# every distinct version found, so the caller can refuse a mismatch.
nvidia_driver_version() {
    for pkg in libnvidia-glcore libnvidia-eglcore nvidia-kernel-support; do
        dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' "$pkg" 2>/dev/null
    done | awk '$1 == "ii" { print $2 }' | sort -u
}

case "$1" in
    status)
        if is_installed wivrn && is_installed adb; then
            echo installed
        else
            echo "not installed"
        fi
        ;;
    install)
        arch=$(dpkg --print-architecture)
        log "install started ($arch)"

        echo "Updating package lists..."
        apt-get update || {
            log "apt-get update failed"
            echo "apt-get update failed -- is the network up? (Setup > Network Settings)"
            exit 1
        }

        # WiVRn: VPinOS deb-repo (republished as-is from its upstream
        # release by github.com/vpinos/deb-package-builder). adb: plain
        # Debian. android-sdk-platform-tools-common: adb's udev rules --
        # without them a non-root `vpinos` can't open the headset's USB
        # device (it's already in plugdev, which those rules grant).
        # avahi-daemon: WiVRn announces itself over mDNS so a headset on
        # Wi-Fi can find it; not otherwise in the image, and listed
        # explicitly rather than relying on recommends.
        # xrizer: OpenVR-on-OpenXR, for SteamVR-API apps (VPX itself
        # speaks OpenXR and doesn't need it). VPinOS deb-repo, installs
        # to /opt/xrizer, which is on WiVRn's default
        # OVR_COMPAT_SEARCH_PATH -- WiVRn finds it and writes
        # openvrpaths.vrpath itself, so nothing to configure here. Also
        # silences the dashboard's "OpenComposite or xrizer is not
        # installed" warning.
        pkgs="wivrn xrizer adb android-sdk-platform-tools-common avahi-daemon"
        # Hardware video encoders WiVRn can use instead of software x264.
        for vendor in $(gpu_vendors); do
            case "$vendor" in
                0x10de)
                    [ "$arch" = amd64 ] || continue
                    ver=$(nvidia_driver_version)
                    if [ -z "$ver" ]; then
                        log "no NVIDIA driver libraries installed, skipping NVENC"
                        echo "NVIDIA driver libraries not found -- skipping NVENC support."
                    elif [ "$(echo "$ver" | wc -l)" -ne 1 ]; then
                        log "mixed NVIDIA library versions ($(echo "$ver" | tr '\n' ' ')), skipping NVENC"
                        echo "Installed NVIDIA libraries have mixed versions -- skipping NVENC support."
                    else
                        log "NVIDIA driver version $ver"
                        pkgs="$pkgs libcuda1=$ver libnvidia-encode1=$ver"
                    fi
                    ;;
                0x1002)
                    pkgs="$pkgs mesa-va-drivers"
                    ;;
                0x8086)
                    [ "$arch" = amd64 ] && pkgs="$pkgs intel-media-va-driver"
                    ;;
            esac
        done

        echo "Installing: $pkgs"
        log "installing: $pkgs"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs || {
            log "apt-get install failed"
            echo "Install failed -- see the output above."
            exit 1
        }

        # Permanent system-wide OpenXR runtime pointer. wivrn-server only
        # writes ~/.config/openxr/1/active_runtime.json while a headset
        # session is active and deletes it afterwards, so VPX started at
        # any other time found no runtime and quietly played on the
        # desktop instead (a real report). Lives here, not in the deb,
        # because the deb is upstream's own package, republished
        # unchanged.
        mkdir -p /etc/xdg/openxr/1
        ln -sf /usr/share/openxr/1/openxr_wivrn.json /etc/xdg/openxr/1/active_runtime.json

        # The server is started/stopped from the VR menu only -- it ties
        # up the GPU encoder and listens on the network, so it shouldn't
        # run on every cabinet boot just because WiVRn is installed.
        systemctl --global disable wivrn.service 2>/dev/null || true

        # Send the server's output to a plain log file vpinos can always
        # read (VR > Show server log, and the pairing PIN), rather than
        # depending on whether the user journal is readable on this
        # system's journald setup.
        mkdir -p /etc/systemd/user/wivrn.service.d
        cat >/etc/systemd/user/wivrn.service.d/vpinos-log.conf <<'EOF'
[Service]
StandardOutput=append:/var/log/vpinos-wivrn.log
StandardError=append:/var/log/vpinos-wivrn.log
EOF
        touch /var/log/vpinos-wivrn.log
        chown vpinos:vpinos /var/log/vpinos-wivrn.log

        # Apply the new adb udev rules to a headset that's already
        # plugged in, instead of needing a replug.
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=usb 2>/dev/null || true

        log "install finished, wivrn $(dpkg-query -W -f='${Version}' wivrn 2>/dev/null)"
        echo "VR components installed."
        ;;
    *)
        echo "usage: vpinos-vr-setup.sh install|status" >&2
        exit 1
        ;;
esac
