#!/bin/bash
# Self-test of cb-system's request dispatcher and jobs (mkosi.extra/usr/sbin/cb-system): what the daemon user drops in the request folder is
# moved into the root-only jobs folder before anything reads it (a FIFO, a link or a directory never blocks or misleads it), a job's failing
# step makes the job fail (and stops what follows it, such as a restart), a body that dies still ends with a status, and the factory reset
# forgets the Wi-Fi passwords, SSH and the update settings. Also the clock (synced or not, the last time kept for a flat clock battery), the
# network link's speed in system.json, and the drives' health (cb-disk-health). Against stand-ins for systemctl, nmcli, journalctl, chronyc,
# date, ip, smartctl and the helpers cb-system calls.
# No root. Needs GNU coreutils (mv -T, stat -c), bash, jq and flock: it runs in the static checks' container.
#
#   bash linux/os/test-system.sh
# shellcheck disable=SC2016
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
X=$HERE/mkosi.extra
LIB=$X/usr/lib/camera-bridge/lib.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
expect() { # expect DESCRIPTION ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; fi
}

if ! mv --help 2>&1 | grep -q -- '--no-target-directory'; then echo "skip  (needs GNU coreutils: run in the static checks' container)"; exit 0; fi

BIN=$tmp/bin ROOT=$tmp/root
mkdir -p "$ROOT/journal/0123456789abcdef0123456789abcdef" "$BIN" "$ROOT/run/requests" "$ROOT/run/status" "$ROOT/run/jobs" "$ROOT/data" "$ROOT/system/ssh" "$ROOT/system/network-connections" \
    "$ROOT/update/cache" "$ROOT/update/stage" "$ROOT/system/away"
export ROOT
: >"$ROOT/calls"
for tool in systemctl nmcli journalctl; do printf '#!/bin/bash\necho "%s $*" >>"$ROOT/calls"\n' "$tool" >"$BIN/$tool"; done
printf '#!/bin/bash\nexit 0\n' >"$BIN/logger"
# The helpers: each records its call; $ROOT/fails-<name> makes it fail.
for helper in cb-update cb-wifi cb-tls cb-away; do
    printf '#!/bin/bash\ncat >/dev/null 2>&1 <&0 || true\necho "%s $*" >>"$ROOT/calls"\n[ ! -e "$ROOT/fails-%s" ]\n' "$helper" "$helper" >"$BIN/$helper"
done
chmod +x "$BIN"/*
sed -e "s#^export PATH=.*#export PATH=$BIN:\$PATH#" \
    -e "s#^\. /usr/lib/camera-bridge/lib.sh#. $LIB; CB_RUN=$ROOT/run; CB_STATUS=$ROOT/run/status; CB_DATA=$ROOT/data; CB_SYSTEM=$ROOT/system#" \
    -e 's/^require_root() {.*/require_root() { :; }/' \
    -e "s#/usr/sbin/cb-#$BIN/cb-#g" -e "s#/srv/update/#$ROOT/update/#g" -e "s#^JOURNAL_DIR=.*#JOURNAL_DIR=$ROOT/journal#" \
    "$X/usr/sbin/cb-system" >"$tmp/cb-system"
sys() { bash "$tmp/cb-system" "$@" 2>/dev/null; }
status() { jq -r "$2" "$ROOT/run/status/$1.json" 2>/dev/null; }
calls() { cat "$ROOT/calls"; }

# --- the dispatcher: everything is moved into the jobs folder before it is looked at ------------------------------------------------
R=$ROOT/run/requests
mkfifo "$R/reboot.json"                                   # would block a read for good
echo '{"x": 1}' >"$ROOT/secret.json"; ln -s "$ROOT/secret.json" "$R/poweroff.json"   # a link to a file the daemon may not read
mkdir -p "$R/update-check.json/inside"                    # a directory: rm -f could not remove it, and the path unit would retrigger forever
echo '{"enabled": true}' >"$R/auto-update.json"
echo 'not json' >"$R/wifi-scan.json"
echo '{}' >"$R/not-a-job.json"
mkfifo "$R/stray"
sys process-requests || bad "the dispatcher failed"
expect "the request folder is empty afterwards (FIFO, link, directory, stray entries)" "$(find "$R" -mindepth 1 | wc -l | tr -d ' ')" "0"
expect "the one valid request is queued with its own copy" "$(find "$ROOT/run/jobs" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f ')" "auto-update.json "
expect "and started" "$(calls | grep -c 'start --no-block camera-bridge-job@auto-update.service' || true)" "1"
expect "the FIFO, the link and the directory started nothing" "$(grep -c 'camera-bridge-job@\(reboot\|poweroff\|update-check\)' "$ROOT/calls" || true)" "0"
expect "the file the link pointed to is untouched" "$(cat "$ROOT/secret.json")" '{"x": 1}'
expect "a request that is not JSON says so" "$(status wifi-scan .message)" "request is not a JSON object"

# Several JSON values in one file: jq judges each, so the gate must see them all (a later object must not vouch for an earlier value).
printf '"anything"\n{"enabled": true}\n' >"$R/wifi-scan.json"
sys process-requests || bad "the dispatcher failed"
expect "a file with two JSON values is refused" "$(status wifi-scan .message)" "request is not a JSON object"
expect "and was not queued" "$(find "$ROOT/run/jobs" -name 'wifi-scan.json' | wc -l | tr -d ' ')" "0"

# --- jobs: a failing step fails the job and stops what follows it -----------------------------------------------------------------
job() { # job NAME BODY: queues BODY for NAME and runs the job
    printf '%s\n' "$2" >"$ROOT/run/jobs/$1.json"
    : >"$ROOT/calls"
    sys run-job "$1" || true
}
touch "$ROOT/fails-cb-update"
job update-apply '{"reboot": true}'
expect "an update that fails makes update-apply fail" "$(status update-apply .state)" "failed"
expect "and the box is not restarted" "$(calls | grep -c 'systemctl reboot' || true)" "0"
rm -f "$ROOT/fails-cb-update"
job update-apply '{"reboot": true}'
expect "one that works is ok and restarts when asked" "$(status update-apply .state) $(calls | grep -c 'systemctl reboot' || true)" "ok 1"
touch "$ROOT/fails-cb-wifi"
job wifi-join '{"ssid": "Maple Cottage", "password": "not-a-real-password", "reboot": true}'
expect "a Wi-Fi network that could not be saved fails the job, and the box does not restart" "$(status wifi-join .state) $(calls | grep -c 'systemctl reboot' || true)" "failed 0"
rm -f "$ROOT/fails-cb-wifi"
job auto-update '{"enabled": "maybe"}'
expect "a body that dies (cb_die) still ends the job with a status" "$(status auto-update .state)" "failed"
expect "the job's arguments are gone" "$(find "$ROOT/run/jobs" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '%f ')" ""

# --- Away from home: the away-set job hands its argument file to cb-away, which checks every value again ----------------------------
job away-set '{"on": true, "port": 51820, "subnet": "10.77.12.0/24", "peers": []}'
expect "the away-set job ends ok and gives cb-away its argument file" "$(status away-set .state) $(calls | grep -c "^cb-away set $ROOT/run/jobs/away-set.running.json\$" || true) $(calls | grep -c '^cb-away' || true)" "ok 1 1"
touch "$ROOT/fails-cb-away"
job away-set '{"on": true, "port": 51820, "subnet": "10.77.12.0/24", "peers": []}'
expect "an away-set that cb-away refuses ends failed" "$(status away-set .state)" "failed"
rm -f "$ROOT/fails-cb-away"

# --- the factory reset forgets more than the bridge's data -----------------------------------------------------------------------
echo psk=not-a-real-password >"$ROOT/system/network-connections/Maple Cottage.nmconnection"
touch "$ROOT/system/ssh/enabled" "$ROOT/system/ssh/authorized_keys" "$ROOT/system/ssh/ssh_host_ed25519_key" "$ROOT/system/update.conf" \
    "$ROOT/system/auto-update" "$ROOT/system/away/state.json" "$ROOT/system/away/private.key" "$ROOT/update/cache/cb-os_0.1.131_root.raw.zst" "$ROOT/data/config.json" "$ROOT/system/recording-drive"
job factory-reset '{"confirm": "RESET"}'
expect "the saved Wi-Fi networks (their passwords) are erased, and NetworkManager forgets them" "$(find "$ROOT/system/network-connections" -mindepth 1 | wc -l | tr -d ' ') $(calls | grep -c 'nmcli connection reload' || true)" "0 1"
expect "SSH's keys and host key are erased" "$(find "$ROOT/system/ssh" -mindepth 1 | wc -l | tr -d ' ')" "0"
expect "the update settings and downloads are erased" "$(find "$ROOT/system/update.conf" "$ROOT/system/auto-update" "$ROOT/update/cache" -mindepth 0 ! -path "$ROOT/update/cache" 2>/dev/null | wc -l | tr -d ' ')" "0"
expect "the log of earlier boots is erased (and the folders of other machine ids)" "$(calls | grep -c 'journalctl --vacuum-time=1s' || true) $(find "$ROOT/journal" -mindepth 1 | wc -l | tr -d ' ')" "1 0"
expect "Away from home's request and the box's VPN key are erased" "$(find "$ROOT/system/away" -mindepth 1 | wc -l | tr -d ' ')" "0"
expect "the bridge's data is erased, the recording drive's choice kept, and the box restarts" \
    "$(find "$ROOT/data" -mindepth 1 | wc -l | tr -d ' ') $(find "$ROOT/system/recording-drive" 2>/dev/null | wc -l | tr -d ' ') $(calls | grep -c 'systemctl reboot' || true)" "0 1 1"

# --- the clock and the network link in system.json ----------------------------------------------------------------------------------
cat >"$BIN/chronyc" <<'STUB'
#!/bin/bash
cat "$ROOT/tracking" 2>/dev/null
STUB
cat >"$BIN/date" <<'STUB'
#!/bin/bash
# The box's clock is $ROOT/now (seconds); "date -u -s @N" sets it.
case "$*" in
    "-u +%s") cat "$ROOT/now" ;;
    "-u -s @"*) echo "${3#@}" >"$ROOT/now"; echo "date $*" >>"$ROOT/calls" ;;
    *) exec /bin/date "$@" ;;
esac
STUB
printf '#!/bin/bash\necho "Current Entry: cb-os_0.1.130.efi"\n' >"$BIN/bootctl"
cat >"$BIN/ip" <<'STUB'
#!/bin/bash
case "$*" in "-4 route show default") cat "$ROOT/route" 2>/dev/null ;; esac
STUB
chmod +x "$BIN"/*
sed -i "s#^SYSFS=/sys#SYSFS=$ROOT/sys#" "$tmp/cb-system"
mkdir -p "$ROOT/sys/class/net/enp1s0/device" "$ROOT/sys/class/net/wlan0/device" "$ROOT/sys/class/net/wlan0/wireless"
echo "default via 192.168.1.1 dev enp1s0 proto dhcp src 192.168.1.20 metric 100" >"$ROOT/route"
echo 100 >"$ROOT/sys/class/net/enp1s0/speed"; echo full >"$ROOT/sys/class/net/enp1s0/duplex"
echo "C0A80105,192.168.1.5,3,1761900000.5,-0.000012,0.000003,0.000020,-7.1,0.001,0.02,0.010,0.002,64.5,Normal" >"$ROOT/tracking"
st=$(sys status)
expect "a clock that follows a time server is synchronized, with its source" "$(jq -c '.clock | [.synchronized, .source, .lastSync]' <<<"$st")" '[true,"192.168.1.5","2025-10-31T08:40:00Z"]'
expect "the wired link's speed and duplex are published" "$(jq -c .link <<<"$st")" '{"interface":"enp1s0","wired":true,"speedMbps":100,"duplex":"full"}'
echo "7F7F0101,,10,0.0,0.000000,0.000000,0.000000,0.0,0.0,0.0,0.0,0.0,0.0,Normal" >"$ROOT/tracking"
expect "a box serving its own clock (no time server reached) is not synchronized" "$(sys status | jq -c '.clock | [.synchronized, .source]')" '[false,null]'
echo "00000000,,0,0.0,0.000000,0.000000,0.000000,0.0,0.0,0.0,0.0,0.0,0.0,Not synchronised" >"$ROOT/tracking"
expect "nor one that has not synchronized yet" "$(sys status | jq -r '.clock.synchronized')" "false"
rm -f "$ROOT/tracking"
expect "no answer from chrony: unknown" "$(sys status | jq -c '.clock')" "null"
echo -1 >"$ROOT/sys/class/net/enp1s0/speed"
expect "a speed the driver does not know is null" "$(sys status | jq -c '.link.speedMbps')" "null"
echo "default via 192.168.1.1 dev wlan0 proto dhcp" >"$ROOT/route"; echo 300 >"$ROOT/sys/class/net/wlan0/speed"
expect "on Wi-Fi there is no cable speed" "$(sys status | jq -c '.link')" '{"interface":"wlan0","wired":false,"speedMbps":null,"duplex":null}'

echo 1800000000 >"$ROOT/now"; rm -f "$ROOT/system/last-time"
sys clock-save
expect "the time is kept at shutdown" "$(cat "$ROOT/system/last-time")" "1800000000"
echo 1700000000 >"$ROOT/now"; : >"$ROOT/calls"
sys clock-restore
expect "a clock that starts behind it (a flat battery) is set forward to it" "$(cat "$ROOT/now") $(grep -c 'date -u -s' "$ROOT/calls" || true)" "1800000000 1"
echo 1800000600 >"$ROOT/now"; : >"$ROOT/calls"
sys clock-restore
expect "a clock that is ahead of it is left alone" "$(cat "$ROOT/now") $(grep -c 'date -u -s' "$ROOT/calls" || true)" "1800000600 0"
sys housekeeping
expect "housekeeping keeps the time only once an hour" "$(cat "$ROOT/system/last-time")" "1800000000"
echo 1800003700 >"$ROOT/now"; sys housekeeping
expect "and then again" "$(cat "$ROOT/system/last-time")" "1800003700"
echo 1700000000 >"$ROOT/now"; sys clock-save
expect "a clock that went back without a time server does not overwrite the kept time" "$(cat "$ROOT/system/last-time")" "1800003700"
echo 1 >"$ROOT/system/last-time"; echo 1700000000 >"$ROOT/now"; : >"$ROOT/calls"; sys clock-restore
expect "a kept time that cannot be real is ignored" "$(grep -c 'date -u -s' "$ROOT/calls" || true)" "0"

# --- the drives' health (cb-disk-health) ---------------------------------------------------------------------------------------------
sed -e "s#^export PATH=.*#export PATH=$BIN:\$PATH#" \
    -e "s#^\. /usr/lib/camera-bridge/lib.sh#. $LIB; CB_RUN=$ROOT/run; CB_STATUS=$ROOT/run/status; CB_DATA=$ROOT/data; CB_SYSTEM=$ROOT/system#" \
    -e 's/^\[ "\$(id -u)" -eq 0 \] ||/true ||/' -e 's/\[ ! -b "\$part" \]/[ -z "$part" ]/' \
    "$X/usr/lib/camera-bridge/cb-disk-health" >"$tmp/cb-disk-health"
drive_says() { # drive_says SMARTCTL-JSON [FS-ERRORS]: state | message of the drive's entry
    printf '%s' "$1" | FS_ERRORS=${2:-0} bash "$tmp/cb-disk-health" --summary | jq -r '"\(.state) | \(.message)"'
}
expect "a healthy NVMe SSD" "$(drive_says '{"model_name":"Fast NVMe","smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":0,"percentage_used":12,"media_errors":0},"temperature":{"current":41},"power_on_time":{"hours":5000}}')" \
    "ok | Healthy, 12% of its rated life used."
expect "an NVMe SSD more than 90% worn" "$(drive_says '{"smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":0,"percentage_used":93,"media_errors":0}}')" \
    "warning | It has used 93% of its rated life. Plan to replace it."
expect "an NVMe SSD that says it is no longer reliable is failing" "$(drive_says '{"smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":4,"percentage_used":40,"media_errors":3}}')" \
    "failing | It reports that it is no longer reliable. It reports 3 read or write errors. Copy the recordings you want to keep and replace it soon."
expect "a drive whose own check failed is failing" "$(drive_says '{"smart_status":{"passed":false}}')" \
    "failing | It reports that it is failing. Copy the recordings you want to keep and replace it soon."
expect "a hard disk with damaged and unreadable sectors" "$(drive_says '{"smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":5,"value":100,"raw":{"value":8}},{"id":197,"value":100,"raw":{"value":2}},{"id":198,"value":100,"raw":{"value":1}}]}}')" \
    "warning | It has replaced 8 damaged sectors. 2 sectors could not be read. Plan to replace it."
expect "a SATA SSD's wear from its device statistics" "$(drive_says '{"smart_status":{"passed":true},"ata_device_statistics":{"pages":[{"table":[{"name":"Percentage Used Endurance Indicator","value":95}]}]}}')" \
    "warning | It has used 95% of its rated life. Plan to replace it."
expect "a Samsung SATA SSD's wear from its wear-levelling attribute (life left)" "$(printf '%s' '{"smart_status":{"passed":true},"ata_smart_attributes":{"table":[{"id":177,"value":96,"raw":{"value":120}}]}}' | bash "$tmp/cb-disk-health" --summary | jq -r .percentUsed)" "4"
expect "errors the file system recorded are a warning" "$(drive_says '{"smart_status":{"passed":true}}' 3)" "warning | Its file system recorded 3 errors. Plan to replace it."
expect "a USB enclosure that hides the drive's health" "$(drive_says '{}')" "unknown | This drive does not report its health (many USB enclosures do not)."

cat >"$BIN/findmnt" <<'STUB'
#!/bin/bash
echo "/dev/test-nvme0n1p4[/camera-bridge]"
STUB
cat >"$BIN/blkid" <<'STUB'
#!/bin/bash
[ "$2" = rec-2222 ] && echo /dev/test-sdb1
STUB
cat >"$BIN/lsblk" <<'STUB'
#!/bin/bash
case "${*: -1}" in /dev/test-nvme0n1p4) echo nvme0n1 ;; /dev/test-sdb1) echo sdb ;; esac
STUB
cat >"$BIN/smartctl" <<'STUB'
#!/bin/bash
case "$*" in
    *nvme0n1) echo '{"model_name":"Fast NVMe","smart_status":{"passed":true},"nvme_smart_health_information_log":{"critical_warning":0,"percentage_used":95,"media_errors":0}}' ;;
    "-j -a /dev/sdb") echo '{"device":{"type":"scsi"}}'; exit 4 ;;
    "-j -a -d sat /dev/sdb") echo '{"model_name":"Portable SSD","smart_status":{"passed":true},"ata_smart_attributes":{"table":[]}}' ;;
esac
STUB
chmod +x "$BIN"/*
mkdir -p "$ROOT/sys/fs/ext4/test-sdb1"; echo 0 >"$ROOT/sys/fs/ext4/test-sdb1/errors_count"
mkdir -p "$ROOT/sys/fs/ext4/test-nvme0n1p4"; echo 0 >"$ROOT/sys/fs/ext4/test-nvme0n1p4/errors_count"
echo rec-2222 >"$ROOT/system/recording-drive"; rm -f "$ROOT/system/archive-drive"
CB_SYSFS=$ROOT/sys bash "$tmp/cb-disk-health" 2>/dev/null || bad "cb-disk-health failed"
expect "the box's own disk and the recording drive are checked (a USB enclosure through SAT)" "$(status disk-health '[.drives[] | "\(.role) \(.name) \(.state)"] | join(", ")')" \
    "system nvme0n1 warning, recording sdb ok"
expect "the whole report names what needs attention" "$(status disk-health '[.state, .message] | join(" | ")')" "warning | The box’s own disk needs attention."
if grep -q 'disk-health)      require_root; exec /usr/lib/camera-bridge/cb-disk-health ;;' "$X/usr/sbin/cb-system"; then pass "cb-system disk-health runs it"; else bad "cb-system disk-health does not run it"; fi

check() { # check DESCRIPTION COMMAND...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else bad "$desc"; fi
}
check "the dispatcher cannot hang for good" grep -q '^TimeoutStartSec=30s$' "$X/usr/lib/systemd/system/camera-bridge-request.service"
check "the drives are checked every day and soon after boot, with smartmontools and nvme-cli in the image, without smartd" bash -c "grep -q '^OnUnitActiveSec=1d$' '$X/usr/lib/systemd/system/camera-bridge-disk-health.timer' && grep -q 'camera-bridge-disk-health.timer' '$HERE/mkosi.postinst.chroot' && grep -Eq '^ +smartmontools$' '$HERE/mkosi.conf' && grep -Eq '^ +nvme-cli$' '$HERE/mkosi.conf' && grep -q 'systemctl mask smartmontools.service' '$HERE/mkosi.postinst.chroot'"
check "chrony's drift and the last known time are kept on the data partition, and the clock is put forward before chrony starts" bash -c "grep -q '^What=/srv/system/chrony$' '$X/usr/lib/systemd/system/var-lib-chrony.mount' && grep -q '^Before=time-set.target chrony.service camerabridged.service sysinit.target$' '$X/usr/lib/systemd/system/camera-bridge-clock.service' && grep -q 'var-lib-chrony.mount' '$HERE/mkosi.postinst.chroot' && grep -q 'camera-bridge-clock.service' '$HERE/mkosi.postinst.chroot' && grep -q '/srv/system/chrony' '$X/usr/lib/camera-bridge/cb-datadirs'"
check "a marker-file reset forgets the Wi-Fi networks before NetworkManager reads them" grep -q '^Before=NetworkManager.service camera-bridge-wifi-import.service$' "$X/usr/lib/systemd/system/camera-bridge-factory-reset.service"

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
