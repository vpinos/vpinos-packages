#!/usr/bin/env bash

wpctl status | awk '
    /^Audio/ { audio=1; next }
    audio && /^[^ ]/ { audio=0 }
    audio && /Devices:/ { devices=1; next }
    audio && /(Sinks|Sources|Filters|Streams):/ { devices=0 }
    audio && devices && match($0, /[0-9]+\./) {
        id   = substr($0, RSTART, RLENGTH-1)
        name = substr($0, RSTART+RLENGTH)
        sub(/^[ \t]+/, "", name)
        sub(/[ \t]+\[.*$/, "", name)
        print id "\t" name
    }
' | while IFS=$'\t' read -r id name; do
    echo
    echo "========================================"
    echo "Device ID: $id  ($name)"
    echo "========================================"

    # The active profile's index is the first Int after Profile:index.
    active=$(pw-cli enum-params "$id" Profile </dev/null | awk '
        /Profile:index / { want = 1; next }
        want && $1 == "Int" { print $2; exit }
    ')

    # * marks the active profile.
    pw-cli enum-params "$id" EnumProfile </dev/null | awk -v active="$active" '
        function flush() {
            if (idx != "")
                printf "%s ID: %-4s Profile: %-45s %s\n", (idx == active ? "*" : " "), idx, pname, desc
            idx = pname = desc = ""
        }
        function strval(s) {
            sub(/^[^"]*"/, "", s); sub(/"[^"]*$/, "", s); return s
        }
        $1 == "Object:"             { flush(); next }
        /Profile:index /            { want = "index"; next }
        /Profile:name /             { want = "name";  next }
        /Profile:description /      { want = "desc";  next }
        want == "index" && $1 == "Int"    { idx   = $2;         want = ""; next }
        want == "name"  && $1 == "String" { pname = strval($0); want = ""; next }
        want == "desc"  && $1 == "String" { desc  = strval($0); want = ""; next }
        END { flush() }
    '
done

echo
echo "========================================"
echo "Sinks"
echo "========================================"
default_sink=$(wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '$1 == "id" { sub(/,$/, "", $2); print $2; exit }')

# "*   53. Name [vol: 0.82]", and a muted sink's volume reads
# "[vol: 0.40 MUTED]". * marks the default sink.
wpctl status | awk -v default_sink="$default_sink" '
    /^Audio/ { audio=1; next }
    audio && /^[^ ]/ { audio=0 }
    audio && /Sinks:/ { sinks=1; next }
    audio && /(Devices|Sources|Filters|Streams):/ { sinks=0 }
    audio && sinks && match($0, /[0-9]+\./) {
        id   = substr($0, RSTART, RLENGTH-1)
        name = substr($0, RSTART+RLENGTH)
        sub(/^[ \t]+/, "", name)
        vol = ""
        if (match(name, /\[vol: [^]]*\]/)) {
            split(substr(name, RSTART+6, RLENGTH-7), v, " ")
            vol = sprintf("%d%%", v[1] * 100 + 0.5)
            if (v[2] == "MUTED") vol = vol " muted"
            name = substr(name, 1, RSTART-1)
            sub(/[ \t]+$/, "", name)
        }
        printf "%s ID: %-4s Volume: %-10s %s\n", (id == default_sink ? "*" : " "), id, vol, name
    }
'
