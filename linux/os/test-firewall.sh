#!/bin/bash
# Self-test of the firewall's shape (mkosi.extra/etc/nftables.conf) and of cb-lan-prefixes (mkosi.extra/usr/lib/camera-bridge/cb-lan-prefixes, the
# box's own on-link prefixes) against a stand-in for ip. What the box offers (the web page, HomeKit, NTP, SSH, the media ports) is reached from the
# local network only, IPv6 included: the input chain accepts nothing but ICMP, DHCP answers and the hotspot's and the guard's DNS by itself, and
# jumps to the "lan" chain for local sources only. No root, no nft. Needs bash, awk, sed, sort and paste. Runs in the static checks job, which
# also parses the ruleset with nft -c. The addresses are documentation ranges.
#
#   bash linux/os/test-firewall.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RULES=$HERE/mkosi.extra/etc/nftables.conf
PREFIXES=$HERE/mkosi.extra/usr/lib/camera-bridge/cb-lan-prefixes
LIB=$HERE/mkosi.extra/usr/lib/camera-bridge/lib.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
expect() { # expect DESCRIPTION ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; fi
}

# The rules of a chain, without comments and blank lines.
chain() { sed -n "/^	chain $1 {/,/^	}/p" "$RULES" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e '/^$/d' -e '/^chain /d' -e '/^type /d' -e '/^}$/d'; }

input=$(chain input)
basics='^(iifname "lo" accept|ct state invalid drop|ct state \{ established, related \} accept|ip protocol icmp |ip6 nexthdr icmpv6 |udp dport 67 iifname "wl\*" accept|iifname "wl\*" ip saddr 10\.42\.0\.0/24 (udp|tcp) dport 53 accept|ip6? saddr @guarded[46] (udp|tcp) dport 53 meter |udp sport 67 udp dport 68 accept|udp sport 547 udp dport 546 accept)'
expect "the input chain accepts nothing but the basics by itself: the VPN goes to its own chain, its port is open, the rest jumps to lan" \
    "$(grep -Ev "$basics" <<<"$input" | tr '\n' ';')" \
    'iifname "wg-away" jump away;udp dport @away_port accept;ip saddr @lan4 jump lan;ip6 saddr @lan6 jump lan;ip saddr @onlink4 jump lan;ip6 saddr @onlink6 jump lan;'
expect "what arrives through the VPN leaves the input chain before anything else can accept it" "$(sed -n 4p <<<"$input")" 'iifname "wg-away" jump away'
expect "the away chain is exactly: ICMP, ICMPv6, the HTTPS page, drop" "$(chain away | tr '\n' ';')" \
    'ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } limit rate 20/second accept;ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request } accept;tcp dport 443 accept;drop;'
expect "the VPN's port set is empty until cb-away fills it" "$(sed -n '/set away_port {/,/}/p' "$RULES" | grep -c elements || true)" "0"
lan=$(chain lan)
# Exactly what the box offers its network, in this order, and nothing else: a rule added here must be added to this list on purpose.
expect "the lan chain is exactly: mDNS, the web page, the bridge's listeners (21090-21199), SSH when on, NTP, SADP's answers, the media ports" \
    "$(tr '\n' ';' <<<"$lan")" \
    "udp dport 5353 accept;tcp dport { 80, 443 } accept;tcp dport 21090-21199 accept;tcp dport @ssh_port ct state new limit rate 10/minute accept;udp dport 123 accept;udp sport 37020 udp dport 37020 accept;udp dport 32768-60999 accept;tcp dport 32768-60999 accept;"
# The bridge's own listeners at their defaults (the engine's BridgeSettings) are inside the range the lan chain opens for them: the webhook, the
# sensors bridge and the first camera's HomeKit accessory. (The firewall once opened only 21100-21199, so the first two were dropped.)
read -r open_low open_high < <(grep -E '^tcp dport 2[0-9]{4}-2[0-9]{4} accept$' <<<"$lan" | sed -E 's/^tcp dport ([0-9]+)-([0-9]+) accept$/\1 \2/')
CONFIG=$HERE/../../Packages/CameraBridgeKit/Sources/BridgeEngine/Configuration/Configuration.swift
for name in webhookPort sensorsBridgePort basePort; do
    value=$(sed -nE "s/^ +$name = ([0-9_]+)$/\1/p" "$CONFIG" | tr -d _ | head -1)
    if [ -n "$value" ] && [ -n "${open_low:-}" ] && [ "$value" -ge "$open_low" ] && [ "$value" -le "$open_high" ]; then
        pass "the default $name ($value) is inside the open range ${open_low:-?}-${open_high:-?}"
    else
        bad "the default $name (${value:-not found in $CONFIG}) is outside the open range ${open_low:-?}-${open_high:-?}"
    fi
done
# The ports a person can choose on the web page (linux/web/js/screens/settings.js): the webhook's and the sensors bridge's are the open range,
# the cameras' are inside it.
PAGE=$HERE/../web/js/screens/settings.js
page_range() { sed -nE "s/^export const $1 = Object\.freeze\(\{ low: ([0-9]+), high: ([0-9]+) \}\);$/\1 \2/p" "$PAGE"; }
expect "the page offers the webhook and the sensors bridge the range the firewall opens" "$(page_range OPEN_PORTS)" "${open_low:-?} ${open_high:-?}"
read -r camera_low camera_high <<<"$(page_range CAMERA_PORTS)"
if [ -n "${camera_low:-}" ] && [ -n "${open_low:-}" ] && [ "$camera_low" -ge "$open_low" ] && [ "$camera_high" -le "$open_high" ] && [ "$camera_low" -le "$camera_high" ]; then
    pass "the page's camera ports ($camera_low-$camera_high) are inside the open range"
else
    bad "the page's camera ports (${camera_low:-?}-${camera_high:-?}) are not inside the open range ${open_low:-?}-${open_high:-?}"
fi
expect "no rule accepts by a source port alone (anyone can choose a source port)" "$(sed 's/#.*//' "$RULES" | grep 'sport' | grep -Ev 'sport [0-9]+ udp dport [0-9]+ accept' || true)" ""
expect "the lan sets are the private and link-local ranges" "$(sed -n '/set lan4 {/,/}/p; /set lan6 {/,/}/p' "$RULES" | grep elements | sed 's/^[[:space:]]*//' | tr '\n' ';')" \
    "elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 };elements = { fe80::/10, fc00::/7 };"

# --- cb-lan-prefixes against a stand-in for ip ------------------------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ip" <<'STUB'
#!/bin/bash
case "$*" in
    "-4 route show table main") cat <<'R'
default via 203.0.113.1 dev eth0 proto dhcp src 203.0.113.20 metric 100
203.0.113.0/24 dev eth0 proto kernel scope link src 203.0.113.20 metric 100
192.168.7.0/24 dev wlan0 proto kernel scope link src 192.168.7.5 metric 600
10.0.0.0/8 via 192.168.7.1 dev wlan0 proto static
100.64.0.0/10 dev eth0 scope link
203.0.113.1 dev eth0 proto dhcp scope link src 203.0.113.20 metric 100
R
    ;;
    "-6 route show table main") cat <<'R'
2001:db8:5:6::/64 dev eth0 proto ra metric 1024 expires 86000sec pref medium
fe80::/64 dev eth0 proto kernel metric 256 pref medium
2001:db8::/32 dev eth0 proto static metric 1024 pref medium
2001:db8:9::/48 via fe80::1 dev eth0 proto ra metric 1024 pref medium
unreachable 2001:db8:7::/64 dev lo metric 1024 pref medium
default via fe80::1 dev eth0 proto ra metric 1024 expires 1700sec pref medium
R
    ;;
esac
STUB
chmod +x "$tmp/bin/ip"
sed -e "s#^export PATH=.*#export PATH=$tmp/bin:\$PATH#" -e "s#^\. /usr/lib/camera-bridge/lib.sh#. $LIB#" "$PREFIXES" >"$tmp/cb-lan-prefixes"
expect "the box's own on-link prefixes, never a route through a gateway, nothing broader than /16 or /48, in one transaction" \
    "$(bash "$tmp/cb-lan-prefixes" --print)" \
    "flush set inet camera_bridge onlink4
flush set inet camera_bridge onlink6
add element inet camera_bridge onlink4 { 192.168.7.0/24, 203.0.113.0/24 }
add element inet camera_bridge onlink6 { 2001:db8:5:6::/64, fe80::/64 }"
printf '#!/bin/bash\nexit 0\n' >"$tmp/bin/ip"
expect "no network: the sets are emptied" "$(bash "$tmp/cb-lan-prefixes" --print | tr '\n' ';')" "flush set inet camera_bridge onlink4;flush set inet camera_bridge onlink6;"
U=$HERE/mkosi.extra/usr/lib/systemd/system/camera-bridge-lan-prefixes.service
if grep -q '^PartOf=nftables.service$' "$U" && grep -q '^ReloadPropagatedFrom=nftables.service$' "$U" && grep -q 'camera-bridge-lan-prefixes.service' "$HERE/mkosi.postinst.chroot"; then
    pass "the prefixes are filled at boot and again whenever the firewall is loaded again"
else
    bad "the prefixes are not filled again with the firewall"
fi

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
