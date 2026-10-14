#!/bin/sh
# VR (WiVRn) controls for vpinos-menu's VR submenu -- everything
# here runs as `vpinos`, no sudo of its own (the one privileged step,
# binding the right GPU driver before the server starts, goes through
# the already-sudo'd vpinos-gpu-driver.sh). Installing the pieces this
# drives is vpinos-vr-setup.sh's job.
#
# The server runs as WiVRn's own systemd user service, NOT through
# vpinos-launch: vpinos-launch runs one client per Hyprland session and stops
# the compositor when it exits, so running wivrn-dashboard there (a
# real report) meant the server died with it and VPX couldn't run at
# the same time. As a user service it outlives any one vpinos-launch run
# and VPX finds it through the OpenXR runtime pointer
# vpinos-vr-setup.sh installs.
#
# Usage: vpinos-vr.sh status|check|start|stop|connect-usb|pair|log|reconcile

# Android package id of the WiVRn headset app -- the one the field
# notes launched successfully over adb.
WIVRN_APP=org.meumeu.wivrn.github
WIVRN_PORT=9757
WIVRN_LOG=/var/log/vpinos-wivrn.log

# VPX only renders in the headset with [PlayerVR] AskToTurnOn = 0
# (0 = enabled, 1 = autodetect, 2 = disabled -- VPX's default is 2).
# Start turns it on; Stop puts back whatever it was before Start,
# saved here ("unset" if the key didn't exist). Only saved when nothing
# is saved yet, so a second Start can't overwrite the original with 0.
VPX_INI="$HOME/.local/share/VPinballX/10.8/VPinballX.ini"
VR_STATE="$HOME/.local/state/vpinos/vr-asktoturnon"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

log() {
    echo "$(date -Is): vpinos-vr: $*" >>/var/log/vpinos-menu.log
}

is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

has_vendor() {
    grep -qx "$1" /sys/class/drm/card[0-9]*/device/vendor 2>/dev/null
}

# Minimal section-aware INI access for VPinballX.ini -- edits only the
# one key line, keeping every comment and every other setting as-is
# (python's configparser would drop the comments). Section and key
# names match case-insensitively.
ini_get() {
    [ -f "$VPX_INI" ] || return 1
    awk -v sec="$1" -v key="$2" '
        function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
        /^[ \t]*\[/ { cur = trim($0); gsub(/^\[|\]$/, "", cur); insec = (tolower(cur) == tolower(sec)); next }
        insec && /^[ \t]*[^;# \t]/ {
            i = index($0, "=")
            if (i && tolower(trim(substr($0, 1, i - 1))) == tolower(key)) { print trim(substr($0, i + 1)); found = 1; exit }
        }
        END { exit !found }
    ' "$VPX_INI"
}

# ini_put <section> <key> <value>, or ini_put <section> <key> to delete
# the key. Adds the key at the end of its section (or the section at the
# end of the file) if it isn't there yet.
ini_put() {
    del=0
    [ $# -lt 3 ] && del=1
    tmp="$VPX_INI.vpinos-tmp"
    awk -v sec="$1" -v key="$2" -v val="$3" -v del="$del" '
        function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
        # Blank lines are held back until the next real line, so a key
        # added at the end of a section lands before its trailing blank
        # line, not after it.
        function out(line) { for (; blanks > 0; blanks--) print ""; print line }
        function add() { if (!done && !del) { print key " = " val; done = 1 } }
        /^[ \t\r]*$/ { blanks++; next }
        /^[ \t]*\[/ {
            if (insec) add()
            cur = trim($0); gsub(/^\[|\]$/, "", cur); insec = (tolower(cur) == tolower(sec))
            out($0); next
        }
        insec && /^[ \t]*[^;# \t]/ {
            i = index($0, "=")
            if (i && tolower(trim(substr($0, 1, i - 1))) == tolower(key)) {
                if (!del) out(key " = " val)
                done = 1; next
            }
        }
        { out($0) }
        END {
            if (insec) add()
            if (!done && !del) { if (NR) { blanks = 1 }; out("[" sec "]"); out(key " = " val) }
            for (; blanks > 0; blanks--) print ""
        }
    ' "$VPX_INI" >"$tmp" 2>/dev/null && mv "$tmp" "$VPX_INI"
}

vpx_vr_enable() {
    if [ ! -f "$VPX_INI" ]; then
        # VPX writes a complete default VPinballX.ini (every setting with
        # its comment) the first time it runs; -h is the quickest run.
        log "no VPinballX.ini yet, generating defaults with -h"
        timeout 30 /opt/vpinball/VPinballX_BGFX -h >/dev/null 2>&1
        if [ ! -f "$VPX_INI" ]; then
            log "VPinballX_BGFX -h didn't create $VPX_INI, creating it with just [PlayerVR]"
            mkdir -p "$(dirname "$VPX_INI")"
            : >"$VPX_INI"
        fi
    fi
    if [ ! -f "$VR_STATE" ]; then
        mkdir -p "$(dirname "$VR_STATE")"
        prev=$(ini_get PlayerVR AskToTurnOn) || prev=unset
        echo "$prev" >"$VR_STATE"
        log "saved [PlayerVR] AskToTurnOn=$prev"
    fi
    ini_put PlayerVR AskToTurnOn 0 && log "set [PlayerVR] AskToTurnOn=0"
}

vpx_vr_restore() {
    [ -f "$VR_STATE" ] || return 0
    prev=$(cat "$VR_STATE")
    if [ "$prev" = unset ]; then
        ini_put PlayerVR AskToTurnOn
    else
        ini_put PlayerVR AskToTurnOn "$prev"
    fi && rm -f "$VR_STATE" && log "restored [PlayerVR] AskToTurnOn=$prev"
}

vpx_vr_state() {
    case "$(ini_get PlayerVR AskToTurnOn)" in
        0) echo on ;;
        1) echo autodetect ;;
        *) echo off ;;
    esac
}

server_state() {
    if systemctl --user is-active --quiet wivrn.service; then
        echo running
    else
        echo stopped
    fi
}

# State of the first adb device: "device" (usable), "unauthorized"
# (USB debugging not yet allowed in the headset), or empty.
adb_state() {
    adb devices 2>/dev/null | awk 'NR > 1 && NF && $1 !~ /^\*/ { print $2; exit }'
}

headset_state() {
    case "$(adb_state)" in
        device) echo connected ;;
        unauthorized) echo "unauthorized (allow USB debugging in the headset)" ;;
        *) echo "not found" ;;
    esac
}

# Best guess at which encoder WiVRn will pick, for the status line --
# WiVRn decides for itself at session start.
encoder_hint() {
    if has_vendor 0x10de && [ "$(cat /etc/vpinos/gpu-driver 2>/dev/null)" = nvidia ] \
        && is_installed libcuda1 && is_installed libnvidia-encode1; then
        echo nvenc
    elif { has_vendor 0x1002 && is_installed mesa-va-drivers; } \
        || { has_vendor 0x8086 && is_installed intel-media-va-driver; }; then
        echo vaapi
    else
        echo "software (x264)"
    fi
}

# Problems that would make an NVIDIA cabinet quietly fall back to
# software encoding instead of NVENC. Prints one line per problem and
# returns 1 if there are any.
check() {
    has_vendor 0x10de || return 0
    [ "$(cat /etc/vpinos/gpu-driver 2>/dev/null)" = nvidia ] || return 0
    rc=0
    if ! is_installed libcuda1 || ! is_installed libnvidia-encode1; then
        echo "NVENC libraries (libcuda1/libnvidia-encode1) aren't installed -- run VR > Setup > Install VR components."
        rc=1
    fi
    if ! lsmod | grep -q '^nvidia_uvm '; then
        echo "nvidia_uvm isn't loaded, so CUDA (NVENC) won't work."
        rc=1
    fi
    return $rc
}

start() {
    vpx_vr_enable
    if [ "$(server_state)" = running ]; then
        echo "VR server already running."
        return 0
    fi
    # Bind the GPU driver the "GPU Driver" option asks for (and, in
    # nvidia mode, nvidia_uvm) BEFORE the server opens the GPU --
    # vpinos-launch would otherwise do it on the next launch, swapping
    # drivers out from under a server that's already running.
    sudo /usr/libexec/vpinos/vpinos-gpu-driver.sh
    # Picks up vpinos-vr-setup.sh's log drop-in on a session that was
    # already running when it got installed.
    systemctl --user daemon-reload
    log "starting wivrn"
    systemctl --user start wivrn.service
    sleep 2
    if [ "$(server_state)" = running ]; then
        echo "VR server started."
    else
        log "wivrn failed to start"
        vpx_vr_restore
        echo "VR server failed to start. Last log lines:"
        tail -n 15 "$WIVRN_LOG" 2>/dev/null
        return 1
    fi
}

stop() {
    log "stopping wivrn"
    systemctl --user stop wivrn.service
    vpx_vr_restore
    echo "VR server stopped."
}

# Same thing the WiVRn dashboard does for a USB-connected headset: a
# reverse tunnel so the headset's 127.0.0.1:9757 reaches this server,
# then open the headset app pointed at it.
connect_usb() {
    case "$(adb_state)" in
        device) ;;
        unauthorized)
            echo "Headset found, but USB debugging isn't allowed yet."
            echo "Put the headset on and accept the \"Allow USB debugging\" prompt."
            return 1
            ;;
        *)
            echo "No headset found over USB. Check the cable, and that"
            echo "Developer Mode is enabled for the headset (Meta Horizon app)."
            return 1
            ;;
    esac
    [ "$(server_state)" = running ] || start || return 1
    log "connecting headset over USB"
    adb reverse tcp:$WIVRN_PORT tcp:$WIVRN_PORT >/dev/null || {
        echo "adb reverse failed."
        return 1
    }
    adb shell am start -a android.intent.action.VIEW \
        -d "wivrn+tcp://127.0.0.1:$WIVRN_PORT" "$WIVRN_APP" >/dev/null || {
        echo "Couldn't start the WiVRn app on the headset -- is it installed?"
        return 1
    }
    echo "WiVRn app started on the headset."
}

# A new headset on Wi-Fi has to be paired once; the PIN it asks for is
# printed in the server's log (already-paired headsets live in
# ~/.config/wivrn/known_keys.json).
pair() {
    [ "$(server_state)" = running ] || start || return 1
    log "enabling pairing"
    wivrnctl enable-pairing
    sleep 2
    echo
    echo "Connect from the headset now. Recent PIN lines from the server log:"
    grep -i 'pin' "$WIVRN_LOG" 2>/dev/null | tail -n 3
}

case "$1" in
    status)
        echo "Server: $(server_state)   Headset (USB): $(headset_state)"
        echo "Encoder: $(encoder_hint)   VPX VR: $(vpx_vr_state)"
        ;;
    # The server also stops without Stop (reboot, crash) -- put VPX's
    # setting back then too, so a cabinet with no VR server running
    # isn't left trying VR on every table. Run by vpinos-menu at startup.
    reconcile)
        [ "$(server_state)" = running ] || vpx_vr_restore
        ;;
    check) check ;;
    start) start ;;
    stop) stop ;;
    connect-usb) connect_usb ;;
    pair) pair ;;
    log)
        echo "Press Ctrl+C to stop."
        tail -n 40 -f "$WIVRN_LOG"
        ;;
    *)
        echo "usage: vpinos-vr.sh status|check|start|stop|connect-usb|pair|log|reconcile" >&2
        exit 1
        ;;
esac
