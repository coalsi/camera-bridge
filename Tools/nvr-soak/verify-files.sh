#!/bin/sh
# The short form of linux/web-dev/soak/verify-files.mjs for machines without Node (the Linux container, a box): the sidecar of each closed file
# is checked against the file (magic, size formula, mp4 size), a sample decodes to the end with ffmpeg, and its video packet count equals the
# sidecar's sample count. The full "sidecar equals a fresh scan" comparison is the Node tool's, on the Mac.
#
#   sh verify-files.sh ROOT [--sample N] [--decode M] [--allow-open N] [--must-be-closed LISTFILE]
# Prints one JSON object { closed, open, checked, decoded, problems: [...] }; exit status 0 when problems is empty.
set -u
root="${1:?recordings folder}"; shift
sample=24; decode=6; allow_open=999999; must=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sample) sample="$2"; shift 2 ;;
        --decode) decode="$2"; shift 2 ;;
        --allow-open) allow_open="$2"; shift 2 ;;
        --must-be-closed) must="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
done
problems=""; add() { problems="$problems${problems:+,}\"$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')\""; }
size_of() { wc -c < "$1" | tr -d ' '; }
# od prints one line of byte values per call (macOS adds an empty line after it, hence NF).
u16() { od -An -tu1 -j"$2" -N2 "$1" | awk 'NF { print $1 * 256 + $2; exit }'; }
u32() { od -An -tu1 -j"$2" -N4 "$1" | awk 'NF { print (($1 * 256 + $2) * 256 + $3) * 256 + $4; exit }'; }
u64() { od -An -tu1 -j"$2" -N8 "$1" | awk 'NF { v = 0; for (i = 1; i <= 8; i++) v = v * 256 + $i; printf "%.0f\n", v; exit }'; }

closed_list=$(mktemp); open_list=$(mktemp); trap 'rm -f "$closed_list" "$open_list"' EXIT
for mp4 in "$root"/*/*/*.mp4; do
    [ -e "$mp4" ] || continue
    if [ -f "${mp4%.mp4}.cbidx" ]; then echo "$mp4" >> "$closed_list"; else echo "$mp4" >> "$open_list"; fi
done
closed=$(wc -l < "$closed_list" | tr -d ' '); open=$(wc -l < "$open_list" | tr -d ' ')
[ "$open" -le "$allow_open" ] || add "$open files without a sidecar, at most $allow_open may be open"

check_sidecar() {   # prints the sample count of the sidecar, or "" and records a problem
    f="$1"; side="${1%.mp4}.cbidx"; rel="${1#"$root"/}"
    [ "$(dd if="$side" bs=4 count=1 2>/dev/null)" = "CBNX" ] || { add "$rel: sidecar has the wrong magic"; return 1; }
    count=$(u32 "$side" 52); rollups=$(u16 "$side" 56)
    want=$((64 + rollups * 12 + count * 40)); have=$(size_of "$side")
    [ "$have" = "$want" ] || { add "$rel: sidecar is $have bytes, expected $want"; return 1; }
    [ "$(u64 "$side" 40)" = "$(size_of "$f")" ] || { add "$rel: sidecar says $(u64 "$side" 40) bytes, the file has $(size_of "$f")"; return 1; }
    # The records are 40 bytes each; the sample count is the big-endian u16 at byte 36. (od's line width differs between systems, so count bytes.)
    samples=$(od -An -v -tu1 -j$((64 + rollups * 12)) "$side" | awk 'NF { for (i = 1; i <= NF; i++) { m = n % 40; if (m == 36) hi = $i; else if (m == 37) s += hi * 256 + $i; n++ } } END { print s + 0 }')
    echo "$samples"
}

checked=0; decoded=0
pick=$(mktemp); trap 'rm -f "$closed_list" "$open_list" "$pick"' EXIT
if [ "$sample" -eq 0 ] || [ "$closed" -le "$sample" ]; then cp "$closed_list" "$pick"
else awk 'BEGIN { srand(3) } { print rand() "\t" $0 }' "$closed_list" | sort | head -n "$sample" | cut -f2- > "$pick"; fi
if [ -n "$must" ]; then
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        if [ -f "$root/${rel%.mp4}.cbidx" ]; then echo "$root/$rel" >> "$pick"; else add "$rel: still has no sidecar after recovery"; fi
    done < "$must"
fi
sort -u "$pick" -o "$pick"
while IFS= read -r f; do
    checked=$((checked + 1))
    samples=$(check_sidecar "$f") || continue
    if [ "$decoded" -lt "$decode" ]; then
        decoded=$((decoded + 1)); rel="${f#"$root"/}"
        err=$(ffmpeg -v error -xerror -i "$f" -f null - 2>&1 >/dev/null | head -n 1)
        [ -z "$err" ] || add "$rel: ffmpeg: $err"
        packets=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$f" 2>/dev/null)
        [ "$packets" = "$samples" ] || add "$rel: $packets video packets, the sidecar counts $samples samples"
    fi
done < "$pick"
stray=$(find "$root" -type f ! -name camera.json ! -name '*.mp4' ! -name '*.cbidx' | head -n 5)
[ -z "$stray" ] || add "stray files: $(echo "$stray" | sed "s#^$root/##" | tr '\n' ' ')"
printf '{"closed":%s,"open":%s,"checked":%s,"decoded":%s,"problems":[%s]}\n' "$closed" "$open" "$checked" "$decoded" "$problems"
[ -z "$problems" ]
