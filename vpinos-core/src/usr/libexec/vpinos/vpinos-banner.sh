#!/bin/sh
# Shared source for the VPinOS logo/version/IP banner -- used by
# vpinos-menu's print_logo() (the console menu header) AND
# /etc/update-motd.d/00-vpinos-banner (shown on SSH login), so the
# raw ANSI art and the version/IP logic live in exactly one place
# rather than being duplicated between the two call sites.
    cat <<'EOF'
[40m[30m▄[47m[97m▄[107m[37m░[47m[97m▄[107m[37m░[40m[30m▄[40m  [40m▄[97m▄[107m[30m   ▄[37m░░[30m      [40m[97m▄[37m▄[30m▄[107m   [40m▄▄▄▄▄▄▄▄▄▄▄[96m▄▄[46m▄▄▄▄▄[40m▄▄[30m▄[96m▄▄[106m[30m     [36m░[30m [40m[96m▄[30m▄[0m
[40m[30m [40m▄[107m   [40m[97m▄[30m▄▄[97m▄[107m[30m   [40m▄[97m▄[107m[30m   ▄▄▄    [40m[97m▄▄▄[30m▄[97m▄▄▄▄▄▄▄▄[30m▄▄[106m[36m░░░[30m▄▄▄▄[36m░░░[40m[30m▄[106m[36m░░░[30m▄▄▄▄▄▄▄[40m▄[0m
[40m[30m [40m▄[107m▄[37m░░░[40m[30m▄[97m▄[107m[37m░░[30m [40m▄▄[107m  [37m░[40m[97m▄▄▄▄[107m[37m░░[30m [40m▄[107m   [40m▄[107m   ▄▄    [40m[96m▄[106m[36m▒▒░[40m[30m▄▄▄[90m▄[106m[36m▒▒░[40m[30m▄[106m[36m▒▒▒▒▒▒▒[40m▄▄[30m▄[40m [0m
[40m[30m  [40m▄[107m[94m░[34m░░[40m[37m▄[107m[34m░░[30m▄[40m▄▄[97m▄[107m[94m░░░[30m▄▄▄▄▄▄[40m▄[97m▄[107m[94m░░[30m▄[37m░[94m░░[40m[30m▄▄▄[107m[94m░░░[40m[30m▄[106m[34m▒░░[40m[30m▄▄▄▄[106m[36m▄[34m▒▒[30m▄[40m▄▄[106m▄▄[46m▄▄▄[106m[34m▒▒▒[40m[30m▄[40m [0m
[40m[30m  [40m▄[47m▄[106m[35m░░░░[107m[30m▄[40m▄▄▄[107m[94m▒▒▒[47m[30m▄[40m▄▄▄▄▄▄▄[107m[94m▒▒▒[40m[30m▄[107m[94m▒▒▒[40m[30m▄▄[90m▄[107m[94m▒▒[47m[97m▄[40m[30m▄[104m[36m░░░░░░░░░[106m[34m▒[40m[30m▄[104m[36m░░░░░░░░░[30m▄[40m▄[40m [0m
[40m[30m   [40m▄[107m▄▄▄▄[40m▄▄▄▄[107m▄▄▄[40m▄▄▄▄▄▄▄▄[107m▄▄▄[47m▄[107m▄▄[96m▄[40m[30m▄▄[107m▄▄▄[40m▄▄▄[106m▄▄▄▄▄▄▄[40m▄▄[106m▄▄▄▄▄▄▄▄▄[40m▄▄[40m  [0m
[40m[30m    [40m▄[104m▄▄▄[46m▄▄▄▄[106m▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄[40m[96m▄[106m[30m▄[36m▒[40m[30m▄[104m[36m░[40m[30m▄[106m▄▄▄▄▄▄▄▄▄▄▄▄▄▄[46m▄▄▄▄[104m▄▄▄▄[40m▄[40m    [0m
[40m[30m                          [40m▄[106m▄[40m[96m▄[30m▄▄[104m[36m░[40m[30m▄[40m                           [0m
[40m[30m                           [40m▄▄[106m▄[46m▄[40m▄▄[40m                           [0m
EOF
    # os-release is sourced in a subshell so it can't leak/clobber any
    # variable in the caller. `hostname -I` (capital I, the
    # `hostname` package's own flag, not iproute2) lists every assigned
    # address space-separated; first one is enough for an at-a-glance
    # cabinet IP, and it's empty (not an error) before DHCP has
    # completed or with no cable/Wi-Fi connected, so that's handled
    # explicitly rather than printing a blank value.
    # vpinos-core's version is the VPinOS version (it moves with every
    # update); /etc/os-release's VERSION_ID only names the ISO the cabinet
    # was installed from, so it's just the fallback.
    ver=$(dpkg-query -W -f='${Version}' vpinos-core 2>/dev/null)
    [ -z "$ver" ] && ver=$(. /etc/os-release 2>/dev/null; echo "$VERSION_ID")
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$ip" ] && ip="not connected"

    # Bordered, centered under the logo -- plain ASCII (+/-/|), not box-
    # drawing Unicode, deliberately: same reasoning as the art above
    # avoiding Rich/Textual's box-drawing glyphs, zero risk instead of
    # unverified risk. Width matches the logo's own visible width (62
    # columns, confirmed via the art above -- every line is the same
    # width) so the frame lines up edge-to-edge with it rather than
    # floating at some unrelated size. Version and IP are separate rows
    # (not one combined line) and each centered independently, since
    # they're two distinct pieces of information, not one value.
    left_label="Version: "
    left="${left_label}${ver}"
    right_label="IP: "
    right="${right_label}${ip}"
    width=60
    leftcol=8
    rightcol=$((width - ${#right} + 1 - 8))
    # Overlaid directly onto the logo's own second-to-last row (not a
    # separate line below it) via plain VT100 cursor positioning --
    # CSI nA (cursor up n rows) and CSI nG (move to column n, same
    # row) -- ordinary ANSI cursor control, not Unicode, so it's no
    # less reliable on the real console than the color codes already
    # used throughout this art. \033[0m resets color first: that row
    # is black-on-black at this position in the original art, which
    # would otherwise make this text invisible without it. Labels red
    # (31), values bright white (97) for contrast. leftcol=8 (7-space
    # indent from column 1) and rightcol subtracts 10 from the plain
    # right-aligned position -- both fixed offsets from their earlier
    # flush-left/flush-right placement, not computed from the art's
    # own content. Ends by moving back down and to column 1 so
    # whatever prints next (menu options, etc.) resumes on a fresh
    # line below the logo, not mid-overlay.
    printf '\033[2A\033[%dG\033[0m\033[31m%s\033[97m%s' "$leftcol" "$left_label" "$ver"
    printf '\033[%dG\033[31m%s\033[97m%s' "$rightcol" "$right_label" "$ip"
    printf '\033[0m\033[2B\033[1G\n'
