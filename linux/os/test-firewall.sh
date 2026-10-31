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
expect "the input chain accepts nothing but the basics by itself, and jumps to the lan chain for local sources only" \
    "$(grep -Ev "$basics" <<<"$input" | tr '\n' ';')" "ip saddr @lan4 jump lan;ip6 saddr @lan6 jump lan;ip saddr @onlink4 jump lan;ip6 saddr @onlink6 jump lan;"
lan=$(chain lan)
for rule in "udp dport 5353 accept" "tcp dport { 80, 443 } accept" "tcp dport 21100-21199 accept" "tcp dport @ssh_port ct state new limit rate 10/minute accept" \
            "udp dport 123 accept" "udp sport 37020 udp dport 37020 accept" "udp dport 32768-60999 accept" "tcp dport 32768-60999 accept"; do
    if grep -qxF "$rule" <<<"$lan"; then pass "the lan chain has: $rule"; else bad "the lan chain lacks: $rule"; fi
done
expect "the lan chain only accepts" "$(grep -cv ' accept$' <<<"$lan" || true)" "0"
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
