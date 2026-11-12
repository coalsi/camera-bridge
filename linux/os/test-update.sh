#!/bin/bash
# Self-test of the update safety net: the boot health check (mkosi.extra/usr/lib/camera-bridge/cb-health-check), whether a failed check
# restarts the box (so a broken version uses up its tries by itself), and what cb-update (mkosi.extra/usr/sbin/cb-update) makes of a version
# that did not start: remembered at boot, reported as "rolled-back", never offered again; an installed update keeps waiting for the restart;
# the daily run and the web's update job share the system-job lock; staging an update (a signed release copied, checked and unpacked for
# systemd-sysupdate) is refused, with nothing installed, when a write fails or the data partition has no room for it. Against stand-ins for
# curl, systemctl, bootctl, logger, systemd-run, df, systemd-sysupdate and the EFI variables. No root, no VM. Needs bash, jq, iconv, flock and
# dpkg (dpkg --compare-versions; the cb-update parts are skipped without them), and minisign and zstd for the staging part.
# What it cannot show (systemd-sysupdate really writing a slot, systemd-boot really counting the tries, the box really restarting) is
# test-vm.sh's update test.
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
    # The download helper runs through systemd-run: "latest" prints $ROOT/latest.json (the newest release), "download" is counted, and
    # succeeds only when $ROOT/download-ok exists (the staging tests below put the files in the cache themselves).
    cat >"$BIN/systemd-run" <<'STUB'
#!/bin/bash
for a in "$@"; do case $a in latest) cat "$ROOT/latest.json"; exit 0 ;; download) echo download >>"$ROOT/calls"; [ -e "$ROOT/download-ok" ]; exit ;; esac; done
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
    expect "nor installed by Install update" "$(grep -c download "$ROOT/calls" || true)" "0"
    release 0.1.132
    upd check || bad "cb-update check failed"
    expect "a newer version is offered" "$(status update '[.state, .updateAvailable, .latest] | map(tostring) | join(" ")')" "available true 0.1.132"
    entries cb-os_0.1.130.efi cb-os_0.1.131+0-3.efi cb-os_0.1.132+3.efi
    upd check || bad "cb-update check failed"
    expect "an installed update keeps waiting for the restart when the daily check runs" "$(status update '[.state, .rebootRequired, .updateAvailable] | map(tostring) | join(" ")')" "installed true false"
    : >"$ROOT/calls"
    upd apply || bad "cb-update apply failed"
    expect "and Install update does not download it again" "$(grep -c download "$ROOT/calls" || true)" "0"
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

# --- cb-update: staging an update. A write that fails (the data partition full, a disk error) leaves "failed" and nothing installed --------
# A release signed with this test's own key in a fake download cache, the real tee, zstd and minisign, and the shell's limit on the size of a
# file (ulimit -f, with SIGXFSZ ignored) standing in for a full disk: past it a write fails as it does on a full partition (tee says so only in
# its status and keeps passing every byte on). systemd-sysupdate is a stand-in that notes what the stage holds.
if command -v dpkg >/dev/null && command -v flock >/dev/null && command -v minisign >/dev/null && command -v zstd >/dev/null; then
    UPD=$ROOT/srv-update
    mkdir -p "$UPD/cache" "$UPD/stage"
    minisign -G -W -p "$tmp/test-key.pub" -s "$tmp/test-key.sec" >/dev/null 2>&1
    copy "$X/usr/sbin/cb-update" "$tmp/cb-update-stage"
    sed -i -e "s#^current_version() {.*#current_version() { cat $ROOT/version; }#" -e "s#^PUBKEY=.*#PUBKEY=$tmp/test-key.pub#" \
        -e "s#^CACHE=.*#CACHE=$UPD/cache#" -e "s#^STAGE=.*#STAGE=$UPD/stage#" -e "s#/usr/lib/systemd/systemd-sysupdate #$BIN/systemd-sysupdate #" \
        "$tmp/cb-update-stage"
    if ! grep -qxF "PUBKEY=$tmp/test-key.pub" "$tmp/cb-update-stage" || ! grep -qxF "CACHE=$UPD/cache" "$tmp/cb-update-stage" \
        || ! grep -qxF "STAGE=$UPD/stage" "$tmp/cb-update-stage" || grep -q '/usr/lib/systemd/systemd-sysupdate' "$tmp/cb-update-stage"; then
        bad "the test's copy of cb-update still uses the box's own key, folders or installer; the staging tests are not run"
    else
        cat >"$BIN/systemd-sysupdate" <<'STUB'
#!/bin/bash
echo "systemd-sysupdate $*" >>"$ROOT/calls"
(cd "$ROOT/srv-update/stage" && sha256sum -- cb-os_*) >"$ROOT/installed"
STUB
        # The data partition's free room: plenty, except for the stage when $ROOT/stage-free-kb says otherwise. Then it is a partition of that
        # size, on which what the stage holds takes room.
        cat >"$BIN/df" <<'STUB'
#!/bin/bash
if [ "${*: -1}" != /srv ] && [ -e "$ROOT/stage-free-kb" ]; then
    printf 'Avail\n%s\n' $(( $(cat "$ROOT/stage-free-kb") - $(du -sk "$ROOT/srv-update/stage" | cut -f1) ))
else
    printf 'Avail\n%s\n' 50000000
fi
STUB
        # sync: fails for the staged files when $ROOT/sync-fails exists (a write error that shows only when the data is written back).
        cat >"$BIN/sync" <<'STUB'
#!/bin/bash
if [ -e "$ROOT/sync-fails" ] && [[ " $* " == *"/srv-update/stage/"* ]]; then echo "sync: error syncing: Input/output error" >&2; exit 1; fi
exec /usr/bin/sync "$@"
STUB
        chmod +x "$BIN/systemd-sysupdate" "$BIN/df" "$BIN/sync"
        case $(uname -m) in x86_64) a=amd64 ;; aarch64) a=arm64 ;; *) a=unknown ;; esac
        v=0.1.131
        # The release: a kernel image of 300 kB and a system image of 4 MB (a little noise, then a pattern: never sparse), about 300 kB packed.
        head -c 300000 /dev/urandom >"$tmp/uki.efi"
        { head -c 300000 /dev/urandom; head -c 3700000 < <(yes 'Camera Bridge OS test system image'); } >"$tmp/root.raw"
        zstd -q -f "$tmp/root.raw" -o "$tmp/root.raw.zst"
        prepare() { # a fresh download of $v in the cache, and an empty stage
            rm -rf "${UPD:?}/cache"/* "$UPD/stage"/* "$ROOT/installed"
            mkdir -p "$UPD/cache/$v"
            cp "$tmp/uki.efi" "$UPD/cache/$v/cb-os_${v}_${a}.efi"
            cp "$tmp/root.raw.zst" "$UPD/cache/$v/cb-os_${v}_${a}_root.raw.zst"
            (cd "$UPD/cache/$v" && sha256sum "cb-os_${v}_${a}.efi" "cb-os_${v}_${a}_root.raw.zst" >SHA256SUMS)
            minisign -S -s "$tmp/test-key.sec" -m "$UPD/cache/$v/SHA256SUMS" -x "$UPD/cache/$v/SHA256SUMS.sig" >/dev/null
            : >"$ROOT/calls"
        }
        stage_apply() { # stage_apply [FILE-SIZE-LIMIT-KB]: Install update, with writes past the limit failing
            ( trap '' XFSZ; [ -z "${1:-}" ] || ulimit -f "$1"; bash "$tmp/cb-update-stage" apply ) 2>"$ROOT/stderr"
        }
        installed() { grep -c '^systemd-sysupdate' "$ROOT/calls" || true; }
        stage_left() { find "$UPD/stage" -mindepth 1 | wc -l | tr -d ' '; }
        echo 0.1.130 >"$ROOT/version"; rm -f "$ROOT/system/update-failed" "$ROOT/stage-free-kb"; entries cb-os_0.1.130.efi; release "$v"
        touch "$ROOT/download-ok"

        prepare
        if stage_apply; then pass "an update whose files verify is installed"; else bad "an update whose files verify failed: $(tail -3 "$ROOT/stderr")"; fi
        expect "it is written by systemd-sysupdate from the stage, once" "$(installed) $(grep '^systemd-sysupdate' "$ROOT/calls" | sed 's/.* //')" "1 $v"
        expect "the stage held the kernel image and the unpacked system image, byte for byte, under the names the transfers expect, and no packed one" \
            "$(sort "$ROOT/installed" | tr -s ' ' | tr '\n' ';')" \
            "$(cd "$tmp" && { printf '%s cb-os_%s.efi\n' "$(sha256sum <uki.efi | cut -d' ' -f1)" "$v"; printf '%s cb-os_%s_root.raw\n' "$(sha256sum <root.raw | cut -d' ' -f1)" "$v"; } | sort | tr '\n' ';')"
        expect "update.json says installed" "$(status update '[.state, .latest, .rebootRequired] | map(tostring) | join(" ")')" "installed $v true"
        expect "the stage and the download are cleared" "$(stage_left) $(find "$UPD/cache" -mindepth 1 | wc -l | tr -d ' ')" "0 0"

        rm -f "$ROOT/esp/EFI/Linux/cb-os_${v}"*; prepare
        if stage_apply 100; then bad "an update whose kernel image could not be written to the stage was installed"; fi
        expect "a kernel image that cannot be written in full to the stage (tee) leaves \"failed\" and nothing installed" \
            "$(installed) $(status update '[.state, .message] | join(" | ")')" "0 failed | verification of version $v failed; nothing was installed"
        expect "and the log says why" "$(grep -cF "could not copy cb-os_${v}_${a}.efi into the staging folder (is the data partition full?)" "$ROOT/stderr")" "1"
        expect "and the stage is emptied" "$(stage_left)" "0"

        prepare
        if stage_apply 1000; then bad "an update whose system image could not be unpacked in full was installed"; fi
        expect "a system image that cannot be unpacked in full (zstd) leaves \"failed\" and nothing installed" \
            "$(installed) $(status update '[.state, .message] | join(" | ")')" "0 failed | verification of version $v failed; nothing was installed"
        expect "and the log says why" "$(grep -cF "could not unpack cb-os_${v}_${a}_root.raw.zst into the staging folder (is the data partition full?)" "$ROOT/stderr")" "1"
        expect "and the stage is emptied" "$(stage_left)" "0"

        prepare
        rm -f "$ROOT/esp/EFI/Linux/cb-os_${v}"*
        touch "$ROOT/sync-fails"
        if stage_apply; then bad "an update whose staged files could not be written back to the disk was installed"; fi
        expect "staged files that fail when written back to the disk (sync) leave \"failed\" and nothing installed" \
            "$(installed) $(status update '[.state, .message] | join(" | ")')" "0 failed | verification of version $v failed; nothing was installed"
        expect "and the log says why" "$(grep -cF "could not write the staged files to the disk (a disk error?)" "$ROOT/stderr")" "1"
        rm -f "$ROOT/sync-fails"

        # Room: the two files plus the unpacked image, a whole root slot (2560 MiB): 2685 MB here. A stage left full by an interrupted try
        # does not count against it, and a refusal empties it and drops the download.
        prepare
        head -c 4096000 /dev/urandom >"$UPD/stage/left-from-an-earlier-try.raw"
        echo 2048 >"$ROOT/stage-free-kb"
        if stage_apply; then bad "an update with no room to stage it was installed"; fi
        expect "with no room to stage it, nothing is written and update.json says why, in MB" \
            "$(installed) $(status update '[.state, .message] | join(" | ")')" \
            "0 failed | not enough free space on the data partition to install version $v (2685 MB needed, 2 MB free); nothing was installed"
        expect "and the stage is emptied and the download dropped, so their room comes back" "$(stage_left) $(find "$UPD/cache" -mindepth 1 | wc -l | tr -d ' ')" "0 0"
        prepare
        head -c 4096000 /dev/urandom >"$UPD/stage/left-from-an-earlier-try.raw"
        echo 2625000 >"$ROOT/stage-free-kb"
        if stage_apply; then pass "with room for it once the stage is emptied (2687 MB, 4 MB of it held by an interrupted try), the update is installed"
        else bad "an interrupted try's leftovers counted against the room: $(status update .message)"; fi
        rm -f "$ROOT/stage-free-kb" "$ROOT/download-ok"
    fi
else
    echo "skip  staging (needs dpkg, flock, minisign and zstd: run in the static checks' container)"
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
