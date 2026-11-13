#!/bin/sh
# Switches which GPU kernel module is bound to the card, based on
# /etc/vpinos/gpu-driver -- called via `sudo` from vpinos-launch, on every
# single invocation (cheap/idempotent if nothing needs to change), right
# before it execs Hyprland. That's the one point every client type
# (vpinball/vpinfe/Chrome/installer/vpxconfig/gamepadtest) already goes
# through, live or installed, and nothing graphical has started yet at
# that point in any of them -- so nothing holds either driver's DRM
# device open, and this never needs a reboot to take effect, unlike the
# "Boot on startup" mode switch (see vpinos-menu's "GPU Driver"
# option and notes/vpinos.md step 5 for the full reasoning).
#
# root-only: modprobe needs CAP_SYS_MODULE, which `vpinos` doesn't have
# and shouldn't -- see /etc/sudoers.d/vpinos, scoped to this one script
# specifically, same narrow-scope reasoning as every other rule there.
set -e

# Releases the kernel's own framebuffer console from whichever DRM
# driver currently owns it -- required before that driver's kernel
# module can actually be removed. Confirmed directly as the real root
# cause of a driver-switch failure on real NVIDIA hardware (a GTX 1650):
# `modprobe -r nouveau` below looked harmless (failures silently
# discarded by `|| true`) but was actually failing every time, visible
# directly in `dmesg` as "GPU ... is already bound to nouveau" / "No
# NVIDIA devices probed" immediately after -- nouveau was never
# unloaded, so nvidia's own probe correctly found the device still
# owned by nouveau and refused it. Root cause: nouveau is always
# actively bound to the real VT console at the point this script runs
# -- vpinos-menu's own text console deliberately runs on nouveau's real
# KMS driver (see 0120-install-nvidia-driver.hook.chroot's own history
# on why the nouveau blacklist is removed), and the kernel refuses to
# unload any module its own framebuffer console (fbcon) still holds a
# reference to, no matter what `modprobe -r`'s exit code says. Writing
# `0` to the bound vtconsole's own `bind` file releases that reference
# first. Symmetric problem in the reverse direction too -- switching
# back to "default" mode while nvidia-drm's own fbdev=1 console (from a
# previous "nvidia" session) is what's currently bound -- so this runs
# before both directions' module removal, not just the nvidia branch.
unbind_fbcon() {
    for vtcon in /sys/class/vtconsole/vtcon*; do
        [ -e "$vtcon/name" ] || continue
        grep -q "frame buffer device" "$vtcon/name" 2>/dev/null \
            && echo 0 > "$vtcon/bind" 2>/dev/null
    done
    return 0
}

# nvidia-uvm: CUDA's unified-memory module. Nothing graphical needs it,
# but CUDA does -- without it libcuda's cuInit fails with "unknown error
# (999)", confirmed on a real Intel+RTX 5060 laptop, so WiVRn (VR
# streaming, see vpinos-vr.sh) silently fell back to software x264
# instead of NVENC. nvidia-modprobe -u -c=0 creates the /dev/nvidia-uvm*
# nodes, which plain modprobe doesn't (same laptop: both were needed).
# Not via /etc/modules-load.d: this project picks the driver per launch,
# not at boot, and loading nvidia at boot would fight nouveau in
# "default" mode. Doesn't touch the console, so unlike the rest of this
# script it's safe to run even when nothing else needs switching.
load_uvm() {
    lsmod | grep -q '^nvidia_uvm ' && return 0
    if [ "$(cat "$LOADED" 2>/dev/null)" = nvidia-legacy ]; then
        # The legacy driver's own nvidia-uvm: `modprobe nvidia-uvm` would
        # pick the current driver's, which refuses a 580 nvidia.ko.
        legacy_insmod nvidia-uvm
    else
        modprobe nvidia-uvm 2>/dev/null \
            || echo "$(date -Is): vpinos-gpu-driver: modprobe nvidia-uvm failed" >>/var/log/vpinos-menu.log
    fi
    if command -v nvidia-modprobe >/dev/null 2>&1; then
        nvidia-modprobe -u -c=0 2>/dev/null \
            || echo "$(date -Is): vpinos-gpu-driver: nvidia-modprobe -u -c=0 failed" >>/var/log/vpinos-menu.log
    fi
    return 0
}

# The NVIDIA legacy driver (580, Maxwell/Pascal/Volta) lives beside the
# current one: same module names (nvidia, nvidia-drm, ...), so its
# modules sit outside /lib/modules where depmod/udev never see them
# (vpinos-nvidia-legacy-modules-<kernel>) and are insmod'ed by path.
# Which of the two is loaded is recorded in $LOADED -- both show up as
# "nvidia" in lsmod. /run is empty at every boot, exactly like the set of
# loaded modules, and nothing else loads nvidia (it's blacklisted from
# autoload), so the file can't go stale. See notes/nvidia-legacy-plan.md.
LEGACY_MODULES=/usr/lib/vpinos/nvidia-legacy/modules/$(uname -r)
LOADED=/run/vpinos/nvidia-loaded

# insmod doesn't resolve dependencies the way modprobe does: load the
# kernel's own (drm, drm_kms_helper, video, ...) by name first. The
# nvidia* ones are loaded by the caller, in order.
legacy_insmod() {
    ko=$LEGACY_MODULES/$1.ko.xz
    shift
    for dep in $(modinfo -F depends "$ko" 2>/dev/null | tr ',' ' '); do
        case "$dep" in
            nvidia*) ;;
            *) modprobe "$dep" 2>/dev/null || true ;;
        esac
    done
    insmod "$ko" "$@" 2>/dev/null \
        || echo "$(date -Is): vpinos-gpu-driver: insmod $(basename "$ko") $* failed" >>/var/log/vpinos-menu.log
}

# Unloads whichever NVIDIA driver is loaded, current or legacy. rmmod by
# name works for both (modprobe -r can't resolve the legacy ones), in
# reverse dependency order: nvidia.ko can't go while anything above it
# still holds it.
unload_nvidia() {
    for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia; do
        lsmod | grep -q "^$m " && { rmmod "$m" 2>/dev/null \
            || echo "$(date -Is): vpinos-gpu-driver: rmmod $m failed" >>/var/log/vpinos-menu.log; }
    done
    rm -f "$LOADED"
}

mode=$(cat /etc/vpinos/gpu-driver 2>/dev/null || true)

# nvidia-legacy on a kernel its modules weren't built for (a release
# that had to drop them): fall back to the open-source driver rather than
# a black screen. The menu refuses to select it in that case; this covers
# a kernel update after it was selected.
if [ "$mode" = nvidia-legacy ] && [ ! -e "$LEGACY_MODULES/nvidia.ko.xz" ]; then
    echo "$(date -Is): vpinos-gpu-driver: gpu-driver is nvidia-legacy but $LEGACY_MODULES has no modules -- using the open-source driver" >>/var/log/vpinos-menu.log
    mode=default
fi
loaded=$(cat "$LOADED" 2>/dev/null || true)

# Skip the whole unbind/modprobe dance entirely when the right driver
# is already bound -- a real report, confirmed directly: doing it
# unconditionally on *every* launch (as this script originally did)
# caused two real symptoms on a real multi-launch session (vpinfe, then
# vpinball, both in "default" mode, no actual switch ever needed
# between them): launches got noticeably slower, and -- worse -- the
# vpinos-menu text console stopped updating after exiting back to it
# entirely (menu kept running fine, new selections still launched, the
# screen just never repainted again). Root cause: unbind_fbcon()
# unconditionally released the console's framebuffer binding every
# time, but nothing ever rebinds it -- the kernel only auto-rebinds a
# vtconsole when a driver is freshly (re)loaded and registers a new
# framebuffer; if the driver was already loaded and nothing actually
# got removed/reloaded (the common case -- most sessions don't flip
# gpu-driver mode between every single launch), no new framebuffer ever
# gets registered, so the explicitly-unbound vtconsole just stays
# unbound forever, with nothing left attached to draw the console.
# Checking already-loaded modules first and skipping entirely when
# they already match the desired mode avoids ever unbinding anything
# that doesn't need to change, which sidesteps this permanently rather
# than trying to add a matching rebind step.
case "$mode" in
    # The right one of the two NVIDIA drivers, not just "an nvidia":
    # switching straight between nvidia and nvidia-legacy must reload.
    # An empty marker counts as the current driver (a session that loaded
    # it before the marker existed).
    nvidia)
        if lsmod | grep -q '^nvidia_drm ' && lsmod | grep -q '^nvidia ' \
            && [ "${loaded:-nvidia}" = nvidia ]; then
            load_uvm
            exit 0
        fi
        ;;
    nvidia-legacy)
        if lsmod | grep -q '^nvidia_drm ' && lsmod | grep -q '^nvidia ' \
            && [ "$loaded" = nvidia-legacy ]; then
            load_uvm
            exit 0
        fi
        ;;
    # Checks that nvidia isn't loaded -- NOT that nouveau specifically
    # is (the previous version of this check) -- that requirement is
    # what this branch actually cares about and already achieves
    # (removing nvidia, loading nouveau only matters on actual NVIDIA
    # hardware). Confirmed as a real regression from the nouveau-
    # specific version: on any hardware that's neither nvidia nor
    # nouveau (AMD, Intel, or -- how this was actually found -- a QEMU
    # VM's virtio-gpu, which has no reason to ever load nouveau) this
    # condition was never true, so unbind_fbcon() below ran
    # unconditionally on literally every single launch with nothing to
    # ever rebind it -- the exact console-never-repaints-again bug this
    # early-exit was originally added to fix, just reintroduced for
    # every GPU driver except nvidia/nouveau.
    *) ! lsmod | grep -q '^nvidia ' && ! lsmod | grep -q '^nvidia_drm ' && exit 0 ;;
esac

case "$mode" in
    nvidia)
        # nouveau (the open-source driver) is almost certainly already
        # bound -- the kernel auto-loads it via udev/module aliases as
        # soon as it sees NVIDIA hardware, same as amdgpu for AMD cards,
        # well before this script ever runs. It has to be unloaded
        # before nvidia.ko can claim the device. unbind_fbcon first --
        # see its own comment above; without it this modprobe silently
        # fails every time and nvidia never actually gets the GPU.
        unbind_fbcon
        modprobe -r nouveau 2>/dev/null || true
        # Coming from nvidia-legacy: its 580 modules have to go first.
        lsmod | grep -q '^nvidia ' && unload_nvidia
        modprobe nvidia 2>/dev/null \
            || echo "$(date -Is): vpinos-gpu-driver: modprobe nvidia failed -- no NVIDIA hardware, or the precompiled module doesn't match this kernel?" >>/var/log/vpinos-menu.log
        # nvidia-drm, separately, with modeset=1: this is what actually
        # registers a DRM/KMS device Hyprland (or any Wayland compositor)
        # can use -- NVIDIA's own well-documented requirement, not
        # specific to this project. Without modeset=1, nvidia-drm loads
        # but does no modesetting, leaving nothing for Hyprland to bind
        # to. modprobe would auto-resolve `nvidia` as nvidia-drm's own
        # dependency anyway; it's still loaded explicitly just above so
        # the log line above can distinguish "no NVIDIA hardware at all"
        # from a problem specific to the DRM layer.
        #
        # fbdev=1 -- REMOVED, real regression, confirmed directly on
        # real hardware (a GTX 1650). Originally added for a real report
        # of the console going black returning from Hyprland/vpinball
        # with "nvidia" mode selected, on the documented theory (per
        # https://wiki.hypr.land/Nvidia/) that an fbdev-backed console
        # on the nvidia-drm KMS device is what the kernel's own fbcon
        # falls back to once Hyprland releases DRM master. That
        # diagnosis turned out to be wrong -- the real cause of that
        # exact symptom was `unbind_fbcon()` below running
        # unconditionally on every launch with nothing ever rebinding
        # afterward (see that function's own comment), present in BOTH
        # branches of this script, not nvidia-specific at all; fixed
        # properly by the early-exit check above. With that real fix in
        # place, `fbdev=1` turned out to be pure liability: confirmed
        # directly producing corrupted/garbled console output on real
        # hardware once active, and a real SSH session hang attempting
        # `rmmod nvidia_drm` afterward -- consistent with its own
        # `(EXPERIMENTAL)` label (confirmed via this exact module's own
        # parameter description) rather than mature, production-ready
        # behavior. `modeset=1` alone is NVIDIA's own well-documented,
        # non-experimental requirement and is unaffected by any of this.
        modprobe nvidia-drm modeset=1 2>/dev/null \
            || echo "$(date -Is): vpinos-gpu-driver: modprobe nvidia-drm modeset=1 failed" >>/var/log/vpinos-menu.log
        if lsmod | grep -q '^nvidia '; then
            mkdir -p "${LOADED%/*}"
            echo nvidia > "$LOADED"
            load_uvm
        fi
        ;;
    nvidia-legacy)
        # Same sequence as nvidia above (see its comments: unbind_fbcon
        # first or nouveau never lets go), with the 580 modules insmod'ed
        # by path. Options go on the insmod line: modprobe.d's
        # `nvidia-drm modeset=1` (nvidia-wayland.conf) doesn't apply to
        # insmod. NVreg_EnableGpuFirmware=0: Pascal and older have no GSP,
        # and the 580 GSP firmware isn't shipped (no room in the ISO); on
        # Turing and newer the closed module runs without it too.
        unbind_fbcon
        modprobe -r nouveau 2>/dev/null || true
        lsmod | grep -q '^nvidia ' && unload_nvidia
        legacy_insmod nvidia NVreg_EnableGpuFirmware=0
        if lsmod | grep -q '^nvidia '; then
            mkdir -p "${LOADED%/*}"
            echo nvidia-legacy > "$LOADED"
            legacy_insmod nvidia-modeset
            legacy_insmod nvidia-drm modeset=1
            # /dev/nvidiactl, /dev/nvidia0, /dev/nvidia-modeset. The
            # libraries would ask nvidia-modprobe (setuid, version-
            # independent, from the current driver) themselves; doing it
            # here as root just takes that off the first launch.
            if command -v nvidia-modprobe >/dev/null 2>&1; then
                nvidia-modprobe -c=0 -m 2>/dev/null || true
            fi
            load_uvm
        else
            echo "$(date -Is): vpinos-gpu-driver: NVIDIA legacy nvidia.ko didn't load -- no supported NVIDIA card? (dmesg); back to the open-source driver" >>/var/log/vpinos-menu.log
            modprobe nouveau 2>/dev/null || true
        fi
        ;;
    *)
        # Default/anything unrecognized: plain open-source Mesa (NVK on
        # NVIDIA hardware, RADV on AMD, Intel's own driver) -- make sure
        # nvidia isn't still bound from a previous launch this session.
        # nvidia-drm and nvidia-uvm first, then nvidia -- the reverse of
        # the load order above, since nvidia.ko can't unload while either
        # still references it.
        #
        # The explicit `modprobe nouveau` here isn't just defensive --
        # it's required. nvidia-driver ships
        # /etc/modprobe.d/nvidia-blacklists-nouveau.conf (confirmed via
        # Debian's own packaging source), so once it's installed (which
        # 0120-install-nvidia-driver.hook.chroot does unconditionally,
        # regardless of which mode ends up selected), nouveau stops
        # auto-loading entirely, on every boot. `blacklist` only blocks
        # *automatic* alias-based loading (udev/hotplug resolving
        # hardware IDs to a driver) -- it does not block an explicit
        # `modprobe nouveau` by exact name, which is exactly what this
        # does.
        # unload_nvidia covers both NVIDIA drivers (rmmod by name, same
        # reverse order as before).
        unbind_fbcon
        unload_nvidia
        modprobe nouveau 2>/dev/null || true
        ;;
esac

# Only reached after an actual driver switch (both early exits above
# skip it): the newly loaded driver registered a fresh framebuffer,
# whose console starts unrotated, so put the Console Rotation setting
# back on it. Already root here, no sudo.
/usr/libexec/vpinos/vpinos-console-rotation.sh || true
