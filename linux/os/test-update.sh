#!/bin/bash
# Self-test of the update safety net: the boot health check (mkosi.extra/usr/lib/camera-bridge/cb-health-check), whether a failed check
# restarts the box (so a broken version uses up its tries by itself), and what cb-update (mkosi.extra/usr/sbin/cb-update) makes of a version
# that did not start: remembered at boot, reported as "rolled-back", never offered again; an installed update keeps waiting for the restart;
# the daily run and the web's update job share the system-job lock. Against stand-ins for curl, systemctl, bootctl, logger, systemd-run and
# the EFI variables. No root, no VM. Needs bash, jq, iconv, flock and dpkg (dpkg --compare-versions; the cb-update part is skipped without it).
# What it cannot show (systemd-boot really counting the tries, the box really restarting) is test-vm.sh's update test.
#
#   bash linux/os/test-update.sh
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

# --- the fake machine ------------------------------------------------------------------------------------------------------
BIN=$tmp/bin ROOT=$tmp/root
mkdir -p "$BIN" "$ROOT/run/status" "$ROOT/data" "$ROOT/system" "$ROOT/esp/EFI/Linux" "$ROOT/efivars"
export ROOT
: >"$ROOT/calls"
cat >"$BIN/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$ROOT/calls"
case "$*" in
    "show -p NRestarts --value camerabridged.service") cat "$ROOT/restarts" 2>/dev/null || echo 0 ;;
    "is-active --quiet avahi-daemon.service") exit 0 ;;
    "is-active --quiet camera-bridge-update-reboot.timer") exit 1 ;;
esac
exit 0
STUB
cat >"$BIN/curl" <<'STUB'
#!/bin/bash
# The daemon's health endpoint: $ROOT/answers holds what the engine is ("running", or "failed": 503, which curl -f turns into exit 22).
[ "${*: -1}" = http://127.0.0.1/api/v1/health ] || exit 64
[ -e "$ROOT/answers" ] || exit 7
[ "$(cat "$ROOT/answers")" = running ] || exit 22
echo '{"ok":true,"state":"running"}'
STUB
printf '#!/bin/bash\necho "$ROOT/esp"\n' >"$BIN/bootctl"
printf '#!/bin/bash\nexit 0\n' >"$BIN/logger"
printf '#!/bin/bash\nexit 0\n' >"$BIN/sleep"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# A copy of a script that needs no root, reads lib.sh from the repository and keeps its folders under $ROOT.
copy() { # copy SCRIPT DESTINATION
    sed -e "s#^export PATH=.*#export PATH=$BIN:\$PATH#" \
        -e "s#^\. /usr/lib/camera-bridge/lib.sh#. $LIB; CB_RUN=$ROOT/run; CB_STATUS=$ROOT/run/status; CB_DATA=$ROOT/data; CB_SYSTEM=$ROOT/system#" \
        -e 's/^require_root() {.*/require_root() { :; }/' \
        "$1" >"$2"
}
status() { jq -r "$2" "$ROOT/run/status/$1.json" 2>/dev/null; }
rebooted() { grep -c '^systemctl reboot' "$ROOT/calls" || true; }

# --- the health check ------------------------------------------------------------------------------------------------------
copy "$X/usr/lib/camera-bridge/cb-health-check" "$tmp/cb-health-check"
health() { CB_EFIVARS=$ROOT/efivars CB_HEALTH_ATTEMPTS=2 CB_HEALTH_DELAY=0 CB_HEALTH_SETTLE=0 bash "$tmp/cb-health-check" "$@" 2>/dev/null; }

echo running >"$ROOT/answers"; echo 0 >"$ROOT/restarts"
if health; then expect "a daemon that answers and never restarted makes a good boot" "$(status health .state)" "ok"; else bad "the check failed a good boot"; fi
echo 2 >"$ROOT/restarts"
if health; then bad "a daemon restarted on the trial boot passed"; else expect "a daemon that was restarted on the trial boot makes a bad boot" "$(status health .message)" "the daemon was restarted 2 times on this boot (it crashed or stopped answering)"; fi
echo 0 >"$ROOT/restarts"; echo failed >"$ROOT/answers"
if health; then bad "a daemon whose engine could not start passed"; else expect "a daemon that answers but whose engine could not start makes a bad boot (503 from health)" "$(status health .state)" "failed"; fi
rm -f "$ROOT/answers"
if health; then bad "a daemon that never answers passed"; else expect "a daemon that never answers makes a bad boot" "$(status health .state)" "failed"; fi
expect "the check itself never restarts the box" "$(rebooted)" "0"

# The variable systemd-boot leaves: 4 bytes of attributes, then the path of the entry (as renamed for this boot) in UTF-16.
counted() { # counted ENTRY-NAME: this boot counts against that entry
    { printf '\007\000\000\000'; printf '\\EFI\\Linux\\%s' "$1" | iconv -f UTF-8 -t UTF-16LE; printf '\000\000'; } >"$ROOT/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
}
entries() { rm -f "$ROOT"/esp/EFI/Linux/*; for e in "$@"; do : >"$ROOT/esp/EFI/Linux/$e"; done; }
after() { # after RESULT: what --after-failure does; prints the number of restarts it asked for
    : >"$ROOT/calls"
    SERVICE_RESULT=$1 health --after-failure || true
    rebooted
}

entries cb-os_0.1.129.efi cb-os_0.1.130+2-1.efi
counted cb-os_0.1.130+2-1.efi
expect "a check that passed restarts nothing" "$(after success)" "0"
expect "a failed check on a new version with tries left restarts the box" "$(after exit-code)" "1"
expect "so does a check that hung (timeout)" "$(after timeout)" "1"
entries cb-os_0.1.129.efi cb-os_0.1.130+0-3.efi
counted cb-os_0.1.130+0-3.efi
expect "the last try that failed restarts too: the previous version starts next" "$(after exit-code)" "1"
entries cb-os_0.1.130+0-3.efi
expect "a version whose tries are used up and that is the only one stays up (no restart loop)" "$(after exit-code)" "0"
entries cb-os_0.1.129+0-3.efi cb-os_0.1.130+0-4.efi
counted cb-os_0.1.130+0-4.efi
expect "nor when every other version is used up too" "$(after exit-code)" "0"
entries cb-os_0.1.130+3.efi
counted cb-os_0.1.130+2-1.efi
expect "a first install with tries left is tried again" "$(after exit-code)" "1"
rm -f "$ROOT"/efivars/*
expect "a boot that is not counted (a blessed version) is never restarted" "$(after exit-code)" "0"

# --- cb-update: a version that did not start, an update waiting for the restart, the lock ------------------------------------------
if command -v dpkg >/dev/null && command -v flock >/dev/null; then
    copy "$X/usr/sbin/cb-update" "$tmp/cb-update"
    sed -i -e "s#^current_version() {.*#current_version() { cat $ROOT/version; }#" "$tmp/cb-update"
    # The download helper runs through systemd-run: "latest" prints $ROOT/latest.json (the newest release), "download" is only counted.
    cat >"$BIN/systemd-run" <<'STUB'
#!/bin/bash
for a in "$@"; do case $a in latest) cat "$ROOT/latest.json"; exit 0 ;; download) echo download >>"$ROOT/calls"; exit 1 ;; esac; done
exit 64
STUB
    chmod +x "$BIN/systemd-run"
    upd() { bash "$tmp/cb-update" "$@" 2>/dev/null; }
    release() { jq -n --arg v "$1" '{version: $v, tag: ("os-v" + $v), url: "https://example.invalid/r", notes: ""}' >"$ROOT/latest.json"; }
    echo 0.1.130 >"$ROOT/version"
    rm -f "$ROOT/run/status/update.json"

    entries cb-os_0.1.130.efi cb-os_0.1.129.efi
    upd boot || bad "cb-update boot failed"
    if [ ! -e "$ROOT/system/update-failed" ] && [ ! -e "$ROOT/run/status/update.json" ]; then pass "a normal boot remembers nothing and says nothing"; else bad "a normal boot reported a rollback"; fi
    entries cb-os_0.1.130.efi cb-os_0.1.131+0-3.efi
    upd boot || bad "cb-update boot failed"
    expect "a newer version whose tries are used up is remembered at boot" "$(cat "$ROOT/system/update-failed")" "0.1.131"
    expect "and update.json says the box went back from it" "$(status update '[.state, .failedVersion, .current, .updateAvailable] | map(tostring) | join(" ")')" "rolled-back 0.1.131 0.1.130 false"
    upd boot || bad "cb-update boot failed"
    expect "it is remembered once" "$(wc -l <"$ROOT/system/update-failed" | tr -d ' ')" "1"
    release 0.1.131
    upd check || bad "cb-update check failed"
    expect "the version that did not start is not offered again" "$(status update '[.state, .updateAvailable, .failedVersion] | map(tostring) | join(" ")')" "rolled-back false 0.1.131"
    : >"$ROOT/calls"
    upd apply || bad "cb-update apply failed"
    expect "nor installed by Update now" "$(grep -c download "$ROOT/calls" || true)" "0"
    release 0.1.132
    upd check || bad "cb-update check failed"
    expect "a newer version is offered" "$(status update '[.state, .updateAvailable, .latest] | map(tostring) | join(" ")')" "available true 0.1.132"
    entries cb-os_0.1.130.efi cb-os_0.1.131+0-3.efi cb-os_0.1.132+3.efi
    upd check || bad "cb-update check failed"
    expect "an installed update keeps waiting for the restart when the daily check runs" "$(status update '[.state, .rebootRequired, .updateAvailable] | map(tostring) | join(" ")')" "installed true false"
    : >"$ROOT/calls"
    upd apply || bad "cb-update apply failed"
    expect "and Update now does not download it again" "$(grep -c download "$ROOT/calls" || true)" "0"
    echo 0.1.132 >"$ROOT/version"
    printf '0.1.129\n0.1.131\n' >"$ROOT/system/update-failed"
    entries cb-os_0.1.132.efi cb-os_0.1.131+0-3.efi
    rm -f "$ROOT/run/status/update.json"
    upd boot || bad "cb-update boot failed"
    if [ ! -e "$ROOT/system/update-failed" ]; then pass "versions at or below the running one are forgotten once a newer one runs"; else bad "old failed versions are kept: $(cat "$ROOT/system/update-failed")"; fi
    if [ ! -e "$ROOT/run/status/update.json" ]; then pass "and no rollback is reported"; else bad "a rollback is reported on a good boot"; fi

    # The lock of cb-system's heavy jobs: one writer at a time. The web job holds it and hands it down on descriptor 9.
    echo 0.1.130 >"$ROOT/version"; rm -f "$ROOT/system/update-failed"; entries cb-os_0.1.130.efi; release 0.1.131
    mkdir -p "$ROOT/run/jobs"; touch "$ROOT/system/auto-update"
    echo '{"state":"downloading","message":"another job"}' >"$ROOT/run/status/update.json"
    flock "$ROOT/run/jobs/.lock" /bin/sleep 5 &
    holder=$!
    for _ in $(seq 1 50); do flock -n "$ROOT/run/jobs/.lock" true 2>/dev/null || break; /bin/sleep 0.1; done
    : >"$ROOT/calls"
    upd auto || bad "the daily run failed while another job held the lock"
    expect "the daily run leaves the running job's update.json alone" "$(status update .message)" "another job"
    if upd apply; then bad "a second install ran while another held the lock"; else expect "a second install is refused while another runs" "$(grep -c download "$ROOT/calls" || true)" "0"; fi
    wait "$holder"
    : >"$ROOT/calls"
    (exec 9>"$ROOT/run/jobs/.lock"; flock -n 9; bash "$tmp/cb-update" apply 2>/dev/null) || true
    expect "the web job's own lock (descriptor 9) lets its install run" "$(grep -c download "$ROOT/calls" || true)" "1"
    rm -f "$ROOT/system/auto-update"
else
    echo "skip  cb-update (needs dpkg and flock: run in the static checks' container)"
fi

# --- the wiring ------------------------------------------------------------------------------------------------------------------
check() { # check DESCRIPTION COMMAND...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else bad "$desc"; fi
}
U=$X/usr/lib/systemd/system
check "a failed or hung check restarts the box through ExecStopPost, after the check's own budget" bash -c "u='$U/camera-bridge-health.service'; grep -q '^ExecStopPost=/usr/lib/camera-bridge/cb-health-check --after-failure$' \$u && grep -q '^TimeoutStartSec=8min$' \$u"
check "a daemon that cannot start is still checked (Wants, not Requires)" bash -c "u='$U/camera-bridge-health.service'; grep -q '^Wants=camerabridged.service$' \$u && ! grep -q '^Requires=' \$u"
check "the rollback is looked for at every boot, before the daemon and the daily check" bash -c "u='$U/camera-bridge-update-boot.service'; grep -q '^ExecStart=/usr/sbin/cb-update boot$' \$u && grep -q '^Before=camerabridged.service camera-bridge-update.service$' \$u && grep -q 'camera-bridge-update-boot.service' '$HERE/mkosi.postinst.chroot'"
check "the daemon is never given up on: no start limit, a growing pause" bash -c "u='$HERE/units/camerabridged.service.in'; grep -q '^StartLimitIntervalSec=0$' \$u && ! grep -q '^StartLimitBurst=' \$u && grep -q '^RestartSteps=' \$u && grep -q '^RestartMaxDelaySec=' \$u"

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
