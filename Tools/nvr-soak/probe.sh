#!/bin/sh
# One sample of a running daemon's resource use, as one line of six integers:
#   rssKB fds threads established closeWait memKB
# memKB is the daemon's own memory: the physical footprint on the Mac (`footprint`), the anonymous resident memory on Linux (RssAnon); 0 when the system does not say.
# rssKB (ps, VmRSS) also counts pages the system can take back at any time, so it is reported but the memory rule does not judge it.
# Usage: sh probe.sh PLATFORM PID PORT        PLATFORM: darwin | linux
# It only reads (ps, lsof, /proc, ss). Run it on the machine the daemon runs on: directly, or through `docker exec CONTAINER` or `ssh HOST`.
set -u
platform="${1:?platform: darwin or linux}"; pid="${2:?pid}"; port="${3:?port}"
count() { awk 'END { print NR + 0 }'; }
case "$platform" in
    darwin)
        rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        mem=$(footprint "$pid" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i < NF; i++) if ($i == "Footprint:") { v = $(i + 1); u = $(i + 2); if (u == "MB") v *= 1024; else if (u == "GB") v *= 1048576; else if (u == "B" || u == "bytes") v /= 1024; printf "%d", v; exit } }')
        fds=$(lsof -nP -p "$pid" 2>/dev/null | awk 'NR > 1' | count)
        threads=$(ps -M -p "$pid" 2>/dev/null | awk 'NR > 1' | count)
        established=$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:ESTABLISHED 2>/dev/null | awk 'NR > 1' | count)
        closewait=$(lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:CLOSE_WAIT 2>/dev/null | awk 'NR > 1' | count)
        ;;
    linux)
        rss=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
        mem=$(awk '/^RssAnon:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
        fds=$(ls "/proc/$pid/fd" 2>/dev/null | count)
        threads=$(awk '/^Threads:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
        established=$(ss -Htn state established "( sport = :$port )" 2>/dev/null | count)
        closewait=$(ss -Htn state close-wait "( sport = :$port )" 2>/dev/null | count)
        ;;
    *) echo "unknown platform $platform" >&2; exit 2 ;;
esac
[ -n "${rss:-}" ] || { echo "process $pid is gone" >&2; exit 1; }
echo "$rss $fds ${threads:-0} $established $closewait ${mem:-0}"
