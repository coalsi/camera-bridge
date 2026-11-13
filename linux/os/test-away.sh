#!/bin/bash
# shellcheck disable=SC2016,SC1112
# Self-test of Away from home's root side (mkosi.extra/usr/sbin/cb-away): the check of the request, the files kept for systemd-networkd, the
# calls that make and remove the interface and fill the firewall's port set, and status/away.json. wg, ip, nft, networkctl and systemctl are
# stand-ins that record their calls in $STUB/calls; no root, no network, no systemd. Needs GNU coreutils (stat -c), bash, jq and flock: it runs
# in the static checks' container.
#
#   bash linux/os/test-away.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AWAY=$HERE/mkosi.extra/usr/sbin/cb-away
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
root=""
NOW=1794000100

pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
expect() { # expect DESCRIPTION ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; fi
}

if ! mv --help 2>&1 | grep -q -- '--no-target-directory'; then echo "skip  (needs GNU coreutils: run in the static checks' container)"; exit 0; fi
[ -x "$AWAY" ] || { bad "cb-away is missing or not executable"; exit 1; }

# Keys that look like WireGuard's: 42 base64 characters, then one that ends a 32-byte value, then "=".
mk() { printf '%42s' '' | tr ' ' "$1"; printf 'E='; }
K_BOX=$(mk C) K_BOX_PUB=$(mk D) K1=$(mk A) K2=$(mk B)
# The first of the router makers' hardware address prefixes in cb-away's list (the test follows the list, so a newer list needs no new test).
EERO_OUI=$(sed -n '/^EERO_OUIS=(/,/^)/p' "$AWAY" | grep -Eo '[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}' | head -n 1)
[ -n "$EERO_OUI" ] || bad "cb-away has no list of eero hardware address prefixes"

# --- stand-ins --------------------------------------------------------------------------------------------------------------
bin=$tmp/bin
mkdir -p "$bin"
for tool in wg ip nft networkctl systemctl; do
    printf '#!/bin/bash\necho "%s $*" >>"$STUB/calls"\n' "$tool" >"$bin/$tool"
done
cat >>"$bin/wg" <<'STUB'
case "$*" in
    genkey) echo "$K_BOX" ;;
    pubkey) cat >/dev/null; echo "$K_BOX_PUB" ;;
    "show wg-away latest-handshakes") cat "$STUB/handshakes" 2>/dev/null || true ;;
    "show wg-away endpoints") cat "$STUB/endpoints" 2>/dev/null || true ;;
    "show wg-away peers") cat "$STUB/live-peers" 2>/dev/null || true ;;
    "show wg-away listen-port") cat "$STUB/live-port" 2>/dev/null || true ;;
esac
exit 0
STUB
cat >>"$bin/ip" <<'STUB'
case "$*" in
    "link show wg-away") [ -e "$STUB/link" ] ;;
    "-4 route show default") cat "$STUB/route4" 2>/dev/null || true ;;
    "-6 route show default") cat "$STUB/route6" 2>/dev/null || true ;;
    "neigh show"*) cat "$STUB/neigh" 2>/dev/null || true ;;
    # The kernel's own delete fails while $STUB/ip-delete-fails exists; an interface set down is still there.
    "link delete dev wg-away") [ ! -e "$STUB/ip-delete-fails" ] || exit 1; rm -f "$STUB/link" "$STUB/live-peers" "$STUB/live-port" ;;
    "link set dev wg-away down") [ -e "$STUB/link" ] ;;
esac
STUB
cat >>"$bin/nft" <<'STUB'
case "$*" in
    "list set inet camera_bridge away_port")
        [ ! -e "$STUB/no-firewall" ] || exit 1
        if [ -e "$STUB/port" ]; then echo "table inet camera_bridge { set away_port { type inet_service; elements = { 51820 } } }"
        else echo "table inet camera_bridge { set away_port { type inet_service } }"; fi ;;
    # $STUB/add-fails: the firewall is there but won't take the port.
    "add element inet camera_bridge away_port { 51820 }") [ ! -e "$STUB/add-fails" ] || exit 1; touch "$STUB/port" ;;
    # $STUB/firewall-goes: the firewall's rules vanish at the next flush of the set (flushed by hand while an apply runs).
    "flush set inet camera_bridge away_port")
        if [ -e "$STUB/firewall-goes" ]; then rm -f "$STUB/firewall-goes"; touch "$STUB/no-firewall"; exit 1; fi
        rm -f "$STUB/port" ;;
esac
exit 0
STUB
cat >>"$bin/networkctl" <<'STUB'
case "$*" in
    # Like networkd: an interface that exists is not changed by a reload; a new one takes its devices and port from the netdev file.
    reload) netdev=$CB_AWAY_ROOT/run/systemd/network/50-wg-away.netdev
            if [ -e "$netdev" ] && [ ! -e "$STUB/link" ]; then
                touch "$STUB/link"
                sed -n 's/^PublicKey=//p' "$netdev" >"$STUB/live-peers"
                sed -n 's/^ListenPort=//p' "$netdev" >"$STUB/live-port"
            fi ;;
    # $STUB/delete-fails holds how many deletes still fail (they leave the interface as it is, as a networkd that cannot delete does).
    "delete wg-away") if [ -s "$STUB/delete-fails" ] && [ "$(cat "$STUB/delete-fails")" -gt 0 ]; then echo $(($(cat "$STUB/delete-fails") - 1)) >"$STUB/delete-fails"
                      else rm -f "$STUB/link" "$STUB/live-peers" "$STUB/live-port"; fi ;;
esac
exit 0
STUB
# The journal: each line cb-away logs, without logger's options.
cat >"$bin/logger" <<'STUB'
#!/bin/bash
printf '%s\n' "${*: -1}" >>"$STUB/log"
STUB
# mktemp fails for the box's key while $STUB/key-fails exists, and for the netdev file while $STUB/netdev-fails exists (a full or failing disk),
# and works as usual otherwise.
cat >"$bin/mktemp" <<'STUB'
#!/bin/bash
case "$*" in *private.key*) [ ! -e "$STUB/key-fails" ] || exit 1 ;; *50-wg-away.netdev*) [ ! -e "$STUB/netdev-fails" ] || exit 1 ;; esac
exec /usr/bin/mktemp "$@"
STUB
chmod +x "$bin"/*
export K_BOX K_BOX_PUB

away() { CB_AWAY_ROOT=$root CB_AWAY_NOW=$NOW CB_AWAY_TEST_PATH=$bin STUB=$STUB bash "$AWAY" "$@"; }
fresh() { # a new stand-in for / with its own stand-in state
    root=$(mktemp -d "$tmp/root.XXXXXX")
    STUB=$(mktemp -d "$tmp/stub.XXXXXX")
    : >"$STUB/calls"
    : >"$STUB/log"
}
# tunnel: "up" or "down" (whether wg-away is there), then how many files networkd could make it from
tunnel() { printf '%s %s' "$([ -e "$STUB/link" ] && echo up || echo down)" "$(find "$root/run/systemd/network" -type f 2>/dev/null | wc -l | tr -d ' ')"; }
logged() { grep -cF -- "$1" "$STUB/log" || true; }   # logged SENTENCE: how many journal lines hold it
removals() { grep -E '^(networkctl delete|ip link (delete|set))' "$STUB/calls" || true; }   # the ways wg-away was asked to go, in order
request() { # request FILE JSON...
    local file=$1; shift
    printf '%s\n' "$*" >"$tmp/$file"
}
# calls: the ones that change something (the stand-ins also record every look)
calls() { grep -E '^(networkctl|nft flush|nft add|systemctl) ' "$STUB/calls" || true; }
status() { jq -c "$1" "$root/run/camera-bridge/status/away.json"; }
mode() { stat -c %a "$1"; }
refused() { # refused DESCRIPTION BODY WORDS: refused with an "error: " line that holds WORDS (so a check pins its own rule)
    printf '%s\n' "$2" >"$tmp/refused.json"
    if out=$(CB_AWAY_ROOT=$tmp bash "$AWAY" check "$tmp/refused.json" 2>&1); then bad "$1 (taken: $out)"
    elif grep -q "^error: .*$3" <<<"$out"; then pass "$1"
    else bad "$1 (failed, but not with \"$3\": $out)"; fi
}
manypeers() { # manypeers N: N devices with distinct valid keys, at .2 and up
    jq -n -c --arg g "$(mk G)" --argjson n "$1" '[range(2; 2 + $n) | . as $i | {publicKey: ($g[0:40] + ("\($i)" | if length == 1 then "0" + . else . end) + "E="), address: "10.77.12.\($i)"}]'
}
peer() { printf '{"publicKey":"%s","address":"%s"}' "$1" "$2"; }

fresh
# The peers come in the wrong order on purpose: they are kept by address.
request on.json '{"on":true,"port":51820,"subnet":"10.77.12.0/24","peers":['"$(peer "$K2" 10.77.12.9),$(peer "$K1" 10.77.12.2)"']}'
request off.json '{"on": false, "peers": "anything"}'
request on2.json '{"on":true,"port":51820,"subnet":"10.77.12.0/24","peers":['"$(peer "$K2" 10.77.12.9)"']}'
request on_null.json '{"on":false,"port":51820,"subnet":null,"peers":[]}'

# --- the request ------------------------------------------------------------------------------------------------------------
expect "a request is kept in its checked form, peers by address" "$(away check "$tmp/on.json")" \
    '{"on":true,"port":51820,"subnet":"10.77.12.0/24","peers":[{"publicKey":"'"$K1"'","address":"10.77.12.2"},{"publicKey":"'"$K2"'","address":"10.77.12.9"}]}'
expect "off needs nothing else" "$(away check "$tmp/off.json")" '{"on":false}'
expect "off with every key present and no subnet is fine" "$(away check "$tmp/on_null.json")" '{"on":false}'

good='"on":true,"port":51820,"subnet":"10.77.12.0/24"'
refused "port 51821 is refused" '{"on":true,"port":51821,"subnet":"10.77.12.0/24","peers":[]}' 'port'
refused "a /16 is not a tunnel subnet" '{"on":true,"port":51820,"subnet":"10.0.0.0/16","peers":[]}' '/24'
refused "a home network is not a tunnel subnet" '{"on":true,"port":51820,"subnet":"192.168.1.0/24","peers":[]}' '/24'
refused "a leading zero is refused" '{"on":true,"port":51820,"subnet":"10.077.12.0/24","peers":[]}' '/24'
refused "nft syntax after the subnet is refused" '{"on":true,"port":51820,"subnet":"10.77.12.0/24; flush ruleset","peers":[]}' '/24'
refused "the setup hotspot's network is refused" '{"on":true,"port":51820,"subnet":"10.42.5.0/24","peers":[]}' 'reserved'
refused "10.255 is refused" '{"on":true,"port":51820,"subnet":"10.255.5.0/24","peers":[]}' 'reserved'
refused "an octet over 255 is refused" '{"on":true,"port":51820,"subnet":"10.77.256.0/24","peers":[]}' '/24'
refused "a peer in another subnet is refused" "{$good,\"peers\":[$(peer "$K1" 10.77.13.2)]}" 'not an address in the subnet'
refused "a peer at .1 (the box) is refused" "{$good,\"peers\":[$(peer "$K1" 10.77.12.1)]}" 'takes .2 to .254'
refused "a peer at .255 is refused" "{$good,\"peers\":[$(peer "$K1" 10.77.12.255)]}" 'takes .2 to .254'
refused "a peer at .0 is refused" "{$good,\"peers\":[$(peer "$K1" 10.77.12.0)]}" 'takes .2 to .254'
refused "a peer address with a leading zero is refused" "{$good,\"peers\":[$(peer "$K1" 10.77.12.02)]}" 'not an address in the subnet'
refused "two peers at one address are refused" "{$good,\"peers\":[$(peer "$K1" 10.77.12.2),$(peer "$K2" 10.77.12.2)]}" 'one address'
refused "one key twice is refused" "{$good,\"peers\":[$(peer "$K1" 10.77.12.2),$(peer "$K1" 10.77.12.3)]}" 'listed twice'
refused "a key of 43 characters is refused" "{$good,\"peers\":[$(peer "${K1%=}" 10.77.12.2)]}" 'public key'
refused "a key that is not the one way base64 writes 32 bytes is refused" "{$good,\"peers\":[$(peer "$(mk A | sed 's/E=$/F=/')" 10.77.12.2)]}" 'public key'
refused "a key holding a newline and [Peer] is refused" "{$good,\"peers\":[{\"publicKey\":\"$K1\\n[Peer]\\nPublicKey=$K2\",\"address\":\"10.77.12.2\"}]}" 'public key'
refused "a peer without a key is refused" "{$good,\"peers\":[{\"address\":\"10.77.12.2\"}]}" 'public key'
refused "a peer that is not an object is refused" "{$good,\"peers\":[\"10.77.12.2\"]}" 'not a JSON object'
refused "65 peers are too many" "{$good,\"peers\":$(manypeers 65)}" 'at most 64'
refused "peers that is not a list is refused" "{$good,\"peers\":\"none\"}" 'list of devices'
refused "on that is not a boolean is refused" '{"on":"true","port":51820,"subnet":"10.77.12.0/24","peers":[]}' '"on" must'
refused "a body that is not JSON is refused" 'on=true' 'not JSON'
refused "a body that is not an object is refused" '[1,2]' 'not a JSON object'
refused "two valid requests in one file are refused" "$(printf '%s\n%s' "$(away check "$tmp/on.json")" "$(away check "$tmp/on2.json")")" 'exactly one JSON value, not 2'
refused "a refused value in front of a good request is refused" "$(printf '"anything"\n%s' "$(away check "$tmp/on.json")")" 'exactly one JSON value, not 2'
refused "an empty file is refused" '' 'exactly one JSON value, not 0'
# 64 peers are fine.
many=$(manypeers 64)
printf '{%s,"peers":%s}\n' "$good" "$many" >"$tmp/many.json"
expect "64 peers are fine" "$(CB_AWAY_ROOT=$tmp bash "$AWAY" check "$tmp/many.json" | jq '.peers | length')" "64"

# --- on ---------------------------------------------------------------------------------------------------------------------
fresh
away set "$tmp/on.json" >/dev/null 2>&1 || bad "set on.json succeeded"
state=$root/srv/system/away
netd=$root/run/systemd/network
expect "the kept request and the box's key are private to root" "$(mode "$state/state.json") $(mode "$state/private.key")" "600 600"
expect "the kept request is the checked form" "$(cat "$state/state.json")" "$(away check "$tmp/on.json")"
expect "the box's key is the one wg made" "$(cat "$state/private.key")" "$K_BOX"
expect "the netdev holds the key, so only root and networkd read it" "$(mode "$netd/50-wg-away.netdev") $(mode "$netd/50-wg-away.network")" "640 644"
netdev=$(cat "$netd/50-wg-away.netdev")
for line in "Name=wg-away" "Kind=wireguard" "MTUBytes=1280" "PrivateKey=$K_BOX" "ListenPort=51820" "PublicKey=$K1" "AllowedIPs=10.77.12.2/32" \
            "PublicKey=$K2" "AllowedIPs=10.77.12.9/32"; do
    if grep -qxF "$line" <<<"$netdev"; then pass "the netdev has ${line//"$K_BOX"/<box key>}"; else bad "the netdev has $line"; fi
done
expect "the netdev has one block per device" "$(grep -c '^\[WireGuardPeer\]$' <<<"$netdev")" "2"
network=$(cat "$netd/50-wg-away.network")
for line in "Name=wg-away" "Address=10.77.12.1/24" "LinkLocalAddressing=no" "IPv6AcceptRA=no" "RequiredForOnline=no"; do
    if grep -qxF "$line" <<<"$network"; then pass "the network file has $line"; else bad "the network file has $line"; fi
done
expect "set makes the interface, fills the port and starts the status timer, in that order" "$(calls)" \
'networkctl reload
nft flush set inet camera_bridge away_port
nft add element inet camera_bridge away_port { 51820 }
systemctl start --no-block camera-bridge-away-status.timer'
expect "the status is for the daemon only" "$(mode "$root/run/camera-bridge/status/away.json")" "640"
expect "the status says ok, with the box's public key and every device not yet seen" "$(status .)" \
    "$(jq -n -c --arg pub "$K_BOX_PUB" --arg k1 "$K1" --arg k2 "$K2" --argjson now "$NOW" \
        '{state: "ok", message: null, publicKey: $pub, port: 51820, router: null,
          peers: [{publicKey: $k1, latestHandshake: 0, endpoint: null}, {publicKey: $k2, latestHandshake: 0, endpoint: null}], updated: $now}')"
expect "the box's private key is in no status and no call" "$(cat "$root/run/camera-bridge/status/away.json" "$STUB/calls" | grep -cF "$K_BOX" || true)" "0"

# --- the same request again, and another list ----------------------------------------------------------------------------------
: >"$STUB/calls"
key_before=$(cat "$state/private.key")
inode_before=$(stat -c %i "$state/private.key")
away set "$tmp/on.json" >/dev/null 2>&1 || bad "the same request again succeeded"
expect "the same request again deletes nothing" "$(grep -c 'networkctl delete' "$STUB/calls" || true)" "0"
expect "and keeps the key" "$(cat "$state/private.key") $(stat -c %i "$state/private.key")" "$key_before $inode_before"
: >"$STUB/calls"
away set "$tmp/on2.json" >/dev/null 2>&1 || bad "another list succeeded"
expect "another list of devices makes the interface again" "$(calls | head -2)" 'networkctl delete wg-away
networkctl reload'
expect "and the netdev holds the one device left" "$(grep -c '^PublicKey=' "$netd/50-wg-away.netdev") $(grep -c "^PublicKey=$K2\$" "$netd/50-wg-away.netdev")" "1 1"
expect "the key is unchanged by it" "$(cat "$state/private.key")" "$K_BOX"
away set "$tmp/on.json" >/dev/null 2>&1

# --- refresh ----------------------------------------------------------------------------------------------------------------
printf '%s\t1794000000\n%s\t0\n' "$K1" "$K2" >"$STUB/handshakes"
printf '%s\t[2001:db8:77::5]:41000\n%s\t(none)\n' "$K1" "$K2" >"$STUB/endpoints"
away refresh >/dev/null 2>&1 || bad "refresh succeeded"
expect "refresh reads handshakes and endpoints, without the port" "$(status '.peers')" \
    "$(jq -n -c --arg k1 "$K1" --arg k2 "$K2" '[{publicKey: $k1, latestHandshake: 1794000000, endpoint: "2001:db8:77::5"}, {publicKey: $k2, latestHandshake: 0, endpoint: null}]')"
printf '%s\t192.0.2.9:51000\n%s\t(none)\n' "$K1" "$K2" >"$STUB/endpoints"
away refresh >/dev/null 2>&1
expect "an IPv4 endpoint loses its port too" "$(status '.peers[0].endpoint')" '"192.0.2.9"'
expect "refresh keeps the interface and the port as they are" "$(status '.state')" '"ok"'

neigh() { printf '192.0.2.1 dev eth0 lladdr %s REACHABLE\n' "$1" >"$STUB/neigh"; }
printf 'default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.50 metric 100\n' >"$STUB/route4"
neigh "$EERO_OUI:01:02:03"
away refresh >/dev/null 2>&1
expect "the router is an eero by its hardware address" "$(status '.router')" '"eero"'
neigh "52:55:0a:00:02:02"
away refresh >/dev/null 2>&1
expect "another maker's router is none" "$(status '.router')" 'null'
: >"$STUB/route4"
printf 'default via fe80::1 dev eth0 proto ra metric 1024\n' >"$STUB/route6"
printf 'fe80::1 dev eth0 lladdr %s:04:05:06 router REACHABLE\n' "$EERO_OUI" >"$STUB/neigh"
away refresh >/dev/null 2>&1
expect "with no IPv4 default route the IPv6 one is asked" "$(status '.router')" '"eero"'
: >"$STUB/route6"
away refresh >/dev/null 2>&1
expect "no default route is no router" "$(status '.router')" 'null'

rm -f "$STUB/link"
away refresh >/dev/null 2>&1 || bad "refresh ran without the interface"
expect "a missing interface is a failure" "$(status '[.state, .message]')" '["failed","The VPN interface isn’t up."]'
touch "$STUB/link"
rm -f "$STUB/port"
away refresh >/dev/null 2>&1 || bad "refresh ran without the port"
expect "a missing port is a failure" "$(status '[.state, .message]')" '["failed","The firewall doesn’t let the VPN’s port in."]'
touch "$STUB/port"
away refresh >/dev/null 2>&1
expect "and it is ok again when both are back" "$(status '[.state, .message]')" '["ok",null]'

# A failure that lasts is logged when it starts and when its sentence changes, not at every run of the 30 s status timer.
: >"$STUB/log"
rm -f "$STUB/port"
for _ in 1 2 3; do away refresh >/dev/null 2>&1; done
rm -f "$STUB/link"
for _ in 1 2; do away refresh >/dev/null 2>&1; done
expect "three refreshes of one failure log it once, and another sentence is logged once too" \
    "$(logged 'The firewall doesn’t let the VPN’s port in.') $(logged 'The VPN interface isn’t up.')" "1 1"
touch "$STUB/link" "$STUB/port"
away refresh >/dev/null 2>&1
rm -f "$STUB/port"
away refresh >/dev/null 2>&1
expect "after it worked again, the same failure is logged again" "$(status .state) $(logged 'The firewall doesn’t let the VPN’s port in.')" '"failed" 2'
touch "$STUB/port"
away refresh >/dev/null 2>&1

# --- a tunnel that does not hold the kept devices -----------------------------------------------------------------------------
fresh
away set "$tmp/on.json" >/dev/null 2>&1
printf '%s\n' "$K1" >"$STUB/live-peers"
away refresh >/dev/null 2>&1
expect "an interface that lacks a kept device is a failure" "$(status '[.state, .message]')" '["failed","The VPN interface doesn’t hold the paired devices."]'
printf '%s\n%s\n%s\n' "$K2" "$K1" "$(mk H)" >"$STUB/live-peers"
away refresh >/dev/null 2>&1
expect "and so is one that still holds a device that was removed" "$(status .state)" '"failed"'
printf '%s\n%s\n' "$K2" "$K1" >"$STUB/live-peers"
away refresh >/dev/null 2>&1
expect "the devices in any order are fine" "$(status .state)" '"ok"'
echo 51821 >"$STUB/live-port"
away refresh >/dev/null 2>&1
expect "another listen port is a failure" "$(status .state)" '"failed"'
fresh
away set "$tmp/on.json" >/dev/null 2>&1
echo 1 >"$STUB/delete-fails"
if CB_AWAY_WAIT_STEPS=2 away set "$tmp/on2.json" >/dev/null 2>&1; then bad "set exits 1 when networkd keeps the old devices"; else pass "set exits 1 when networkd keeps the old devices"; fi
expect "and the status says the interface does not hold the devices" "$(status '[.state, .message]')" '["failed","The VPN interface doesn’t hold the paired devices."]'
# A removed device's key must stop working even though a step failed: the interface goes, and the request and key stay.
expect "and the interface is taken down, with the files networkd would make it from" "$([ -e "$STUB/link" ] && echo up || echo down) $(find "$root/run/systemd/network" -type f | wc -l | tr -d ' ') $([ -s "$STUB/live-peers" ] && echo peers || echo none)" "down 0 none"
expect "and the request and the key stay" "$(jq -c '.peers | length' "$root/srv/system/away/state.json") $(cat "$root/srv/system/away/private.key")" "1 $K_BOX"
expect "and the port stays closed" "$([ -e "$STUB/port" ] && echo open || echo closed)" "closed"

# The same when the new netdev cannot be written: the old one (with the removed device) must not go on running.
fresh
away set "$tmp/on.json" >/dev/null 2>&1
touch "$STUB/netdev-fails"
if away set "$tmp/on2.json" >/dev/null 2>&1; then bad "set exits 1 when the netdev cannot be written"; else pass "set exits 1 when the netdev cannot be written"; fi
expect "a netdev that cannot be written takes the interface down, and says so" "$([ -e "$STUB/link" ] && echo up || echo down) $(find "$root/run/systemd/network" -type f | wc -l | tr -d ' ') $(status '[.state, .message]')" \
    'down 0 ["failed","The VPN’s settings could not be written."]'
expect "and the request and the key stay" "$(jq -c '.peers | length' "$root/srv/system/away/state.json") $(cat "$root/srv/system/away/private.key")" "1 $K_BOX"
rm -f "$STUB/netdev-fails"
away apply >/dev/null 2>&1 || bad "apply after the disk works again succeeded"
expect "the next apply brings back the kept devices" "$(cat "$STUB/live-peers") $(status .state)" "$K2 \"ok\""

# --- the firewall goes away while the tunnel runs -----------------------------------------------------------------------------
fresh
away set "$tmp/on.json" >/dev/null 2>&1
touch "$STUB/no-firewall"
away set "$tmp/on2.json" >/dev/null 2>&1 && bad "set without the firewall exits 1"
expect "a running interface goes down when the firewall is missing" "$([ -e "$STUB/link" ] && echo up || echo down) $(find "$root/run/systemd/network" -type f | wc -l | tr -d ' ')" "down 0"
expect "and the request and key stay for the next apply" "$(jq -c '.peers | length' "$root/srv/system/away/state.json") $(cat "$root/srv/system/away/private.key")" "1 $K_BOX"
rm -f "$STUB/no-firewall"
away apply >/dev/null 2>&1 || bad "apply with the firewall back succeeded"
expect "the next apply brings it back" "$([ -e "$STUB/link" ] && echo up) $(status .state)" 'up "ok"'

# The firewall is gone some other way (flushed, or nftables stopped or started by hand outside camera-bridge-away.service): the status
# timer's next refresh takes the tunnel down with it and says why. The request and the key stay for the next apply.
fresh
away set "$tmp/on.json" >/dev/null 2>&1
touch "$STUB/no-firewall"
: >"$STUB/calls"
away refresh >/dev/null 2>&1 || bad "refresh without the firewall exits 0"
expect "a refresh without the firewall takes the interface down, with the files networkd would make it from" "$(tunnel)" "down 0"
expect "and names the firewall" "$(status '[.state, .message]')" '["failed","The firewall isn’t loaded, so Away from home can’t open its port."]'
expect "and keeps the request and the key" "$(jq -c '.peers | length' "$root/srv/system/away/state.json") $(cat "$root/srv/system/away/private.key")" "2 $K_BOX"
: >"$STUB/calls"
away refresh >/dev/null 2>&1
expect "the next refresh still names the firewall, and has nothing left to take down" "$(status .message) $(grep -c '^networkctl' "$STUB/calls" || true)" \
    '"The firewall isn’t loaded, so Away from home can’t open its port." 0'
rm -f "$STUB/no-firewall"
away apply >/dev/null 2>&1 || bad "apply with the firewall back succeeded"
expect "with the firewall back, the next apply brings the tunnel back" "$(tunnel) $(status .state)" 'up 2 "ok"'

# The firewall's rules vanish while an apply makes the interface: the interface goes with them.
fresh
touch "$STUB/firewall-goes"
if away set "$tmp/on.json" >/dev/null 2>&1; then bad "set exits 1 when the firewall goes while the interface is made"; else pass "set exits 1 when the firewall goes while the interface is made"; fi
expect "the interface goes with the firewall, and the status names it" "$(tunnel) $(status '[.state, .message]')" \
    'down 0 ["failed","The firewall isn’t loaded, so Away from home can’t open its port."]'
# The firewall is there but won't take the port: the interface stays, since the chain `away` still keeps it to the HTTPS page.
fresh
touch "$STUB/add-fails"
if away set "$tmp/on.json" >/dev/null 2>&1; then bad "set exits 1 when the firewall won't take the port"; else pass "set exits 1 when the firewall won't take the port"; fi
expect "a firewall that won't take the port leaves the interface up, and the status says so" "$(tunnel) $(status '[.state, .message]')" \
    'up 2 ["failed","The firewall wouldn’t take the VPN’s port."]'

# --- down -------------------------------------------------------------------------------------------------------------------
# A stop or restart of nftables.service stops camera-bridge-away.service first (PartOf=, and it starts after nftables.service), so down
# runs while the rules are still loaded, and nftables' own stop flushes them afterwards.
fresh
away set "$tmp/on.json" >/dev/null 2>&1
: >"$STUB/calls"
away down >/dev/null 2>&1 || bad "down succeeded"
expect "down takes the interface down and closes the port" "$(calls)" 'networkctl delete wg-away
networkctl reload
nft flush set inet camera_bridge away_port'
expect "and leaves no interface and no file for networkd" "$(tunnel)" "down 0"
expect "the request and the key stay for the next start" "$(jq -c '.peers | length' "$root/srv/system/away/state.json") $(cat "$root/srv/system/away/private.key")" "2 $K_BOX"
expect "the status is failed: the interface is down while the firewall is still there" "$(status '[.state, .message]')" '["failed","The VPN interface isn’t up."]'
touch "$STUB/no-firewall"
away refresh >/dev/null 2>&1
expect "once nftables has flushed its rules, the status names the firewall" "$(status '[.state, .message]')" '["failed","The firewall isn’t loaded, so Away from home can’t open its port."]'
rm -f "$STUB/no-firewall"
away apply >/dev/null 2>&1 || bad "apply after down succeeded"
expect "the next apply brings the tunnel back with the same devices and key" "$([ -e "$STUB/link" ] && echo up) $(status .state) $(cat "$root/srv/system/away/private.key")" "up \"ok\" $K_BOX"
away set "$tmp/off.json" >/dev/null 2>&1
away down >/dev/null 2>&1 || bad "down with Away from home off succeeded"
expect "down with Away from home off leaves it off" "$(status .state)" '"off"'

# Neither networkd nor the kernel removes the interface: it is set down, which closes WireGuard's socket, and down fails and says so.
fresh
away set "$tmp/on.json" >/dev/null 2>&1
echo 99 >"$STUB/delete-fails"
touch "$STUB/ip-delete-fails"
: >"$STUB/calls"
if away down >/dev/null 2>&1; then bad "down exits 1 while wg-away is still there"; else pass "down exits 1 while wg-away is still there"; fi
expect "networkd is asked, then the kernel, then the interface is set down" "$(removals)" 'networkctl delete wg-away
ip link delete dev wg-away
ip link set dev wg-away down'
expect "the status says the interface couldn't be removed, and the port is closed" "$(status '[.state, .message]') $([ -e "$STUB/port" ] && echo open || echo closed)" \
    '["failed","The VPN interface couldn’t be removed."] closed'

# --- writes that fail ---------------------------------------------------------------------------------------------------------
fresh
touch "$STUB/key-fails"
if away set "$tmp/on.json" >/dev/null 2>&1; then bad "set exits 1 when the key cannot be kept"; else pass "set exits 1 when the key cannot be kept"; fi
expect "and says so, with no key in the status" "$(status '[.state, .publicKey]')" '["failed",null]'
expect "and no interface was made" "$([ -e "$STUB/link" ] && echo up || echo none)" "none"

# --- apply (at boot) ----------------------------------------------------------------------------------------------------------
fresh
away set "$tmp/on.json" >/dev/null 2>&1
rm -f "$STUB/link" "$STUB/port"
: >"$STUB/calls"
away apply >/dev/null 2>&1 || bad "apply ran"
expect "apply makes the kept state again" "$([ -e "$STUB/link" ] && [ -e "$STUB/port" ] && echo yes) $(status .state)" "yes \"ok\""
expect "apply on a netdev that is already right deletes nothing" "$(grep -c 'networkctl delete' "$STUB/calls" || true)" "0"

# --- without the firewall -----------------------------------------------------------------------------------------------------
fresh
touch "$STUB/no-firewall"
if away set "$tmp/on.json" >/dev/null 2>&1; then bad "set without the firewall failed"; else pass "set without the firewall exits 1"; fi
expect "and says why" "$(status '[.state, .message]')" '["failed","The firewall isn’t loaded, so Away from home can’t open its port."]'
expect "the request is kept for the next boot" "$(cat "$root/srv/system/away/state.json")" "$(away check "$tmp/on.json")"
if away apply >/dev/null 2>&1; then pass "apply without the firewall exits 0"; else bad "apply without the firewall exits 0"; fi
expect "and still says why" "$(status '.state')" '"failed"'

# --- off --------------------------------------------------------------------------------------------------------------------
fresh
away set "$tmp/on.json" >/dev/null 2>&1
: >"$STUB/calls"
away set "$tmp/off.json" >/dev/null 2>&1 || bad "set off.json succeeded"
expect "off stops the timer, removes the interface and closes the port" "$(calls)" \
'systemctl stop camera-bridge-away-status.timer
networkctl delete wg-away
networkctl reload
nft flush set inet camera_bridge away_port'
expect "off removes everything kept" "$(find "$root/run/systemd/network" "$root/srv/system/away" -type f | wc -l | tr -d ' ')" "0"
expect "and the interface and the port are gone" "$([ -e "$STUB/link" ] || [ -e "$STUB/port" ] || echo gone)" "gone"
expect "the status is off, with no key and no devices" "$(status '[.state, .publicKey, .peers, .router, .port]')" '["off",null,[],null,51820]'
: >"$STUB/calls"
away set "$tmp/off.json" >/dev/null 2>&1 || bad "off again succeeded"
pass "off is idempotent"
expect "off again, with nothing left, runs no networkctl" "$(grep -c '^networkctl' "$STUB/calls" || true)" "0"
expect "cb-away status prints the status" "$(away status | jq -c .state)" '"off"'

# networkd can't delete the interface, but the kernel can: off is done.
fresh
away set "$tmp/on.json" >/dev/null 2>&1
echo 99 >"$STUB/delete-fails"
: >"$STUB/calls"
away set "$tmp/off.json" >/dev/null 2>&1 || bad "off succeeded when the kernel removed what networkd didn't"
expect "the kernel's own delete removed it, and it is off" "$(removals | tail -n 1) $(tunnel) $(status '[.state, .message]')" 'ip link delete dev wg-away down 0 ["off",null]'

# Every delete fails: networkd's and the kernel's. A device with a session would keep it (the firewall lets established traffic in before it
# looks at the emptied port set), so the interface is set down, and off fails and says so instead of passing for off.
fresh
away set "$tmp/on.json" >/dev/null 2>&1
echo 99 >"$STUB/delete-fails"
touch "$STUB/ip-delete-fails"
: >"$STUB/calls"
if away set "$tmp/off.json" >/dev/null 2>&1; then bad "off exits 1 while wg-away is still there"; else pass "off exits 1 while wg-away is still there"; fi
expect "networkd is asked, then the kernel, then the interface is set down" "$(removals)" 'networkctl delete wg-away
ip link delete dev wg-away
ip link set dev wg-away down'
expect "the status is failed, not off" "$(status '[.state, .message, .publicKey, .peers]')" '["failed","The VPN interface couldn’t be removed.",null,[]]'
expect "the port is closed and what was kept is gone all the same" "$([ -e "$STUB/port" ] && echo open || echo closed) $(find "$root/srv/system/away" -type f | wc -l | tr -d ' ')" "closed 0"
away refresh >/dev/null 2>&1 || bad "refresh while off exits 0"
away refresh >/dev/null 2>&1
expect "a refresh keeps saying failed while wg-away is there, and the failure is logged once" "$(status .state) $(logged 'The VPN interface couldn’t be removed.')" '"failed" 1'
rm -f "$STUB/link"
away refresh >/dev/null 2>&1
expect "once wg-away is gone, a refresh says off" "$(status '[.state, .message]')" '["off",null]'

# --- apply with nothing, or something damaged --------------------------------------------------------------------------------
fresh
if away apply >/dev/null 2>&1; then pass "apply with nothing kept exits 0"; else bad "apply with nothing kept exits 0"; fi
expect "and is off" "$(status .state)" '"off"'
expect "with neither the files nor the interface there (every boot and firewall reload while off), no networkctl is run" "$(grep -c '^networkctl' "$STUB/calls" || true)" "0"
mkdir -p "$root/srv/system/away"
echo 'not json' >"$root/srv/system/away/state.json"
echo "$K_BOX" >"$root/srv/system/away/private.key"
if away apply >/dev/null 2>&1; then pass "apply with a damaged state.json exits 0"; else bad "apply with a damaged state.json exits 0"; fi
expect "and is off, with the damaged files gone" "$(status .state) $(find "$root/srv/system/away" -type f | wc -l | tr -d ' ')" '"off" 0'
fresh
expect "status with no status file is the off document" "$(away status | jq -c '[.state, .peers, .updated]')" "[\"off\",[],$NOW]"

[ "$fail" -eq 0 ] && echo "ALL AWAY CHECKS PASSED"
exit "$fail"
