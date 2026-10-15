#!/bin/bash
# The NVR soak and its fault scenarios (task T15). One orchestrator: it starts load cameras, a throwaway daemon, a stand-in for systemd's notify socket,
# a sampler and scripted browsers, runs a schedule, stops everything, checks the recordings on disk and writes a verdict.
#
#   Tools/nvr-soak/run-soak.sh --scenario soak|kill9|crash-images|hang|startup-hang [options]
#
#   --target mac|container|attach   where the daemon runs (default mac). container: the Linux daemon in the cb-linux-swift container (OrbStack).
#                                   attach: a daemon that already runs (a box); soak only. Needs --base URL, --password-file F and
#                                     --pid-cmd "ssh cb@box pidof camerabridged"   --probe-cmd "ssh cb@box"   [--platform linux]
#                                     --log-cmd "ssh cb@box journalctl -u camerabridged -o cat --no-pager -S @EPOCH"
#                                     --restarts-cmd "ssh cb@box systemctl show camerabridged -p NRestarts --value"
#   --bin PATH          the camerabridged to run (a release build!). mac: a path on this Mac; container: a path inside it (default /cache/build/release/camerabridged, or
#                       a copy under the worktree, which the container sees at the same path)
#   --minutes N         length of the soak (default 120; at least 2)       --cameras N (8)   --clients N (6)   --cap-gb G (20; the retention cap)
#   --seed N            seeds the scripted clients (default 1)             --run-id ID       --keep   keep recordings and clips after the run
#   --like FILE         make the load clips like a camera: the JSON of `node linux/web-dev/soak/budget-from-captures.mjs --like CAPTURE_DIR`
#   --phases FILE       use these phases (the JSON `phases.json` holds: [{name, kind: off|load|storm, from, to}] in seconds, ending at --minutes x 60) instead of the standard schedule
#   --rehearsal         run the stand-in server (linux/web-tests) instead of the daemon: proves that the scripts work together; the verdict never counts
# Environment: SCRATCH (required: the session's scratchpad folder; everything is made under $SCRATCH/soak), CB_SOAK_PORT (18090), CB_SOAK_HAP_PORT (24400),
#   CB_SOAK_RTSP_PORT (18554), CB_GO2RTC (the go2rtc helper). Exit status 0 only when every rule of the verdict passes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/../.." && pwd)"
SOAK="$WT/linux/web-dev/soak"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SCENARIO=soak; TARGET=mac; BIN=""; MINUTES=120; CAMERAS=8; CLIENTS=6; CAP=20; SEED=1; RUN_ID=""; KEEP=0; LIKE=""; REHEARSAL=0; PHASES_FILE=""
BASE_ATTACH=""; PASSWORD_FILE=""; PROBE_CMD_ATTACH=""; PID_CMD=""; LOG_CMD=""; RESTARTS_CMD=""; PLATFORM_ATTACH=linux
while [ $# -gt 0 ]; do
    case "$1" in
        --scenario) SCENARIO="$2"; shift 2 ;;       --target) TARGET="$2"; shift 2 ;;       --bin) BIN="$2"; shift 2 ;;
        --minutes) MINUTES="$2"; shift 2 ;;         --cameras) CAMERAS="$2"; shift 2 ;;     --clients) CLIENTS="$2"; shift 2 ;;
        --cap-gb) CAP="$2"; shift 2 ;;              --seed) SEED="$2"; shift 2 ;;           --run-id) RUN_ID="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;                    --like) LIKE="$2"; shift 2 ;;           --rehearsal) REHEARSAL=1; shift ;;            --phases) PHASES_FILE="$2"; shift 2 ;;
        --base) BASE_ATTACH="$2"; shift 2 ;;        --password-file) PASSWORD_FILE="$2"; shift 2 ;;
        --probe-cmd) PROBE_CMD_ATTACH="$2"; shift 2 ;;  --pid-cmd) PID_CMD="$2"; shift 2 ;; --log-cmd) LOG_CMD="$2"; shift 2 ;; --restarts-cmd) RESTARTS_CMD="$2"; shift 2 ;;
        --platform) PLATFORM_ATTACH="$2"; shift 2 ;;
        -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) die "unknown option $1 (try --help)" ;;
    esac
done
case "$SCENARIO" in soak|kill9|crash-images|hang|startup-hang) ;; *) die "unknown scenario $SCENARIO" ;; esac
case "$TARGET" in mac|container|attach) ;; *) die "unknown target $TARGET" ;; esac
[ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] || die "set SCRATCH to the session's scratchpad folder (everything this script makes lives under \$SCRATCH/soak)"
[ "$TARGET" = attach ] && [ "$SCENARIO" != soak ] && die "--target attach runs the soak scenario only (the fault scenarios start, kill and hang the daemon)"
[ "$TARGET" = container ] && [ "$SCENARIO" = crash-images ] && die "crash-images runs on the Mac only (it edits the recordings with Node, which the container does not have); the container proves kill9 and hang"
[ "$REHEARSAL" = 1 ] && [ "$TARGET" != mac ] && die "--rehearsal runs on the Mac only"

RUN_ID="${RUN_ID:-$SCENARIO-$(date +%Y%m%d-%H%M%S)}"
RUN="$SCRATCH/soak/$RUN_ID"; OUT="$RUN/out"; REC="$RUN/data/recordings"
[ -e "$RUN" ] && die "$RUN already exists: a run folder is used once (choose another --run-id)"
PORT="${CB_SOAK_PORT:-18090}"; HAP="${CB_SOAK_HAP_PORT:-24400}"; RTSP_PORT="${CB_SOAK_RTSP_PORT:-18554}"
CONTAINER="cbsoak-$RUN_ID"; VOLUME="cbsoak-data-$RUN_ID"
BASE="http://127.0.0.1:$PORT"; SRC_HOST=127.0.0.1; PLATFORM=darwin; PROBE_CMD=sh
if [ "$TARGET" = container ]; then SRC_HOST=host.docker.internal; PLATFORM=linux; PROBE_CMD="docker exec -i $CONTAINER"; [ -n "$BIN" ] || BIN=/cache/build/release/camerabridged; fi
if [ "$TARGET" = attach ]; then BASE="$BASE_ATTACH"; PLATFORM="$PLATFORM_ATTACH"; PROBE_CMD="$PROBE_CMD_ATTACH"; fi
[ "$REHEARSAL" = 1 ] && BIN="$WT/linux/web-tests/soak-fixture-daemon.sh"
URL_TEMPLATE="rtsp://$SRC_HOST:$RTSP_PORT/load{n}"
RESULT=1
DECODE=6; SETTLE_A=45; SETTLE_B=45; SETTLE_C=60
if [ "$REHEARSAL" = 1 ]; then DECODE=0; SETTLE_A=3; SETTLE_B=3; SETTLE_C=3; fi

cleanup() {
    set +e
    if [ -f "$RUN/pids" ]; then while read -r pid; do kill "$pid" 2>/dev/null; done < "$RUN/pids"; fi
    if [ "$TARGET" != attach ] && [ -f "$RUN/.soak-run" ]; then
        daemon_ctl stop >/dev/null 2>&1 || daemon_ctl kill9 >/dev/null 2>&1
        daemon_ctl unlisten >/dev/null 2>&1
        [ "$REHEARSAL" = 1 ] || bash "$HERE/load-sources.sh" stop "$RUN/src" >/dev/null 2>&1
    fi
    [ "$TARGET" = container ] && container_down
    if [ -f "$RUN/.soak-run" ]; then
        rm -f "$RUN/session.json" "$RUN/pw" "$RUN/setup-token"
        if [ "$KEEP" != 1 ] && [ "$TARGET" != attach ]; then safe_rm_rf "$RUN/src/clips"; [ "$TARGET" = mac ] && safe_rm_rf "$RUN/data" ; safe_rm_rf "$RUN/rec.saved"; fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- preflight, setup -------------------------------------------------------------------------------------------------------------------------
preflight() {
    need node "Node 20 or later"; node -e 'process.exit(parseInt(process.versions.node) >= 20 ? 0 : 1)' || die "Node 20 or later is required"
    need curl "curl"; need lsof "lsof"; need nc "nc"
    if [ "$REHEARSAL" != 1 ] && [ "$TARGET" != attach ]; then need ffmpeg "ffmpeg makes the load clips"; need ffprobe "ffprobe"; fi
    [ "$TARGET" = attach ] || { port_busy "$PORT" && die "port $PORT is in use (set CB_SOAK_PORT)"; }
    if [ "$REHEARSAL" != 1 ] && [ "$TARGET" != attach ]; then port_busy "$RTSP_PORT" && die "port $RTSP_PORT is in use (set CB_SOAK_RTSP_PORT)"; fi
    case "$TARGET" in
        mac)
            [ -x "$BIN" ] || die "--bin PATH to a built camerabridged is required (swift build -c release --product camerabridged --scratch-path \$SB)" ;;
        container)
            need docker "the Linux container"; docker info >/dev/null 2>&1 || die "the container engine is not running"
            # The worktree is mounted too: --bin may be a copy of the build inside it (build/ is ignored by git), which frees the shared volume for other builds.
            docker run --rm -v cb-linux-build:/cache:ro --mount "type=bind,source=$WT,target=$WT,readonly" cb-linux-swift test -x "$BIN" \
                || die "$BIN is neither in the container's cb-linux-build volume nor in the worktree (sh Tools/linux-test.sh build -c release --product camerabridged)" ;;
        attach)
            [ -n "$BASE" ] && [ -f "${PASSWORD_FILE:-/nonexistent}" ] || die "--target attach needs --base URL and --password-file FILE"
            [ -n "$PID_CMD" ] || die "--target attach needs --pid-cmd (a command that prints the daemon's pid, e.g. \"ssh cb@box pidof camerabridged\")" ;;
    esac
    if [ "$TARGET" = mac ] && [ "$REHEARSAL" != 1 ]; then
        local total_kb free_kb need_kb floor_kb
        read -r total_kb free_kb <<EOD
$(df -k "$SCRATCH" | awk 'NR == 2 { print $2, $4 }')
EOD
        floor_kb=$(( total_kb / 20 > 8 * 1048576 ? total_kb / 20 : 8 * 1048576 ))   # the daemon pauses below max(8 GiB, 5%) free
        need_kb=$(( CAP * 1000000 / 1024 + floor_kb + 12 * 1048576 ))
        [ "$free_kb" -ge "$need_kb" ] || die "not enough disk: $((free_kb / 1048576)) GiB free, need $((need_kb / 1048576)) GiB (cap $CAP GB + the daemon's floor $((floor_kb / 1048576)) GiB + 12 GiB for clips, open files and margin). Free some space or lower --cap-gb (10 is the least the daemon accepts)"
    fi
}

setup_run() {
    mkdir -p "$RUN/src" "$OUT" "$RUN/notify" "$RUN/bin"
    : > "$RUN/.soak-run"; : > "$RUN/pids"
    (umask 077; rand_hex 18 > "$RUN/pw"; rand_hex 8 > "$RUN/setup-token")
    chmod 600 "$RUN/pw" "$RUN/setup-token"
    say "run $RUN_ID: scenario $SCENARIO, target $TARGET, $CAMERAS cameras, cap $CAP GB; folder $RUN"
}

write_daemon_env() {
    { echo "BIN=$BIN"; echo "PORT=$PORT"; echo "HAP=$HAP"; echo "WEB=$WT/linux/web"; echo "DEV=$([ "$TARGET" = mac ] && echo 1 || echo 0)"; echo "DAEMON_ARGS="; } > "$RUN/daemon.env"
    rm -f "$RUN/extra.env"
}

start_sources() {
    [ "$REHEARSAL" = 1 ] && return 0
    local like=""; [ -n "$LIKE" ] && like="--like $LIKE"
    say "making $CAMERAS load clips (about a minute)"
    # shellcheck disable=SC2086
    bash "$HERE/load-sources.sh" clips "$RUN/src" "$CAMERAS" $like || die "the load clips could not be made"
    bash "$HERE/load-sources.sh" start "$RUN/src" "$CAMERAS" || die "the load cameras could not start"
}

build_helpers() { daemon_ctl build || die "the helpers could not be compiled (cc or clang is required on the daemon's side)"; }

start_infra() {
    daemon_ctl listen || die "the notify listener did not start"
    say "starting the daemon"
    daemon_ctl start || die "the daemon did not start"
    wait_for 90 "the daemon to answer /health" api_ready || { tail -n 20 "$OUT/daemon.log"; die "the daemon did not come up"; }
}

prepare_cameras() {
    say "adding $CAMERAS cameras and turning Record on"
    node "$SOAK/prepare.mjs" --base "$BASE" --password-file "$RUN/pw" --setup-token-file "$RUN/setup-token" --out "$RUN" --cameras "$CAMERAS" \
        --url-template "$URL_TEMPLATE" --cap-gb "$CAP" --wait-sec 240 || die "preparing the cameras failed"
}

# Starts the sampler and the clients, all against the same clock. $1: seconds of observation; $2: the clients' extra flags.
begin_observation() {
    END="$1"; local client_flags="${2:-}"
    rm -f "$RUN/stop"
    T0=$(( $(ms_now) + 4000 ))
    if [ -n "$PHASES_FILE" ]; then cp "$PHASES_FILE" "$OUT/phases.json" || die "cannot read --phases $PHASES_FILE"; else node "$SOAK/meta.mjs" phases --end-sec "$END" --out "$OUT/phases.json"; fi
    node "$SOAK/meta.mjs" create --out "$OUT/meta.json" --run-id "$RUN_ID" --target "$TARGET" --scenario "$SCENARIO" --t0 "$T0" --end-sec "$END" --port "$PORT" --cameras "$CAMERAS" \
        --seed "$SEED" --cap-gb "$CAP" --root "$REC" --phases "$OUT/phases.json" --rehearsal "$REHEARSAL"
    local pid; pid="$(daemon_pid)"
    node "$SOAK/sampler.mjs" --base "$BASE" --session "$RUN/session.json" --t0 "$T0" --end-sec "$END" --out "$OUT/samples.ndjson" --pid "$pid" --port "$PORT" --platform "$PLATFORM" \
        --probe-script "$HERE/probe.sh" --probe-cmd "$PROBE_CMD" --stop-file "$RUN/stop" > "$OUT/sampler.log" 2>&1 &
    echo $! >> "$RUN/pids"; SAMPLER_PID=$!
    CLIENT_PIDS=""
    local i=1 style
    while [ "$i" -le "$CLIENTS" ]; do
        style=polite; [ "$i" -gt $((CLIENTS - 2)) ] && [ "$CLIENTS" -ge 3 ] && style=aggressive    # the last two ignore Retry-After
        # shellcheck disable=SC2086
        node "$SOAK/client.mjs" --base "$BASE" --session "$RUN/session.json" --id "$i" --seed $((SEED * 1000 + i)) --style "$style" --t0 "$T0" --phases "$OUT/phases.json" \
            --out "$OUT/client-$i.ndjson" --end-sec "$END" --stop-file "$RUN/stop" $client_flags > "$OUT/client-$i.log" 2>&1 &
        echo $! >> "$RUN/pids"; CLIENT_PIDS="$CLIENT_PIDS $!"
        i=$((i + 1))
    done
    say "observation started: $END s, $CLIENTS clients, sampler on pid $SAMPLER_PID"
}

# Waits until the observation is over (clients and sampler end by themselves), reporting once a minute, with a hard deadline.
wait_observation() {
    local deadline=$(( T0 / 1000 + END + 120 )) last=0 now elapsed
    while :; do
        now=$(date +%s); [ "$now" -ge "$deadline" ] && { say "the observation did not end by itself: stopping it"; break; }
        local running=0 p
        for p in $SAMPLER_PID $CLIENT_PIDS; do kill -0 "$p" 2>/dev/null && running=$((running + 1)); done
        [ "$running" -eq 0 ] && break
        if [ "$TARGET" != attach ] && ! daemon_alive; then say "THE DAEMON IS NOT RUNNING any more; ending the observation"; DAEMON_DIED=1; touch "$RUN/stop"; break; fi
        elapsed=$(( now - T0 / 1000 ))
        if [ $((now - last)) -ge 60 ]; then last=$now; say "t=${elapsed}s of $END, $running of $((CLIENTS + 1)) tools running"; fi
        sleep 5
    done
}

stop_daemon_timed() {
    local s0 s1 ok=true
    s0=$(ms_now); daemon_ctl stop || ok=false; s1=$(ms_now)
    node "$SOAK/meta.mjs" patch --out "$OUT/meta.json" --json "{\"shutdown\":{\"seconds\":$(( (s1 - s0) / 100 ))e-1,\"ok\":$ok}}"
}

analyze_soak() {
    sleep 2
    node "$SOAK/analyze.mjs" --run "$OUT" --secrets "$RUN/pw,$RUN/setup-token,$RUN/session.json"; RESULT=$?
    say "verdict: $OUT/results.md"
}

# ---- scenarios ---------------------------------------------------------------------------------------------------------------------------------
scenario_soak() {
    local END_SEC=$((MINUTES * 60))
    [ "$MINUTES" -ge 2 ] || die "--minutes must be at least 2"
    if [ "$TARGET" = attach ]; then
        mkdir -p "$OUT" "$RUN/notify"
        node "$SOAK/prepare.mjs" --base "$BASE" --password-file "$PASSWORD_FILE" --out "$RUN" --login-only --wait-sec 60 || die "could not sign in to $BASE"
        echo "$($PID_CMD | head -n 1)" > "$RUN/daemon.pid"
        CAMERAS="$(node -p "require('$RUN/cameras.json').length")"
        [ "$CAMERAS" -gt 0 ] || die "no camera on $BASE records: turn Record on for the cameras first"
        local before; before=""; [ -n "$RESTARTS_CMD" ] && before="$($RESTARTS_CMD | head -n 1)"
        begin_observation "$END_SEC"
        wait_observation
        local after=""; [ -n "$RESTARTS_CMD" ] && after="$($RESTARTS_CMD | head -n 1)"
        [ -n "$LOG_CMD" ] && ${LOG_CMD//@EPOCH/$(( T0 / 1000 ))} > "$OUT/daemon.log" 2>/dev/null
        node "$SOAK/meta.mjs" patch --out "$OUT/meta.json" --json "{\"systemd\":{\"restartsBefore\":${before:-null},\"restartsAfter\":${after:-null}},\"shutdown\":{\"seconds\":0,\"ok\":true}}"
        node "$SOAK/analyze.mjs" --run "$OUT" --secrets "$RUN/session.json"; RESULT=$?
        return
    fi
    begin_observation "$END_SEC"
    wait_observation
    say "stopping the daemon"
    stop_daemon_timed
    # After a clean stop every file is closed: one without a sidecar is a defect.
    verify_tree "$OUT/verify.json" --sample 24 --decode "$DECODE" --allow-open 0 > /dev/null 2>&1
    [ -s "$OUT/verify.json" ] || echo '{"closed":0,"open":0,"checked":0,"decoded":0,"problems":["the verifier produced no output"]}' > "$OUT/verify.json"
    analyze_soak
}

# Shared start of the fault scenarios: three minutes of recording with two changes of the sound switch, so that every camera has closed files and an open one.
record_with_closed_files() {
    say "recording for 150 s; the sound switch changes twice so that files close"
    sleep "$SETTLE_A"; node "$SOAK/cameras-nvr.mjs" --base "$BASE" --session "$RUN/session.json" --cameras "$RUN/cameras.json" --set sound --to on
    sleep "$SETTLE_B"; node "$SOAK/cameras-nvr.mjs" --base "$BASE" --session "$RUN/session.json" --cameras "$RUN/cameras.json" --set sound --to off
    sleep "$SETTLE_C"
}

write_scenario_meta() {
    T0=$(( $(ms_now) )); END=0
    node "$SOAK/meta.mjs" create --out "$OUT/meta.json" --run-id "$RUN_ID" --target "$TARGET" --scenario "$SCENARIO" --t0 "$T0" --end-sec 1 --port "$PORT" --cameras "$CAMERAS" --seed "$SEED" --cap-gb "$CAP" --root "$REC" --rehearsal "$REHEARSAL"
}

scenario_kill9() {
    write_scenario_meta
    record_with_closed_files
    node "$SOAK/scenario-check.mjs" snapshot --base "$BASE" --session "$RUN/session.json" --out "$OUT/before.json" || die "could not take the snapshot"
    KILL_WALL=$(ms_now)
    say "kill -9"
    daemon_ctl kill9
    sleep 1
    list_unclosed > "$OUT/unclosed-before.txt"
    say "$(wc -l < "$OUT/unclosed-before.txt" | tr -d ' ') files were open"
    START_WALL=$(ms_now)
    daemon_ctl start || die "the daemon did not start again"
    wait_for 120 "the daemon to answer /health" api_ready || die "no /health after the restart"
    local health_s=$(( ($(ms_now) - START_WALL) / 1000 ))
    wait_for 180 "the archive to be ready" archive_ready; local ready_s=$(( ($(ms_now) - START_WALL) / 1000 ))
    say "health after ${health_s}s, archive ready after ${ready_s}s"
    node "$SOAK/scenario-check.mjs" recovery --base "$BASE" --session "$RUN/session.json" --before "$OUT/before.json" --kill-wall "$KILL_WALL" --out "$OUT/recovery.json" --recover-sec 90; local r1=$?
    daemon_ctl stop; local stopped=$?
    verify_tree "$OUT/verify.json" --sample 0 --decode "$DECODE" --allow-open 0 --must-be-closed "$OUT/unclosed-before.txt" > /dev/null 2>&1; local r2=$?
    cat "$OUT/verify.json"
    # The first health answer must come long before the unit's 120 s start timeout; READY itself is checked in the soak's watchdog rule.
    local r3=0; [ "$health_s" -le 15 ] || { say "FAIL: /health took ${health_s}s after the restart (budget 15 s)"; r3=1; }
    [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$r3" -eq 0 ] && [ "$stopped" -eq 0 ] && RESULT=0
    say "kill9: archive ready ${ready_s}s after start; recovery $([ $r1 -eq 0 ] && echo pass || echo FAIL), files $([ $r2 -eq 0 ] && echo sound || echo DAMAGED)"
}

scenario_crash_images() {
    write_scenario_meta
    record_with_closed_files
    say "kill -9, then nine ways a power cut can leave the recordings"
    daemon_ctl kill9; sleep 1
    cp -cR "$REC" "$RUN/rec.saved" 2>/dev/null || cp -R "$REC" "$RUN/rec.saved" || die "could not copy the recordings"
    local variants="cut-mdat cut-moof cut-prft cut-boundary zero-tail zero-last lose-sidecar bad-sidecar stale-sidecar" v n=0 failures=0
    : > "$OUT/crash-images.txt"
    for v in $variants; do
        n=$((n + 1))
        safe_rm_rf "$REC"
        cp -cR "$RUN/rec.saved" "$REC" 2>/dev/null || cp -R "$RUN/rec.saved" "$REC"
        node "$SOAK/damage.mjs" --root "$REC" --variant "$v" --seed "$n" > "$OUT/damage-$v.jsonl" || die "damage $v failed"
        list_unclosed > "$OUT/unclosed-$v.txt"
        START_WALL=$(ms_now)
        daemon_ctl start || die "the daemon did not start ($v)"
        wait_for 90 "/health ($v)" api_ready || { say "FAIL $v: no /health"; failures=$((failures + 1)); daemon_ctl kill9; continue; }
        wait_for 240 "the archive to be ready ($v)" archive_ready; local ready_s=$(( ($(ms_now) - START_WALL) / 1000 ))
        sleep 5
        daemon_ctl stop
        verify_tree "$OUT/crash-$v.json" --sample 0 --decode "$DECODE" --allow-open 0 --must-be-closed "$OUT/unclosed-$v.txt" --damaged "$OUT/damage-$v.jsonl" > /dev/null 2>&1; local ok=$?
        [ "$ok" -eq 0 ] || failures=$((failures + 1))
        echo "$v: archive ready after ${ready_s}s, files $([ $ok -eq 0 ] && echo repaired || echo 'NOT REPAIRED')" | tee -a "$OUT/crash-images.txt"
        [ "$ok" -eq 0 ] || cat "$OUT/crash-$v.json"
    done
    [ "$failures" -eq 0 ] && RESULT=0
    say "crash-images: $failures of 9 variants failed (summary: $OUT/crash-images.txt)"
}

scenario_hang() {
    local END_SEC=420 HANG_START=120 HANG_END=270
    begin_observation "$END_SEC" "--tolerate-slow 1"
    node "$SOAK/scenario-check.mjs" hang-drive --flag "$RUN/hang.flag" --t0 "$T0" --hang-start "$HANG_START" --hang-end "$HANG_END" --base "$BASE" --session "$RUN/session.json" --out "$OUT/hang.json" &
    local drive=$!; echo $drive >> "$RUN/pids"
    wait_observation
    wait "$drive"
    node "$SOAK/scenario-check.mjs" hang-check --run "$OUT" --hang "$OUT/hang.json"; local r1=$?
    daemon_ctl stop; local stopped=$?
    verify_tree "$OUT/verify.json" --sample 12 --decode "$DECODE" --allow-open 0 > /dev/null 2>&1; local r2=$?
    cat "$OUT/verify.json"
    [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && [ "$stopped" -eq 0 ] && RESULT=0
}

scenario_startup_hang() {
    write_scenario_meta
    say "recording for 60 s, then a clean stop"
    sleep "$SETTLE_C"
    daemon_ctl stop || die "the daemon did not stop"
    write_shim_env
    : > "$RUN/hang.flag"
    START_WALL=$(ms_now)
    say "starting the daemon with the recordings folder hung"
    daemon_ctl start || die "the daemon did not start"
    if ! wait_for 30 "/health while the folder hangs" api_ready; then
        say "the daemon does not answer /health 30 s after its start with the folder hung: the startup checks below say what else is wrong"
        # Where it waits: the stacks of its threads (macOS `sample`), the evidence for whoever owns the call. Only symbol names, no data.
        if [ "$TARGET" = mac ] && command -v sample >/dev/null 2>&1; then sample "$(daemon_pid)" 3 -file "$OUT/startup-hung.sample.txt" >/dev/null 2>&1 || true; fi
    fi
    node "$SOAK/scenario-check.mjs" startup --base "$BASE" --session "$RUN/session.json" --flag "$RUN/hang.flag" --start-wall "$START_WALL" --run "$OUT" --hang-sec 45 --cameras "$CAMERAS" --out "$OUT/startup.json"; local r1=$?
    daemon_ctl stop; local stopped=$?
    [ "$r1" -eq 0 ] && [ "$stopped" -eq 0 ] && RESULT=0
}

# ---- main -------------------------------------------------------------------------------------------------------------------------------------
preflight
setup_run
if [ "$TARGET" = attach ]; then
    scenario_soak
else
    write_daemon_env
    [ "$TARGET" = container ] && container_up
    start_sources
    build_helpers
    case "$SCENARIO" in
        hang|startup-hang) hangshim_selftest || die "the hang shim does not stop the file calls on this platform: no hung-volume result can be trusted" ;;
    esac
    [ "$SCENARIO" = hang ] && write_shim_env     # the shim is loaded from the start; it does nothing until the flag file exists
    start_infra
    prepare_cameras
    case "$SCENARIO" in
        soak) scenario_soak ;;
        kill9) scenario_kill9 ;;
        crash-images) scenario_crash_images ;;
        hang) scenario_hang ;;
        startup-hang) scenario_startup_hang ;;
    esac
fi
[ "$REHEARSAL" = 1 ] && say "REHEARSAL: this proves the scripts work together, nothing about the daemon"
say "$SCENARIO: $([ "$RESULT" -eq 0 ] && echo PASS || echo FAIL) (files in $OUT)"
exit "$RESULT"
