#!/bin/bash
# Soaks and measures the Mac app's NVR against the real engine, without touching the installed app. Everything happens in a
# measurement build (bundle identifier com.coreysilvia.CameraBridge.nvrtest, process name CameraBridgeNVRTest) that runs
# `-isolatedEngine` (App/Sources/Model/IsolatedEngine.swift): demo cameras, throwaway data, loopback only, ports from 38100.
#
#   CB_SOAK_ROOT=<new directory in the session scratchpad> Tools/nvr-soak.sh build        # the measurement build
#   CB_SOAK_ROOT=...                                       Tools/nvr-soak.sh run          # 2 h soak, kill -9 at minute 60, relaunch, quit, verify
#   CB_SOAK_ROOT=...                                       Tools/nvr-soak.sh yank         # a drive pulled while recording, then plugged in again
#   CB_SOAK_ROOT=...                                       Tools/nvr-soak.sh probe all    # the budget scenarios (or: keyframe,exact), 9 demo cameras
#   CB_SOAK_ROOT=...                                       Tools/nvr-soak.sh ui           # the manager window over 9 recording demo cameras (attended checks)
#   CB_SOAK_ROOT=...                                       Tools/nvr-soak.sh startup      # a recordings folder on the startup volume: its free space and floor, 90 s
#   CB_SOAK_ROOT=...                                       Tools/nvr-soak.sh external /Volumes/NAME [probe all]   # the `run` (or the probes) on a drive the owner named (owner only)
#   Tools/nvr-soak.sh selftest                                                           # the guards, with nothing started
#
# Environment (all optional except CB_SOAK_ROOT): CB_SOAK_APP (default $CB_SOAK_ROOT/dd/Build/Products/Release/CameraBridgeNVRTest.app),
# CB_SOAK_MINUTES=120, CB_SOAK_KILL_AT=60 (0: no kill), CB_SOAK_CAMERAS=8, CB_SOAK_IMAGE_GB=24, CB_SOAK_CLASSIC=1 (the renderer path of macOS 15
# and 26), CB_SOAK_UI_MINUTES=45, CB_SOAK_MAX_GB=10 (the retention cap; `probe` uses 18 so that retention does not trim the footage a scenario is choosing its targets in), CB_SOAK_NO_FOLDER=1 (no folder chosen yet: the first Record asks), CB_SOAK_PACKAGES (a copy of build/SourcePackages for an offline build), CB_SOAK_SIGN=- (ad-hoc signing).
#
# What it never does: write outside CB_SOAK_ROOT and the disk image mounted in it (the `external` run writes one new folder on the drive it was
# given), touch the owner's ~/Library/Application Support/CameraBridge or Containers, find a process by name (only by the path of its own build),
# kill anything but that process, wait without a deadline, or continue when the Data volume has less than 40 GiB free.

set -euo pipefail

BUNDLE_ID="com.coreysilvia.CameraBridge.nvrtest"
PRODUCT="CameraBridgeNVRTest"
TEAM_ID="${TEAM_ID:-XL4RAH5J96}"
DATA_VOLUME="/System/Volumes/Data"
MIN_FREE_KB=$((40 * 1024 * 1024))
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "nvr-soak: $*" >&2; exit 3; }
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

# ------------------------------------------------------------------------------------------------------------------------------ guards

# True (0) when `path` is somewhere a run must not write.
forbidden_root() {
  case "$1" in
    "$HOME"|"$HOME/"|"$HOME/Library"*|"$HOME/Documents"*|"$HOME/Desktop"*|"$HOME/Movies"*|"$HOME/Downloads"*|/Volumes/*|/|/System*|/Library*|/Users|/Applications*) return 0 ;;
  esac
  return 1
}

need_root() {
  [ -n "${CB_SOAK_ROOT:-}" ] || die "set CB_SOAK_ROOT to a new directory in the session scratchpad"
  case "$CB_SOAK_ROOT" in /*) ;; *) die "CB_SOAK_ROOT must be a full path" ;; esac
  case "$CB_SOAK_ROOT" in *..*) die "CB_SOAK_ROOT must not contain .." ;; esac
  ! forbidden_root "$CB_SOAK_ROOT" || die "CB_SOAK_ROOT is somewhere a run must not write: $CB_SOAK_ROOT"
  if [ -d "$CB_SOAK_ROOT" ] && [ -n "$(ls -A "$CB_SOAK_ROOT" 2>/dev/null)" ] && [ ! -f "$CB_SOAK_ROOT/.nvr-soak-root" ]; then
    die "$CB_SOAK_ROOT is not empty and was not made by this script"
  fi
  mkdir -p "$CB_SOAK_ROOT"
  touch "$CB_SOAK_ROOT/.nvr-soak-root"
  ROOT="$(cd "$CB_SOAK_ROOT" && pwd -P)"
}

free_kb() {
  if [ -n "${CB_SOAK_FAKE_AVAIL_KB:-}" ]; then echo "$CB_SOAK_FAKE_AVAIL_KB"; return; fi
  df -k "$DATA_VOLUME" | awk 'NR==2{print $4}'
}

disk_ok() { [ "$(free_kb)" -ge "$MIN_FREE_KB" ]; }

need_app() {
  APP="${CB_SOAK_APP:-$ROOT/dd/Build/Products/Release/$PRODUCT.app}"
  [ -d "$APP" ] || die "no measurement build at $APP (run: Tools/nvr-soak.sh build)"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
    || die "$APP is not a $BUNDLE_ID build"
}

# The process id of our own build (found by the path of its executable, never by name).
APP=""
pid_of() { [ -n "$APP" ] || return 0; pgrep -f "$APP/Contents/MacOS/$PRODUCT" | head -1 || true; }

kill_ours() {
  local pid cmd
  pid="$(pid_of)"
  [ -n "$pid" ] || return 0
  cmd="$(ps -o command= -p "$pid" || true)"
  case "$cmd" in "$APP/Contents/MacOS/$PRODUCT"*) ;; *) die "refusing to kill $pid: it is not our build ($cmd)" ;; esac
  kill -9 "$pid"
}

wait_gone() { # seconds
  local deadline=$(( $(date +%s) + $1 ))
  while [ -n "$(pid_of)" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
  [ -z "$(pid_of)" ]
}

# ---------------------------------------------------------------------------------------------------------------------------- the volume

IMAGE=""; MNT=""; FOLDER=""; IMG_DEV=""

make_volume() { # a sparse disk image mounted inside ROOT: a pulled drive is `diskutil unmount force` plus an eject of its disk
  IMAGE="$ROOT/soak.sparsebundle"; MNT="$ROOT/mnt"
  mkdir -p "$MNT"
  diskutil image create blank --format UDSB --size "${CB_SOAK_IMAGE_GB:-24}g" --volumeName CBNVRSoak --fs APFS "$IMAGE" >/dev/null
  attach_volume
  mkdir -p "$MNT/Recordings"
  FOLDER="$MNT/Recordings"
}

attach_volume() { IMG_DEV="$(diskutil image attach --nobrowse --mountPoint "$MNT" "$IMAGE" | awk '/Apple_APFS_Container/{print $1}')"; }

pull_volume() { # what the app sees when a drive is unplugged: its open files fail with EIO, the folder is gone
  diskutil unmount force "$MNT" >/dev/null
  if [ -n "$IMG_DEV" ]; then diskutil eject "$IMG_DEV" >/dev/null 2>&1 || true; fi
}

drop_volume() {
  [ -n "$MNT" ] || return 0
  if mount | grep -q " on $MNT "; then
    diskutil eject "$MNT" >/dev/null 2>&1 || diskutil unmount force "$MNT" >/dev/null 2>&1 || true
  elif [ -n "$IMG_DEV" ]; then
    diskutil eject "$IMG_DEV" >/dev/null 2>&1 || true
  fi
  rm -rf "$IMAGE"
}

# What every command does when it ends, however it ends: stops our own build, ejects the image, removes the one folder an `external` run made.
CLEANUP_FOLDER=""
cleanup() {
  kill_ours || true
  wait_gone 10 || true
  drop_volume
  case "$CLEANUP_FOLDER" in /Volumes/?*/CameraBridge-NVR-soak-*) rm -rf "$CLEANUP_FOLDER" ;; esac
}

# ----------------------------------------------------------------------------------------------------------------------------- launching

# launch <extra app arguments...>: a new instance of OUR build, with the isolated engine. In the background (`open -g`) unless CB_SOAK_FOREGROUND=1;
# without the recordings folder argument when CB_SOAK_NO_FOLDER=1 (the first Record then asks for one, as it does for a person).
launch() {
  local env=() front=(-g) folder=(-isolatedNVRFolder "$FOLDER")
  [ "${CB_SOAK_CLASSIC:-0}" = 1 ] && env=(--env CAMERABRIDGE_CLASSIC_RENDERER=1)
  [ "${CB_SOAK_FOREGROUND:-0}" = 1 ] && front=()
  [ "${CB_SOAK_NO_FOLDER:-0}" = 1 ] && folder=()
  local keys=()
  [ -n "${CB_SOAK_DEMO_KEYFRAME:-}" ] && keys=(-isolatedDemoKeyframeSeconds "$CB_SOAK_DEMO_KEYFRAME")   # a smart-codec stream: the demo cameras key every N s
  open -n ${front[@]+"${front[@]}"} ${env[@]+"${env[@]}"} -a "$APP" --args \
    -isolatedEngine "$ROOT/data" -isolatedDemoCameras "${CB_SOAK_CAMERAS:-8}" ${folder[@]+"${folder[@]}"} ${keys[@]+"${keys[@]}"} \
    -isolatedKeepDays 1 -isolatedMaxGB "${CB_SOAK_MAX_GB:-10}" -isolatedBasePort 38100 "$@"
  local deadline=$(( $(date +%s) + 30 ))
  while [ -z "$(pid_of)" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
  [ -n "$(pid_of)" ] || die "the measurement build did not start (see: log show --last 2m --predicate 'process == \"$PRODUCT\"')"
  log "started $(pid_of)"
}

sample() { # one line of process and disk numbers
  local pid rss cpu used mp4 idx
  pid="$(pid_of)"; [ -n "$pid" ] || return 1
  read -r rss cpu <<<"$(ps -o rss=,%cpu= -p "$pid" | awk '{print $1, $2}')"
  used="$(du -sk "$FOLDER" 2>/dev/null | awk '{print $1}')"
  mp4="$(find "$FOLDER" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')"
  idx="$(find "$FOLDER" -name '*.cbidx' 2>/dev/null | wc -l | tr -d ' ')"
  echo "$(date +%s),$pid,${rss:-0},${cpu:-0},${used:-0},$mp4,$idx,$(free_kb),$(df -k "$FOLDER" 2>/dev/null | awk 'NR==2{print $4+0}')" >> "$ROOT/samples.csv"
}

# ------------------------------------------------------------------------------------------------------------------------------ commands

cmd_build() {
  need_root
  local identity sign="${CB_SOAK_SIGN:-}" src
  if [ -z "$sign" ]; then
    identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    [ -n "$identity" ] || die "no 'Apple Development' identity; set CB_SOAK_SIGN=- for an ad-hoc build"
    sign="$identity"
  fi
  disk_ok || die "less than 40 GiB free on the Data volume"
  # A copy of the sources with another bundle identifier and product name, so that the build can never be mistaken for the installed app (the
  # name and identifier cannot be overridden on the xcodebuild command line: the package targets would take them too).
  src="$ROOT/src"
  mkdir -p "$src"
  rsync -a --delete --exclude .git --exclude .build --exclude build --exclude Reference --exclude Interop --exclude docs --exclude linux \
    --exclude Tools/captures --exclude CameraBridge.xcodeproj "$REPO_ROOT/" "$src/"
  python3 -I - "$src/project.yml" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
for pattern, replacement in [(r"(PRODUCT_BUNDLE_IDENTIFIER: )com\.coreysilvia\.CameraBridge\n", r"\1com.coreysilvia.CameraBridge.nvrtest\n"),
                             (r"(PRODUCT_NAME: )CameraBridge\n", r"\1CameraBridgeNVRTest\n"),
                             (r"(CFBundleDisplayName: )Camera Bridge\n", r"\1Camera Bridge NVR Test\n"),
                             (r"(CFBundleName: )Camera Bridge\n", r"\1Camera Bridge NVR Test\n"),
                             (r"(        Release:\n          CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO\n)", r'\1          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG $(inherited)"\n')]:
    text, count = re.subn(pattern, replacement, text)
    assert count == 1, "project.yml: %s matched %d times" % (pattern, count)
open(path, "w").write(text)
PY
  (cd "$src" && xcodegen generate >/dev/null)
  rm -rf "$ROOT/dd/Build/Products/Release/$PRODUCT.app"   # a failed build must not leave the previous one to be taken for the new one
  # Release (optimised, so the numbers mean something) with DEBUG on for the app target only (the copy’s project.yml says so; a command line
  # override would also replace the compilation conditions that SwiftPM packages such as swift-crypto set for themselves).
  xcodebuild build -project "$src/CameraBridge.xcodeproj" -scheme CameraBridge -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$ROOT/dd" ${CB_SOAK_PACKAGES:+-clonedSourcePackagesDirPath "$CB_SOAK_PACKAGES" -disableAutomaticPackageResolution} \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$sign" "DEVELOPMENT_TEAM=$([ "$sign" = "-" ] && echo "" || echo "$TEAM_ID")" \
    2>&1 | tee "$ROOT/build.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  APP="$ROOT/dd/Build/Products/Release/$PRODUCT.app"
  need_app
  log "built $APP"
  { codesign -d --entitlements :- "$APP" 2>/dev/null | grep -o 'com.apple.security[a-z.-]*' | sort | tr '\n' ' '; echo; } || true
}

cmd_run() { # the soak
  need_root; need_app
  local minutes="${CB_SOAK_MINUTES:-120}" kill_at="${CB_SOAK_KILL_AT:-60}" killed=0 started end relaunched=0 measured_loss=0
  disk_ok || die "less than 40 GiB free on the Data volume"
  [ -n "$(pid_of)" ] && die "a $PRODUCT is already running"
  rm -rf "$ROOT/data" "$ROOT/samples.csv" "$ROOT/events.log"
  echo "ts,pid,rss_kb,cpu,used_kb,mp4,cbidx,free_data_kb,free_vol_kb" > "$ROOT/samples.csv"
  trap cleanup EXIT
  if [ -z "$FOLDER" ]; then make_volume; fi
  started="$(date +%s)"
  echo "$started launch-1" >> "$ROOT/events.log"
  launch -isolatedHeartbeatSeconds 10 -isolatedQuitAfterMinutes "$minutes" -isolatedRecordAfterSeconds 180
  end=$(( started + minutes * 60 + 600 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    if [ -z "$(pid_of)" ]; then log "the app exited"; break; fi
    sample || true
    if ! disk_ok; then log "the Data volume is below 40 GiB free: stopping"; echo "$(date +%s) disk-guard" >> "$ROOT/events.log"; break; fi
    if [ "$kill_at" -gt 0 ] && [ "$killed" = 0 ] && [ $(( $(date +%s) - started )) -ge $(( kill_at * 60 )) ]; then
      echo "$(date +%s) kill-9" >> "$ROOT/events.log"
      log "kill -9 at minute $kill_at"
      kill_ours; wait_gone 15 || die "the killed app is still there"
      killed=1; sleep 2
      echo "$(date +%s) launch-2" >> "$ROOT/events.log"
      launch -isolatedHeartbeatSeconds 10 -isolatedQuitAfterMinutes $(( minutes - kill_at ))
      relaunched="$(date +%s)"
    fi
    # The footage lost at the kill, read 100 s after the relaunch (the repair is done; retention has not yet deleted the files around the kill).
    if [ "$relaunched" -gt 0 ] && [ "$measured_loss" = 0 ] && [ $(( $(date +%s) - relaunched )) -ge 100 ]; then
      measured_loss=1
      python3 -I "$REPO_ROOT/Tools/nvr_soak_report.py" killloss "$FOLDER" "$(awk '$2=="kill-9"{print $1}' "$ROOT/events.log" | head -1)" > "$ROOT/kill-loss.txt" || true
    fi
    sleep 30
  done
  echo "$(date +%s) end" >> "$ROOT/events.log"
  wait_gone 60 || { echo "$(date +%s) quit-hung" >> "$ROOT/events.log"; kill_ours; }
  sleep 70   # a file that was open when the process died is repaired once it has been quiet for 60 s
  python3 -I "$REPO_ROOT/Tools/nvr_soak_report.py" soak "$ROOT"
  local kill_ts; kill_ts="$(awk '$2=="kill-9"{print $1}' "$ROOT/events.log" | head -1)"
  python3 -I "$REPO_ROOT/Tools/nvr_soak_report.py" verify "$FOLDER" ${kill_ts:+--kill-ts "$kill_ts"} || true
  [ -s "$ROOT/kill-loss.txt" ] && cat "$ROOT/kill-loss.txt"
}

cmd_yank() { # pull the drive while recording, then plug it in again
  need_root; need_app
  disk_ok || die "less than 40 GiB free on the Data volume"
  [ -n "$(pid_of)" ] && die "a $PRODUCT is already running"
  rm -rf "$ROOT/data" "$ROOT/samples.csv" "$ROOT/events.log"
  echo "ts,pid,rss_kb,cpu,used_kb,mp4,cbidx,free_data_kb,free_vol_kb" > "$ROOT/samples.csv"
  trap cleanup EXIT
  make_volume
  CB_SOAK_CAMERAS="${CB_SOAK_CAMERAS:-2}" launch -isolatedHeartbeatSeconds 1 -isolatedQuitAfterMinutes 8 -nvrProbe drivehold   # a viewer plays recorded footage during the pull
  sleep 150; sample || true
  echo "$(date +%s) yank" >> "$ROOT/events.log"; log "pulling the drive"
  pull_volume
  sleep 75; sample || true
  echo "$(date +%s) replug" >> "$ROOT/events.log"; log "plugging the drive in"
  attach_volume
  sleep 90; sample || true
  wait_gone 150 || kill_ours
  sleep 70
  python3 - "$ROOT" <<'PY'
import json, sys
root = sys.argv[1]
beats = [json.loads(l) for l in open(root + "/data/probe/heartbeat.jsonl") if l.strip()]
events = {}
for line in open(root + "/events.log"):
    ts, name = line.split()[:2]
    events[name] = float(ts)
def states(beat): return [c["state"] for c in beat["cameras"]]
yank, replug = events["yank"], events["replug"]
paused = next((b["t"] for b in beats if b["t"] >= yank and any(s.startswith("paused") for s in states(b))), None)
back = next((b["t"] for b in beats if b["t"] >= replug and all(s == "recording" for s in states(b))), None)
issue = next((b["issue"] for b in beats if b["t"] >= yank and b.get("issue")), None)
def after(moment, since):
    return "never" if moment is None else "%.1f s after" % (moment - since)
print("- first camera paused: %s the drive was pulled (about 6 s expected: a write error or the 5 s probe, plus the status tick)" % after(paused, yank))
print("- banner while the drive was away: %s" % (issue or "none"))
print("- every camera recording again: %s the drive came back (the 5 s probe plus the next keyframe)" % after(back, replug))
print("- the app survived: %s" % ("yes" if beats and beats[-1]["t"] > replug + 60 else "no"))
import os
hold_path = root + "/data/probe/drivehold.json"
if not os.path.exists(hold_path):
    print("- viewer: NOT RUN (no probe/drivehold.json: the scenario did not finish)")
else:
    samples = json.load(open(hold_path)).get("samples", [])
    gone = next((x["t"] for x in samples if x["t"] >= yank and x["coverage"] == "driveMissing"), None)
    away = [x for x in samples if gone is not None and gone + 2 <= x["t"] <= replug]
    moved = (max(x["position"] for x in away) - min(x["position"] for x in away)) if away else None
    kept = bool(away) and all(x["shows"] for x in away)
    resumed = next((x["t"] for x in samples if x["t"] >= replug and x["coverage"] != "driveMissing" and away and x["position"] > away[-1]["position"] + 1), None)
    print("- viewer: the cell said driveMissing: %s the drive was pulled (the buffered picture plays out first; about 10 s expected)" % after(gone, yank))
    print("- viewer: the last picture stayed while the drive was away: %s" % ("yes" if kept else "no (or never driveMissing)"))
    print("- viewer: the clock stood still while the drive was away: %s" % ("yes (moved %.2f s)" % moved if moved is not None and moved < 0.5 else "no (moved %s s)" % moved))
    print("- viewer: playing again: %s the drive came back (the 5 s probe: expect 5 to 10 s)" % after(resumed, replug))
PY
  python3 -I "$REPO_ROOT/Tools/nvr_soak_report.py" verify "$FOLDER" || true
}

cmd_ui() { # the app with its manager window over nine demo cameras that record to the image, for the attended checks (CB_SOAK_UI_MINUTES, default 45)
  need_root; need_app
  disk_ok || die "less than 40 GiB free on the Data volume"
  [ -n "$(pid_of)" ] && die "a $PRODUCT is already running"
  rm -rf "$ROOT/data" "$ROOT/samples.csv" "$ROOT/events.log"
  echo "ts,pid,rss_kb,cpu,used_kb,mp4,cbidx,free_data_kb,free_vol_kb" > "$ROOT/samples.csv"
  trap cleanup EXIT
  make_volume
  local minutes="${CB_SOAK_UI_MINUTES:-45}"
  CB_SOAK_FOREGROUND=1 CB_SOAK_CAMERAS=9 launch -openManager YES -isolatedHeartbeatSeconds 2 -isolatedQuitAfterMinutes "$minutes"
  log "the manager window is open: use it for $minutes minutes (the first 10 minutes only build the timeline); the recordings are in $FOLDER"
  local deadline=$(( $(date +%s) + minutes * 60 + 300 ))
  while [ -n "$(pid_of)" ] && [ "$(date +%s)" -lt "$deadline" ]; do sample || true; disk_ok || { log "disk guard"; break; }; sleep 15; done
  wait_gone 20 || kill_ours
}

cmd_startup() { # a recordings folder on the startup volume: what the engine measures there and whether the floor stops it (90 s, one camera)
  need_root; need_app
  disk_ok || die "less than 40 GiB free on the Data volume"
  [ -n "$(pid_of)" ] && die "a $PRODUCT is already running"
  rm -rf "$ROOT/data" "$ROOT/startup-rec"
  mkdir "$ROOT/startup-rec"
  FOLDER="$ROOT/startup-rec"
  trap cleanup EXIT
  CB_SOAK_CAMERAS=1 launch -isolatedHeartbeatSeconds 2 -isolatedQuitAfterMinutes 1.5
  wait_gone 150 || kill_ours
  python3 - "$ROOT" <<'PY'
import json, sys
beats = [json.loads(l) for l in open(sys.argv[1] + "/data/probe/heartbeat.jsonl") if l.strip()]
ready = [b for b in beats if b["ready"] and b["storage"]]
last = (ready or beats)[-1]
storage, camera = last["storage"], last["cameras"][0] if last["cameras"] else {}
gib = lambda v: "%.1f GiB" % (v / 1073741824) if v is not None else "none"
print("- the engine's numbers for a folder on the startup volume: total %s, free %s, floor %s, pause %s" % (gib(storage.get("total")), gib(storage.get("free")), gib(storage.get("floor")), storage.get("pause")))
print("- camera state %s; banner %s" % (camera.get("state"), last.get("issue") or "none"))
print("- compare with Foundation (step 9): available vs important-usage decides which number the engine reads; the Mac startup floor is max(20 GiB, min(10% of total, 50 GiB)), ArchivePlatformPolicy.macStartupFloor")
PY
}

cmd_probe() { # probe <scenarios>
  need_root; need_app
  disk_ok || die "less than 40 GiB free on the Data volume"
  [ -n "$(pid_of)" ] && die "a $PRODUCT is already running"
  local scenarios="${1:-all}"
  rm -rf "$ROOT/data"
  trap cleanup EXIT
  if [ -z "$FOLDER" ]; then make_volume; fi
  # The cap is 18 GB here, not 10: with 9 cameras recording the 10 GB cap trims the oldest footage while a scenario is still choosing its targets in it.
  CB_SOAK_MAX_GB="${CB_SOAK_MAX_GB:-18}" CB_SOAK_CAMERAS=9 launch -nvrProbe "$scenarios" -isolatedHeartbeatSeconds 10 -isolatedRecordAfterSeconds 0
  local deadline=$(( $(date +%s) + 3600 ))
  while [ -n "$(pid_of)" ] && [ "$(date +%s)" -lt "$deadline" ]; do sample || true; sleep 15; done
  wait_gone 20 || kill_ours
  python3 -I "$REPO_ROOT/Tools/nvr_soak_report.py" budgets "$ROOT/data/probe"
}

cmd_external() { # external /Volumes/NAME [probe SCENARIOS]: the soak (or the probes) on a drive the owner named; one new folder on it, removed at the end
  need_root; need_app
  local volume="${1:-}" what="${2:-run}"
  case "$volume" in /Volumes/?*) ;; *) die "external needs a mounted volume: /Volumes/NAME" ;; esac
  [ -d "$volume" ] || die "$volume is not mounted"
  [ "$(df -k "$volume" | awk 'NR==2{print $4}')" -ge $((60 * 1024 * 1024)) ] || die "$volume has less than 60 GiB free"
  diskutil info -plist "$volume" > "$ROOT/volume.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Internal' "$ROOT/volume.plist")" = false ] || die "$volume is an internal volume"
  echo "solid state: $(/usr/libexec/PlistBuddy -c 'Print :SolidState' "$ROOT/volume.plist" 2>/dev/null || echo unknown)"
  FOLDER="$volume/CameraBridge-NVR-soak-$(date +%Y%m%d-%H%M%S)"
  [ ! -e "$FOLDER" ] || die "$FOLDER exists"
  mkdir "$FOLDER"
  CLEANUP_FOLDER="$FOLDER"
  case "$what" in
    probe) cmd_probe "${3:-all}" ;;
    *) cmd_run ;;
  esac
}

cmd_selftest() {
  local fails=0
  check() { if "$@"; then :; else echo "selftest FAILED: $*"; fails=$((fails + 1)); fi; }
  check forbidden_root "$HOME"
  check forbidden_root "$HOME/Library/Application Support/CameraBridge"
  check forbidden_root "/Volumes/Backup/x"
  check forbidden_root "$HOME/Movies/soak"
  check forbidden_root "/"
  check eval '! forbidden_root /private/tmp/claude-501/x/scratchpad/soak'
  check eval '! forbidden_root /private/tmp/x'
  CB_SOAK_FAKE_AVAIL_KB=$((39 * 1024 * 1024)) check eval '! disk_ok'
  CB_SOAK_FAKE_AVAIL_KB=$((41 * 1024 * 1024)) check disk_ok
  check eval '[ "$(free_kb)" -gt 0 ]'
  local scratch; scratch="$(mktemp -d "${TMPDIR:-/tmp}/nvr-soak-selftest.XXXXXX")"
  mkdir "$scratch/stranger"; touch "$scratch/stranger/file"
  check eval '! ( CB_SOAK_ROOT="$scratch/stranger"; need_root ) >/dev/null 2>&1'
  check eval '( CB_SOAK_ROOT="$scratch/fresh"; need_root; [ -f "$scratch/fresh/.nvr-soak-root" ] ) >/dev/null 2>&1'
  check eval '! ( CB_SOAK_ROOT="relative/dir"; need_root ) >/dev/null 2>&1'
  check eval '! ( CB_SOAK_ROOT="$HOME/Library/x"; need_root ) >/dev/null 2>&1'
  check eval '! ( CB_SOAK_ROOT=""; need_root ) >/dev/null 2>&1'
  rm -rf "$scratch"
  bash -n "$0" || fails=$((fails + 1))
  [ "$fails" = 0 ] && echo "selftest ok" || { echo "selftest: $fails failure(s)"; exit 1; }
}

case "${1:-}" in
  build) cmd_build ;;
  run) cmd_run ;;
  yank) cmd_yank ;;
  ui) cmd_ui ;;
  startup) cmd_startup ;;
  probe) shift; cmd_probe "${1:-all}" ;;
  external) shift; cmd_external "$@" ;;
  selftest) cmd_selftest ;;
  *) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
