#!/bin/sh
# Saves a live session's settings on the USB stick it booted from, when
# the "save settings to USB" boot entry was picked (`persistence
# persistence-label=vpinos-data` on the kernel command line, see the
# ISO's config/bootloaders/).
#
# live-boot already knows how to do this: at boot it looks for a
# partition labelled vpinos-data with a persistence.conf in it and puts
# the directories listed there over the image, with the changes kept on
# that partition. Burning the ISO doesn't create that partition -- the
# image's own partition table only covers the image -- so on the first
# boot with that entry this script makes it in the free space after the
# image, and puts the same overlays in place for the session already
# running. live-boot takes over from the next boot on.
#
# Only settings are kept, never the whole system: the kernel always
# boots from the image, so a saved apt upgrade (Update VPinOS) would
# leave modules that don't match it, and a newer ISO would boot with the
# old files on top.
#
#   vpinos-persistence.sh setup    vpinos-persistence.service, at boot
#   vpinos-persistence.sh status   the state and a sentence, for the menus
#   vpinos-persistence.sh reset    Tools > Reset Saved Settings (sudo'd)
#
# setup and reset are root-only: partitioning and mounting -- see
# /etc/sudoers.d/vpinos-core for reset, scoped to this one script, same
# narrow-scope reasoning as every other rule there.

LABEL=vpinos-data
STATUS=/run/vpinos/persistence
# Less free space than this on the stick isn't worth a partition: a
# 2 GB stick has ~100 MB left after the image.
MIN_FREE_MB=1024
# What's saved: the cabinet settings vpinos-menu and vpinos-config
# write, the vpinos user's home (VPinballX.ini, VPinFE, ~/tables) and
# Wi-Fi connections. live-boot panics on a `union` whose directory isn't
# in the image, so only the ones that exist go in persistence.conf.
PATHS="/home /etc/vpinos /etc/NetworkManager/system-connections"

say() {
    echo "vpinos-persistence: $*" >&2
}

# The status the menus and System Info read: the state (saving, other,
# off or failed), a sentence for the user, and where our partition is
# mounted (for reset).
set_status() {
    mkdir -p "$(dirname "$STATUS")"
    printf '%s\n%s\n%s\n' "$1" "$2" "$3" >"$STATUS"
    say "$1: $2"
}

# The partition at /run/live/persistence/<dev>, where live-boot mounts
# persistence media (and so does this script): "<device> <mount point>".
persistence_mounts() {
    awk '$2 ~ "^/run/live/persistence/" { print $1, $2 }' /proc/mounts
}

# The disk the live image was read from. Nothing for a DVD or a VM's CD
# (rom), Ventoy (dm) or an ISO file on another disk (loop).
boot_disk() {
    src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null)
    case "$src" in
        /dev/*) ;;
        *) return 1 ;;
    esac
    case "$(lsblk -dno TYPE "$src" 2>/dev/null)" in
        disk) echo "$src" ;;
        part) echo "/dev/$(lsblk -dno PKNAME "$src")" ;;
        *) return 1 ;;
    esac
}

# The disk's partitions, one "<number> <start> <size> <type>" per line,
# from sfdisk's dump: "/dev/sdb1 : start=   64, size=   4035392, type=0, bootable".
partitions() {
    sfdisk -d "$1" 2>/dev/null | awk -F'[:,]' '/ : start=/ {
        n = $1; gsub(/ /, "", n); sub(/^.*[^0-9]/, "", n)
        s = $2; sub(/.*= */, "", s)
        z = $3; sub(/.*= */, "", z)
        t = $4; sub(/.*= */, "", t)
        print n, s, z, t
    }'
}

# The device node of partition <n> of <disk>: sdb3, mmcblk0p3, nvme0n1p3.
part_node() {
    for p in $(lsblk -lnpo NAME "$1" 2>/dev/null); do
        if [ "$(cat "/sys/class/block/${p#/dev/}/partition" 2>/dev/null)" = "$2" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# Whether the vpinos-data partition at <dev> has a persistence.conf.
# Without one live-boot ignores the partition: a first setup that was
# cut off, or Reset Saved Settings, which removes it.
has_conf() {
    tmp=$(mktemp -d) || return 1
    found=1
    if mount -o ro "$1" "$tmp" 2>/dev/null; then
        [ -f "$tmp/persistence.conf" ] && found=0
        umount "$tmp"
    fi
    rmdir "$tmp"
    return $found
}

# Formats <dev>, writes persistence.conf and puts the overlays in place
# for this session, the same layout live-boot's do_union uses
# (<partition><path>/rw and /work), so live-boot picks it up as is.
make_persistence() {
    part=$1
    mp=/run/live/persistence/${part#/dev/}

    # The caller reads the mount point from stdout, so nothing else
    # goes there.
    mkfs.ext4 -F -q -m 0 -L "$LABEL" "$part" >&2 || return 1
    mkdir -p "$mp"
    mount -o noatime "$part" "$mp" >&2 || return 1

    conf=""
    for p in $PATHS; do
        # In the image (see PATHS); live-boot's own test is the same.
        ls -d /run/live/rootfs/*"$p" >/dev/null 2>&1 || continue
        [ -d "$p" ] || continue
        # rw's own owner and mode become the directory's in the overlay
        # (system-connections is root-only), so they're copied from it.
        mkdir -p "$mp$p/rw" "$mp$p/work"
        chown --reference="$p" "$mp$p" "$mp$p/rw"
        chmod --reference="$p" "$mp$p" "$mp$p/rw"
        conf="$conf$p union
"
    done
    [ -n "$conf" ] || return 1

    # Written last, and only once it's complete: a partition without
    # one is set up again from scratch on the next boot.
    printf '%s' "$conf" >"$mp/persistence.conf.new" &&
        sync &&
        mv "$mp/persistence.conf.new" "$mp/persistence.conf" &&
        sync || return 1

    # This session: the overlays over what's here now, so nothing done
    # so far this boot is lost. Before the menu and NetworkManager start
    # (see vpinos-persistence.service), so nothing has these open yet.
    for p in $(awk '{ print $1 }' "$mp/persistence.conf"); do
        mount -t overlay overlay \
            -o "noatime,lowerdir=$p,upperdir=$mp$p/rw,workdir=$mp$p/work" "$p" ||
            return 1
    done
    echo "$mp"
}

setup() {
    # A later boot: live-boot found the partition and has done it all.
    # Rufus and Ventoy have persistence of their own, under another
    # label; that's left alone.
    persistence_mounts | while read -r dev mp; do
        if [ "$(blkid -s LABEL -o value "$dev" 2>/dev/null)" = "$LABEL" ] && [ -f "$mp/persistence.conf" ]; then
            set_status saving "Settings are saved to this USB stick." "$mp"
            exit 10
        fi
    done
    [ $? = 10 ] && return 0
    if [ -n "$(persistence_mounts)" ]; then
        set_status other "Settings are saved by this USB stick's own persistence (Rufus or Ventoy)."
        return 0
    fi

    if ! disk=$(boot_disk); then
        set_status off "Not saving settings: this isn't a USB stick written from the ISO (DVD, virtual machine or Ventoy)."
        return 0
    fi
    if [ "$(lsblk -dno RO "$disk")" != 0 ]; then
        set_status off "Not saving settings: the USB stick is write-protected."
        return 0
    fi
    if ! sfdisk -d "$disk" 2>/dev/null | grep -qx 'label: dos'; then
        set_status off "Not saving settings: the USB stick isn't laid out the way writing the ISO leaves it."
        return 0
    fi

    # Written from the ISO (dd, Etcher, Rufus's DD mode), the stick has
    # the image's own two partitions: 1 is the whole image (type 0,
    # from sector 64) and 2 the EFI boot image inside it. Ours goes after
    # the image, on a 1 MiB boundary, to the end of the stick. Rufus's
    # ISO mode copies files to one FAT partition instead, with nothing
    # free after it.
    table=$(partitions "$disk")
    p1=$(echo "$table" | awk '$1 == 1')
    p2=$(echo "$table" | awk '$1 == 2')
    p3=$(echo "$table" | awk '$1 == 3')
    others=$(echo "$table" | awk '$1 > 3')
    set -- $p1
    if [ "$2" != 64 ] || [ "$4" != 0 ] || [ "$(echo "$p2" | awk '{ print $4 }')" != ef ] || [ -n "$others" ]; then
        set_status off "Not saving settings: the USB stick isn't laid out the way writing the ISO leaves it."
        return 0
    fi
    start=$(( ($2 + $3 + 2047) / 2048 * 2048 ))
    sectors=$(cat "/sys/class/block/${disk#/dev/}/size")

    if [ -z "$p3" ]; then
        if [ $((sectors - start)) -lt $((MIN_FREE_MB * 2048)) ]; then
            set_status off "Not saving settings: less than $MIN_FREE_MB MB free on the USB stick."
            return 0
        fi
        set_status working "Setting up saved settings on this USB stick..."
        echo "Setting up saved settings on this USB stick..." >/dev/console
        # --no-reread: the stick is in use (the image is mounted from
        # it), so the kernel is told about the one new partition by
        # partx instead of re-reading the whole table. sfdisk only
        # rewrites the partition entries, never the image's boot code.
        if ! echo "start=$start, type=83" | sfdisk -q --append --no-reread --no-tell-kernel "$disk"; then
            set_status failed "Not saving settings: couldn't create a partition on the USB stick."
            return 0
        fi
        partx -a --nr 3 "$disk" 2>/dev/null
    else
        # Partition 3 is there already: ours from an earlier boot that
        # didn't finish, or one Reset Saved Settings cleared. Anything
        # else on it is left alone.
        set -- $p3
        if [ "$2" != "$start" ] || [ "$4" != 83 ]; then
            set_status off "Not saving settings: the USB stick already has another partition after the image."
            return 0
        fi
        partx -a --nr 3 "$disk" 2>/dev/null
    fi

    udevadm settle 2>/dev/null
    part=$(part_node "$disk" 3)
    if [ -z "$part" ]; then
        set_status failed "Not saving settings: the new partition on the USB stick didn't show up."
        return 0
    fi
    if [ -n "$p3" ]; then
        fs=$(blkid -s TYPE -o value "$part" 2>/dev/null)
        label=$(blkid -s LABEL -o value "$part" 2>/dev/null)
        if [ -n "$fs" ] && [ "$label" != "$LABEL" ]; then
            set_status off "Not saving settings: the USB stick already has another partition after the image."
            return 0
        fi
        if [ "$label" = "$LABEL" ] && has_conf "$part"; then
            # Set up, but live-boot didn't use it.
            set_status failed "Not saving settings: the saved settings on this USB stick couldn't be read."
            return 0
        fi
        echo "Setting up saved settings on this USB stick..." >/dev/console
    fi

    if ! mp=$(make_persistence "$part"); then
        set_status failed "Not saving settings: setting up the USB stick failed (see journalctl -u vpinos-persistence)."
        return 0
    fi
    set_status saving "Settings are saved to this USB stick." "$mp"
}

status() {
    if [ -f "$STATUS" ]; then
        head -n 2 "$STATUS"
    else
        echo none
    fi
}

# Removes persistence.conf, so the next boot with "save settings"
# starts from scratch: live-boot ignores the partition without it, and
# setup formats it again. The settings stay in use until the reboot the
# menu does straight after.
reset() {
    if [ "$(sed -n 1p "$STATUS" 2>/dev/null)" != saving ]; then
        echo "Settings aren't being saved to this USB stick."
        return 1
    fi
    mp=$(sed -n 3p "$STATUS")
    case "$mp" in
        /run/live/persistence/?*) ;;
        *) echo "Settings aren't being saved to this USB stick."; return 1 ;;
    esac
    rm -f "$mp/persistence.conf" && sync || {
        echo "Couldn't clear the saved settings."
        return 1
    }
    set_status off "Saved settings cleared; starting fresh at the next boot."
}

case "$1" in
    setup) setup ;;
    status) status ;;
    reset) reset ;;
    *) echo "usage: vpinos-persistence.sh setup|status|reset" >&2; exit 2 ;;
esac
