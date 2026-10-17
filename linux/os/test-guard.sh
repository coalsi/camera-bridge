#!/bin/bash
# Self-test of the internet guard's root side (mkosi.extra/usr/sbin/cb-guard): the check of the list of watched cameras, and the collector
# against recorded lines of dnsmasq's query log (dnsmasq 2.91 of Debian 13 with log-queries, the service's TZ=UTC). No root, no firewall, no
# systemd: under CB_GUARD_ROOT cb-guard leaves them alone. Needs bash, jq, GNU date and the time zone files. Runs in the static checks job.
#
#   bash linux/os/test-guard.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD=$HERE/mkosi.extra/usr/sbin/cb-guard
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
root=""
now=0

pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
expect() { # expect DESCRIPTION ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; fi
}
guard() { CB_GUARD_ROOT=$root CB_GUARD_NOW=$now CB_GUARD_DNS_SINCE=${dns_since:-} bash "$GUARD" "$@"; }
dns_since=""   # when the stand-in DNS started answering (epoch seconds); empty: it does not run
at() { date -u -d "$1" +%s; }
fresh() { # a new stand-in for /, with the list of watched cameras $1 and the time $2
    root=$(mktemp -d "$tmp/root.XXXXXX")
    mkdir -p "$root/srv/system/guard" "$root/run/camera-bridge/guard/log" "$root/run/camera-bridge/status"
    printf '%s\n' "$1" >"$tmp/body.json"
    now=$(at "$2")
    guard set "$tmp/body.json" >/dev/null 2>&1 || bad "the list was taken: $1"
}
status() { jq -c "$1" "$root/run/camera-bridge/status/guard.json"; }
log_lines() { cat >>"$root/run/camera-bridge/guard/log/queries.log"; }
refused() { # refused DESCRIPTION BODY
    printf '%s\n' "$2" >"$tmp/refused.json"
    if out=$(CB_GUARD_ROOT=$tmp CB_GUARD_NOW=0 bash "$GUARD" check "$tmp/refused.json" 2>&1); then bad "$1 (taken: $out)"
    elif grep -q '^error: ' <<<"$out"; then pass "$1"
    else bad "$1 (failed without saying why: $out)"; fi
}

[ -x "$GUARD" ] || bad "cb-guard is missing or not executable"

# --- the list of watched cameras ----------------------------------------------------------------------------------------
printf '%s\n' '{"cameras": [{"address": "192.168.77.21", "level": "watch"}, {"address": "FD00:0:0:0:0:0:0:21", "level": "watch"},
                {"address": "192.168.77.21", "level": "watch"}, {"address": "fe80:0:0:0:1:0:0:1", "level": "watch"}],
                "timeZone": "America/Los_Angeles", "extra": true}' >"$tmp/list.json"
expect "a list is kept with canonical addresses, each once, and its time zone" \
    "$(CB_GUARD_ROOT=$tmp bash "$GUARD" check "$tmp/list.json")" \
    '{"cameras":[{"address":"192.168.77.21","level":"watch"},{"address":"fd00::21","level":"watch"},{"address":"fe80::1:0:0:1","level":"watch"}],"timeZone":"America/Los_Angeles"}'
printf '%s\n' '{"cameras": [], "timeZone": "../../etc/passwd"}' >"$tmp/list.json"
expect "an odd time zone becomes UTC" "$(CB_GUARD_ROOT=$tmp bash "$GUARD" check "$tmp/list.json")" '{"cameras":[],"timeZone":"UTC"}'
printf '%s\n' '{"cameras": [], "timeZone": "Mars/Olympus_Mons"}' >"$tmp/list.json"
expect "an unknown time zone becomes UTC" "$(CB_GUARD_ROOT=$tmp bash "$GUARD" check "$tmp/list.json")" '{"cameras":[],"timeZone":"UTC"}'
printf '%s\n' '{"cameras": [{"address": "10.0.0.1", "level": "watch"}, {"address": "172.16.0.1", "level": "watch"},
                {"address": "172.31.255.254", "level": "watch"}, {"address": "169.254.10.20", "level": "watch"}, {"address": "febf:ffff::1", "level": "watch"}]}' >"$tmp/list.json"
expect "every local range is taken" "$(CB_GUARD_ROOT=$tmp bash "$GUARD" check "$tmp/list.json" | jq -c '[.cameras[].address]')" \
    '["10.0.0.1","172.16.0.1","172.31.255.254","169.254.10.20","febf:ffff::1"]'

refused "a public IPv4 address is refused" '{"cameras": [{"address": "8.8.8.8", "level": "watch"}]}'
refused "a documentation IPv4 address is refused" '{"cameras": [{"address": "192.0.2.10", "level": "watch"}]}'
refused "a global IPv6 address is refused" '{"cameras": [{"address": "2001:db8::1", "level": "watch"}]}'
refused "172.32.0.1 is not private" '{"cameras": [{"address": "172.32.0.1", "level": "watch"}]}'
refused "loopback is refused" '{"cameras": [{"address": "127.0.0.1", "level": "watch"}]}'
refused "leading zeros are refused" '{"cameras": [{"address": "192.168.077.21", "level": "watch"}]}'
refused "an IPv6 address with a zone is refused" '{"cameras": [{"address": "fe80::1%eth0", "level": "watch"}]}'
refused "an IPv4-mapped IPv6 address is refused" '{"cameras": [{"address": "::ffff:192.168.77.21", "level": "watch"}]}'
refused "two :: are refused" '{"cameras": [{"address": "fd00::1::2", "level": "watch"}]}'
refused "nine groups are refused" '{"cameras": [{"address": "fd00:1:2:3:4:5:6:7:8", "level": "watch"}]}'
refused "a name is refused" '{"cameras": [{"address": "camera.local", "level": "watch"}]}'
refused "nft syntax is refused" '{"cameras": [{"address": "192.168.77.21 }; flush ruleset; add element inet camera_bridge guarded4 { 10.0.0.1", "level": "watch"}]}'
refused "a number is refused" '{"cameras": [{"address": 3232255253, "level": "watch"}]}'
refused "Seal is not offered yet" '{"cameras": [{"address": "192.168.77.21", "level": "seal"}]}'
refused "a camera without a level is refused" '{"cameras": [{"address": "192.168.77.21"}]}'
refused "a list that is not an array is refused" '{"cameras": "192.168.77.21"}'
refused "a body without a list is refused" '{}'
refused "a body that is not JSON is refused" 'cameras=192.168.77.21'
refused "65 cameras are too many" "$(jq -n -c '{cameras: [range(1; 66) | {address: "10.0.1.\(.)", level: "watch"}]}')"
expect "64 cameras are fine" "$(jq -n -c '{cameras: [range(1; 65) | {address: "10.0.1.\(.)", level: "watch"}]}' >"$tmp/list.json"
                               CB_GUARD_ROOT=$tmp bash "$GUARD" check "$tmp/list.json" | jq '.cameras | length')" "64"

# --- the collector ------------------------------------------------------------------------------------------------------
fresh '{"cameras": [{"address": "192.168.77.21", "level": "watch"}, {"address": "FD00::0021", "level": "watch"}], "timeZone": "UTC"}' "2026-10-17 18:00:00"
expect "a new list writes the status at once" "$(status '[.available, .running, .message, (.cameras | map(.address))]')" \
    '[true,false,"2 cameras are watched",["192.168.77.21","fd00::21"]]'
expect "the list is kept, private to root" "$(stat -c %a "$root/srv/system/guard/cameras.json")" "600"
# Recorded from dnsmasq 2.91 (192.168.77.x stand in for the cameras); the TCP question comes from a child process.
log_lines <<'EOF'
Oct 17 17:46:00 dnsmasq[20]: started, version 2.91 cache disabled
Oct 17 17:46:00 dnsmasq[20]: compile time options: IPv6 GNU-getopt DBus no-UBus i18n IDN2 DHCP DHCPv6 no-Lua TFTP conntrack ipset nftset auth DNSSEC loop-detect inotify dumpfile
Oct 17 17:46:00 dnsmasq[20]: warning: interface wl* does not currently exist
Oct 17 17:46:00 dnsmasq[20]: warning: no upstream servers configured
Oct 17 17:46:01 dnsmasq[20]: query[A] p2p.example.com from 192.168.77.21
Oct 17 17:46:01 dnsmasq[20]: config p2p.example.com is NXDOMAIN
Oct 17 17:46:01 dnsmasq[20]: query[AAAA] cloud.example.net from 192.168.77.21
Oct 17 17:46:01 dnsmasq[20]: config cloud.example.net is NXDOMAIN
Oct 17 17:46:01 dnsmasq[20]: query[PTR] 1.77.168.192.in-addr.arpa from 192.168.77.21
Oct 17 17:46:01 dnsmasq[20]: config 1.77.168.192.in-addr.arpa is NXDOMAIN
Oct 17 17:46:01 dnsmasq[42]: query[A] tcp.example.org from 192.168.77.21
Oct 17 17:46:01 dnsmasq[42]: config tcp.example.org is NXDOMAIN
Oct 17 17:46:01 dnsmasq[20]: query[TXT] version.bind from 192.168.77.21
Oct 17 17:46:01 dnsmasq[20]: config version.bind is not implemented (EDE: unknown)
Oct 17 17:46:01 dnsmasq[20]: query[A] weird"name\032x.example.com from 192.168.77.21
Oct 17 17:46:01 dnsmasq[20]: config weird"name\032x.example.com is NXDOMAIN
Oct 17 17:46:03 dnsmasq[20]: query[A] P2P.Example.COM from 192.168.77.21
Oct 17 17:50:44 dnsmasq[18]: query[A] p2p.example.com from 192.168.77.21
Oct 17 17:50:45 dnsmasq[18]: query[A] p2p.example.com from 192.168.77.99
Oct  7 09:00:00 dnsmasq[18]: query[A] old.example.com from 192.168.77.21
Oct 17 12:00:00 dnsmasq[18]: query[A] ntp.example.org from fd00::21
Oct 17 12:00:01 dnsmasq[18]: query[A] torn.example.org from 192.168.7
EOF
printf 'Oct 17 17:59:59 dnsmasq[18]: query[A] \001\002 junk\n\377\376\n' | log_lines
guard collect || bad "collect ran"
expect "lookups today and in the last 24 hours, local questions left out" "$(status '[.cameras[] | [.address, .today, .last24h]]')" '[["192.168.77.21",6,6],["fd00::21",1,1]]'
expect "names lowercased, most asked first, with first and last" "$(status '.cameras[0].names[0]')" \
    '{"name":"p2p.example.com","count":3,"first":"2026-10-17T17:46:01Z","last":"2026-10-17T17:50:44Z"}'
expect "every internet name it asked for, other cameras', old ones and local questions left out" "$(status '[.cameras[0].names[].name]')" \
    '["p2p.example.com","cloud.example.net","tcp.example.org","weird\"name\\032x.example.com"]'
expect "an IPv6 camera's lookups are matched in the log's form" "$(status '.cameras[1].names | map([.name, .count])')" '[["ntp.example.org",1]]'
expect "today is counted in the kept time zone" "$(status '[.timeZone, .todayStart, .updatedAt, .state]')" \
    '["UTC","2026-10-17T00:00:00Z","2026-10-17T18:00:00Z","ok"]'
expect "the log was read and taken away" "$(find "$root/run/camera-bridge/guard/log" -type f | wc -l | tr -d ' ')" "0"
expect "the status is for the daemon only, the history private" "$(stat -c %a "$root/run/camera-bridge/status/guard.json") $(stat -c %a "$root/srv/system/guard/history.json")" "640 600"
expect "the history keeps only watched cameras" "$(jq -c '.cameras | keys' "$root/srv/system/guard/history.json")" '["192.168.77.21","fd00::21"]'

printf 'Oct 17 17:55:00 dnsmasq[18]: query[A] p2p.example.com from 192.168.77.21\nOct 17 17:55:30 dnsmasq[18]: query[A] p2p.example.com from 192.168.77.21\n' | log_lines
guard collect
expect "a later collection adds to the history" "$(status '.cameras[0] | [.today, .names[0].count, .names[0].last]')" '[8,5,"2026-10-17T17:55:30Z"]'
if guard status | jq -e '.available == true' >/dev/null; then pass "cb-guard status prints the status"; else bad "cb-guard status prints the status"; fi

now=$(at "2026-10-18 17:00:00")
guard collect
expect "yesterday is not today, but still within 24 hours" "$(status '.cameras[0] | [.today, .last24h, (.names | length)]')" '[0,8,4]'
now=$(at "2026-10-25 18:00:00")
guard collect
expect "after 7 days a lookup is forgotten" "$(status '.cameras[0] | [.today, .last24h, (.names | length)]')" '[0,0,0]'

echo 'not json' >"$root/srv/system/guard/history.json"
printf 'Oct 25 17:59:00 dnsmasq[18]: query[A] again.example.com from 192.168.77.21\n' | log_lines
guard collect
expect "a damaged history starts again" "$(status '.cameras[0].names | map(.name)')" '["again.example.com"]'
echo '{"v": 1, "cameras": {"192.168.77.21": {"not an hour": {"n": {}, "o": 0}}}}' >"$root/srv/system/guard/history.json"
guard collect 2>/dev/null || bad "collect ran"
printf 'Oct 25 17:59:30 dnsmasq[18]: query[A] healed.example.com from 192.168.77.21\n' | log_lines
guard collect || bad "collect ran"
expect "a history it cannot read is replaced" "$(status '.cameras[0].names | map(.name)')" '["healed.example.com"]'

printf '%s\n' '{"cameras": [{"address": "fd00::21", "level": "watch"}], "timeZone": "UTC"}' >"$tmp/body.json"
guard set "$tmp/body.json" >/dev/null 2>&1
expect "a camera no longer watched is forgotten" "$(jq -c '.cameras | keys' "$root/srv/system/guard/history.json") $(status '.cameras | length')" '[] 1'

# Questions that never leave the home network (names of the local network, reverse lookups of its addresses, questions about the DNS server
# itself) are not internet lookups: neither counted nor named.
fresh '{"cameras": [{"address": "192.168.77.21", "level": "watch"}], "timeZone": "UTC"}' "2026-10-17 18:00:00"
zeros=$(printf '0.%.0s' $(seq 29))
for name in router nas.local printer.lan box.home.arpa nvr.localdomain cam.internal localhost version.bind hostname.bind id.server \
            2.77.168.192.in-addr.arpa 168.192.in-addr.arpa 5.0.16.172.in-addr.arpa 9.0.31.172.in-addr.arpa 1.0.0.10.in-addr.arpa \
            1.0.0.127.in-addr.arpa 9.9.254.169.in-addr.arpa "1.${zeros}d.f.ip6.arpa" "1.${zeros}c.f.ip6.arpa" "1.0.${zeros}8.e.f.ip6.arpa" \
            "1.0.${zeros}b.e.f.ip6.arpa" \
            8.8.8.8.in-addr.arpa 5.0.32.172.in-addr.arpa 1.0.0.11.in-addr.arpa "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa" \
            cloud.lan.example.net nas.local.example.com; do
    printf 'Oct 17 17:10:00 dnsmasq[18]: query[A] %s from 192.168.77.21\n' "$name"
done | log_lines
guard collect
expect "local questions are not internet lookups" "$(status '.cameras[0] | [.today, .last24h]')" '[6,6]'
expect "only the internet names are shown" "$(status '[.cameras[0].names[].name]')" \
    '["1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa","1.0.0.11.in-addr.arpa","5.0.32.172.in-addr.arpa","8.8.8.8.in-addr.arpa","cloud.lan.example.net","nas.local.example.com"]'

# How long each camera has been watched without a break: from when its address was put on the list (a list sent again keeps it), from when
# the history started again, and from when the DNS last started answering, whichever is latest.
fresh '{"cameras": [{"address": "192.168.77.21", "level": "watch"}], "timeZone": "UTC"}' "2026-10-17 08:00:00"
expect "a camera is watched from when it was put on the list" "$(status '[.cameras[].since]')" '["2026-10-17T08:00:00Z"]'
now=$(at "2026-10-17 09:00:00")
printf '%s\n' '{"cameras": [{"address": "192.168.77.21", "level": "watch"}, {"address": "192.168.77.22", "level": "watch", "since": 0}], "timeZone": "UTC"}' >"$tmp/body.json"
guard set "$tmp/body.json" >/dev/null 2>&1
expect "a list sent again keeps when each camera began; a new one begins now, whatever the request says" "$(status '[.cameras[].since]')" \
    '["2026-10-17T08:00:00Z","2026-10-17T09:00:00Z"]'
dns_since=$(at "2026-10-17 07:00:00")
now=$(at "2026-10-17 09:30:00")
guard collect
expect "a DNS that has run all along changes nothing" "$(status '[.running, .cameras[].since]')" '[true,"2026-10-17T08:00:00Z","2026-10-17T09:00:00Z"]'
dns_since=$(at "2026-10-17 10:00:00")
now=$(at "2026-10-17 11:00:00")
guard collect
expect "a DNS that started again restarts every camera's watch" "$(status '[.cameras[].since]')" '["2026-10-17T10:00:00Z","2026-10-17T10:00:00Z"]'
dns_since=""
printf '%s\n' '{"cameras": [{"address": "192.168.77.22", "level": "watch"}], "timeZone": "UTC"}' >"$tmp/body.json"
guard set "$tmp/body.json" >/dev/null 2>&1
printf '%s\n' '{"cameras": [{"address": "192.168.77.21", "level": "watch"}, {"address": "192.168.77.22", "level": "watch"}], "timeZone": "UTC"}' >"$tmp/body.json"
guard set "$tmp/body.json" >/dev/null 2>&1
expect "a camera taken off the list and put back begins again" "$(status '[.cameras[].since]')" '["2026-10-17T11:00:00Z","2026-10-17T09:00:00Z"]'
now=$(at "2026-10-17 12:00:00")
echo 'not json' >"$root/srv/system/guard/history.json"
guard collect
expect "when the history starts again, so does every camera's watch" "$(status '[.cameras[].since]')" '["2026-10-17T12:00:00Z","2026-10-17T12:00:00Z"]'
jq -c 'del(.cameras[].since)' "$root/srv/system/guard/cameras.json" >"$tmp/old.json" && cp "$tmp/old.json" "$root/srv/system/guard/cameras.json"
now=$(at "2026-10-17 13:00:00")
guard collect
expect "a list kept by an older version begins now" "$(status '[.cameras[].since]') $(jq -c '[.cameras[].since]' "$root/srv/system/guard/cameras.json")" \
    "[\"2026-10-17T13:00:00Z\",\"2026-10-17T13:00:00Z\"] [$now,$now]"

# What dnsmasq (a lower-privileged user) leaves where its log should be is read only when it is a plain file: a FIFO would hold the
# collector forever, a link would make root read another file.
fresh '{"cameras": [{"address": "192.168.77.21", "level": "watch"}], "timeZone": "UTC"}' "2026-10-17 18:00:00"
mkfifo "$root/run/camera-bridge/guard/log/queries.log"
if CB_GUARD_ROOT=$root CB_GUARD_NOW=$now timeout 20 bash "$GUARD" collect >/dev/null 2>&1; then pass "a FIFO in place of the log does not hold the collector"
else bad "a FIFO in place of the log does not hold the collector"; fi
expect "and it is taken away unread" "$(find "$root/run/camera-bridge/guard" -type p | wc -l | tr -d ' ') $(status '.cameras[0].today')" "0 0"
printf 'Oct 17 17:59:00 dnsmasq[18]: query[A] elsewhere.example.com from 192.168.77.21\n' >"$tmp/elsewhere.log"
ln -s "$tmp/elsewhere.log" "$root/run/camera-bridge/guard/log/queries.log"
guard collect
expect "a link in place of the log is not followed" "$(status '.cameras[0].today') $(find "$root/run/camera-bridge/guard" -type l | wc -l | tr -d ' ') $(wc -l <"$tmp/elsewhere.log" | tr -d ' ')" "0 0 1"

# Today in the bridge's time zone: 22:00 on Oct 16 in Los Angeles is 05:00 UTC on Oct 17.
fresh '{"cameras": [{"address": "192.168.77.21", "level": "watch"}], "timeZone": "America/Los_Angeles"}' "2026-10-17 05:00:00"
printf 'Oct 16 06:30:00 dnsmasq[18]: query[A] before-midnight.example.com from 192.168.77.21\nOct 17 04:00:00 dnsmasq[18]: query[A] evening.example.com from 192.168.77.21\n' | log_lines
guard collect
expect "today starts at local midnight" "$(status '[.todayStart, .cameras[0].today, .cameras[0].last24h]')" '["2026-10-16T07:00:00Z",1,2]'

# The log has no year: a line from the last second of the old year, read in the new one.
fresh '{"cameras": [{"address": "192.168.77.21", "level": "watch"}], "timeZone": "UTC"}' "2027-01-01 00:00:30"
printf 'Dec 31 23:59:50 dnsmasq[18]: query[A] new-year.example.com from 192.168.77.21\n' | log_lines
guard collect
expect "a line from last year is dated last year" "$(status '.cameras[0].names[0].last')" '"2026-12-31T23:59:50Z"'

# A camera asking for many names in one hour: the first 40 are named, every lookup is counted.
fresh '{"cameras": [{"address": "192.168.77.21", "level": "watch"}], "timeZone": "UTC"}' "2026-10-17 18:00:00"
for i in $(seq 1 60); do printf 'Oct 17 17:%02d:00 dnsmasq[18]: query[A] name%02d.example.com from 192.168.77.21\n' "$((i % 60))" "$i"; done | log_lines
guard collect
expect "at most 40 names an hour are kept, all lookups counted" "$(status '.cameras[0] | [(.names | length), .today]')" '[40,60]'

# The DNS server's configuration.
config=$(guard config)
for line in 'address=/#/' 'no-resolv' 'no-hosts' 'bind-dynamic' 'except-interface=lo' 'interface=en*' 'interface=wl*' 'log-queries' \
            "log-facility=$root/run/camera-bridge/guard/log/queries.log"; do
    if grep -qxF -- "$line" <<<"$config"; then pass "dnsmasq: $line"; else bad "dnsmasq: $line"; fi
done
if grep -Eq '^(server|listen-address|dhcp-range|interface=lo)' <<<"$config"; then bad "dnsmasq has no upstream server, fixed address or DHCP"; else pass "dnsmasq has no upstream server, fixed address or DHCP"; fi

if [ "$fail" -eq 0 ]; then echo; echo "ALL GUARD CHECKS PASSED"; else echo; echo "SOME GUARD CHECKS FAILED"; exit 1; fi
