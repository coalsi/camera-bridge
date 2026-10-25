#!/bin/bash
# Self-test of the box's 5 GHz preference (mkosi.extra/usr/lib/camera-bridge/cb-wifi-pick and the part of mkosi.extra/usr/sbin/cb-wifi that uses it): the
# choice of an access point from a list (a pure filter), the parsing of `iw ... scan dump`, and cb-wifi against stand-ins for nmcli, iw and ip. No root,
# no radio, no NetworkManager. The network names and addresses are made up. Needs bash, jq, awk and sed. Runs in the static checks job.
#
#   bash linux/os/test-wifi.sh
# shellcheck disable=SC2016
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PICK=$HERE/mkosi.extra/usr/lib/camera-bridge/cb-wifi-pick
WIFI=$HERE/mkosi.extra/usr/sbin/cb-wifi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
expect() { # expect DESCRIPTION ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; fi
}

[ -x "$PICK" ] || bad "cb-wifi-pick is missing or not executable"

# --- the band of a frequency ---------------------------------------------------------------------------------------------
band() { bash "$PICK" --band "$1"; }
expect "2412 MHz is 2.4 GHz" "$(band 2412)" "2.4 GHz"
expect "2462 MHz is 2.4 GHz" "$(band 2462)" "2.4 GHz"
expect "5180 MHz is 5 GHz" "$(band 5180)" "5 GHz"
expect "5745 MHz is 5 GHz" "$(band 5745)" "5 GHz"
expect "5955 MHz is 6 GHz" "$(band 5955)" "6 GHz"
expect "6415 MHz is 6 GHz" "$(band 6415)" "6 GHz"
expect "0 MHz (not joined) is nothing" "$(band 0)" ""
expect "3000 MHz is nothing" "$(band 3000)" ""
expect "a word is nothing" "$(band wifi)" ""

# --- the scan dump -----------------------------------------------------------------------------------------------------------
cat >"$tmp/scan.txt" <<'DUMP'
BSS 02:00:5e:10:00:01(on wlan0) -- associated
	last seen: 1234.567s [boottime]
	TSF: 123456789 usec (0d, 00:02:03)
	freq: 2437.0
	beacon interval: 100 TUs
	capability: ESS Privacy ShortSlotTime (0x0411)
	signal: -52.00 dBm
	last seen: 12 ms ago
	SSID: Maple Cottage
	Supported rates: 1.0* 2.0* 5.5* 11.0* 6.0 9.0 12.0 18.0
BSS 02:00:5e:10:00:02(on wlan0)
	TSF: 123456789 usec (0d, 00:02:03)
	freq: 5180
	beacon interval: 100 TUs
	signal: -61.00 dBm
	SSID: Maple Cottage
BSS 02:00:5e:10:00:03(on wlan0)
	freq: 5745
	signal: -49.50 dBm
	SSID: Neighbour 5G
BSS 02:00:5e:10:00:04(on wlan0)
	freq: 2412
	signal: -80.00 dBm
	SSID:
DUMP
expect "the scan dump becomes one line per access point" "$(bash "$PICK" --parse <"$tmp/scan.txt" | tr '\t' '|')" \
"02:00:5e:10:00:01|2437|-52|Maple Cottage
02:00:5e:10:00:02|5180|-61|Maple Cottage
02:00:5e:10:00:03|5745|-49|Neighbour 5G
02:00:5e:10:00:04|2412|-80|"
expect "an empty dump is an empty list" "$(printf '' | bash "$PICK" --parse)" ""

# --- the choice ----------------------------------------------------------------------------------------------------------------
pick() { # pick LIST SSID BSSID MHZ [MIN_DBM]: LIST is lines "bssid|mhz|dbm|name"
    printf '%s\n' "$1" | tr '|' '\t' | CB_WIFI_MIN_DBM=${5:--70} bash "$PICK" --pick "$2" "$3" "$4"
}
A=02:00:5e:20:00:01   # the 2.4 GHz radio the box is on
B=02:00:5e:20:00:02   # the same network on 5 GHz
C=02:00:5e:20:00:03   # the same network on 5 GHz, further away
D=02:00:5e:20:00:04   # the same network on 6 GHz
N="Maple Cottage"
base="$A|2437|-50|$N"
expect "on 2.4 GHz, a 5 GHz access point of the network that is strong enough is chosen" "$(pick "$base
$B|5180|-62|$N" "$N" $A 2437)" "$B"
expect "the strongest of several is chosen" "$(pick "$base
$C|5200|-68|$N
$B|5180|-62|$N" "$N" $A 2437)" "$B"
expect "-70 dBm is strong enough" "$(pick "$base
$B|5180|-70|$N" "$N" $A 2437)" "$B"
expect "-71 dBm is not" "$(pick "$base
$B|5180|-71|$N" "$N" $A 2437)" ""
expect "a limit can be set" "$(pick "$base
$B|5180|-75|$N" "$N" $A 2437 -80)" "$B"
expect "a 6 GHz access point counts too, when it is the strongest" "$(pick "$base
$B|5180|-62|$N
$D|5955|-55|$N" "$N" $A 2437)" "$D"
expect "another network's 5 GHz access point is never chosen" "$(pick "$base
$B|5180|-40|Neighbour 5G" "$N" $A 2437)" ""
expect "a name that only starts like the network's is not it" "$(pick "$base
$B|5180|-40|Maple Cottage 5G" "$N" $A 2437)" ""
expect "another 2.4 GHz access point of the network is not a move" "$(pick "$base
$C|2462|-40|$N" "$N" $A 2437)" ""
expect "on 5 GHz already, nothing moves" "$(pick "$A|5240|-50|$N
$B|5180|-40|$N" "$N" $A 5240)" ""
expect "not joined (0 MHz), nothing moves" "$(pick "$B|5180|-40|$N" "$N" "" 0)" ""
expect "no network name, nothing moves" "$(pick "$B|5180|-40|" "" $A 2437)" ""
expect "an empty list chooses nothing" "$(pick "" "$N" $A 2437)" ""
expect "a name with a colon and a space is compared whole" "$(pick "$base
$B|5180|-60|Cafe: Upstairs" "Cafe: Upstairs" $A 2437)" "$B"

# --- cb-wifi against stand-ins -----------------------------------------------------------------------------------------------
# A copy of cb-wifi that needs no root and finds its helpers next to the repository's files.
sed -e "s#/usr/lib/camera-bridge/#$HERE/mkosi.extra/usr/lib/camera-bridge/#g" -e 's/^\[ "\$(id -u)" -eq 0 \].*$/true/' -e "s#/usr/sbin/cb-guard#true#g" -e "s#^export PATH=.*#export PATH=$tmp/bin:\$PATH#" "$WIFI" >"$tmp/cb-wifi"
mkdir -p "$tmp/bin" "$tmp/run"
for tool in sleep logger systemctl; do printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/$tool"; done
cat >"$tmp/bin/ip" <<'STUB'
#!/bin/sh
case "$*" in
    "-4 route show default") echo "default via 192.168.77.1 dev ${CB_TEST_ROUTE_DEV:-wlan0} proto dhcp" ;;
esac
STUB
cat >"$tmp/bin/iw" <<'STUB'
#!/bin/sh
# iw dev wlan0 link | iw dev wlan0 scan dump, from the files the test writes
case "$*" in
    "dev wlan0 link")
        printf 'Connected to %s (on wlan0)\n\tSSID: %s\n\tfreq: %s\n\tsignal: -50 dBm\n' "$(cat "$CB_TEST_DIR/bssid")" "Maple Cottage" "$(cat "$CB_TEST_DIR/freq")" ;;
    "dev wlan0 scan dump") cat "$CB_TEST_DIR/scan" ;;
esac
STUB
cat >"$tmp/bin/nmcli" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$CB_TEST_DIR/nmcli.log"
case "$*" in
    "-t -f DEVICE,TYPE device status") echo "wlan0:wifi" ;;
    "-t -f GENERAL.CONNECTION device show wlan0") echo "GENERAL.CONNECTION:Maple Cottage" ;;
    "connection up id Maple Cottage ifname wlan0 ap "*)
        [ -z "${CB_TEST_FAIL_AP:-}" ] || exit 4
        echo 5180 >"$CB_TEST_DIR/freq" ;;
esac
exit 0
STUB
chmod +x "$tmp"/bin/*
scan() { # scan BSS...: writes the stand-in scan dump; each argument "bssid|mhz|dbm|name"
    : >"$tmp/run/scan"
    local line bssid mhz dbm name
    for line in "$@"; do
        IFS='|' read -r bssid mhz dbm name <<<"$line"
        printf 'BSS %s(on wlan0)\n\tfreq: %s\n\tsignal: %s.00 dBm\n\tSSID: %s\n' "$bssid" "$mhz" "$dbm" "$name" >>"$tmp/run/scan"
    done
}
run_wifi() { # run_wifi FREQ: cb-wifi --prefer-5ghz with the box on FREQ MHz; the stand-ins' log is in $tmp/run/nmcli.log
    echo "$1" >"$tmp/run/freq"
    echo "$A" >"$tmp/run/bssid"
    : >"$tmp/run/nmcli.log"
    PATH="$tmp/bin:$PATH" CB_TEST_DIR="$tmp/run" CB_SYSTEM="$tmp/run" CB_TAG=test bash "$tmp/cb-wifi" --prefer-5ghz 2>"$tmp/run/stderr" || true
    grep '^connection up' "$tmp/run/nmcli.log" || true
}

scan "$A|2437|-50|$N" "$B|5180|-62|$N"
expect "on 2.4 GHz with a good 5 GHz access point, the box moves to it, for this connection only" "$(run_wifi 2437)" "connection up id Maple Cottage ifname wlan0 ap $B"
scan "$A|2437|-50|$N" "$B|5180|-78|$N"
expect "a 5 GHz access point that is too weak is left alone" "$(run_wifi 2437)" ""
scan "$A|5240|-50|$N" "$B|5180|-40|$N"
expect "on 5 GHz the box stays" "$(run_wifi 5240)" ""
scan "$A|2437|-50|$N" "$B|5180|-62|$N"
expect "with a cable carrying the traffic the radio is left alone" "$(CB_TEST_ROUTE_DEV=eth0 run_wifi 2437)" ""
expect "a move that fails puts the connection back as it was" "$(CB_TEST_FAIL_AP=1 run_wifi 2437)" "connection up id Maple Cottage ifname wlan0 ap $B
connection up id Maple Cottage ifname wlan0"
expect "nothing is saved in the connection (no band, no BSSID)" "$(grep -c 'modify' "$tmp/run/nmcli.log" || true)" "0"

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
