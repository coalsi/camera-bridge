#!/bin/bash
# Tests Tools/fetch-go2rtc.sh against a local folder instead of GitHub: the real release files (pass their folder as SOURCE_DIR, or let
# the test make files of its own for the failure cases). Run: Tools/test-fetch-go2rtc.sh [SOURCE_DIR]
# SOURCE_DIR holds go2rtc_mac_arm64.zip and go2rtc_mac_amd64.zip as released; without it only the failure cases run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/fetch-go2rtc.sh"
SOURCE_DIR="${1:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fetch-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

run() {  # run NAME BASE CACHE OUTPUT [args…]; sets $status and $log
  local base="$1" cache="$2" output="$3"; shift 3
  log="$(CB_GO2RTC_BASE_URL="$base" CB_GO2RTC_CACHE="$cache" "$SCRIPT" --output "$output" "$@" 2>&1)"
  status=$?
}

# 1. Files whose checksum is not the pinned one are refused, and nothing is installed.
mkdir -p "$WORK/bad"
echo "not a zip" > "$WORK/bad/go2rtc_mac_arm64.zip"
echo "not a zip" > "$WORK/bad/go2rtc_mac_amd64.zip"
run "file://$WORK/bad" "$WORK/cache1" "$WORK/out1"
if [ $status -ne 0 ] && echo "$log" | grep -q "CHECKSUM MISMATCH" && [ ! -e "$WORK/out1/go2rtc" ] && [ -z "$(ls "$WORK/cache1" 2>/dev/null)" ]; then
  pass "a download that does not match the pinned checksum is refused and not kept"
else
  fail "a bad download was accepted ($status): $log"
fi

# 2. A missing file fails.
run "file://$WORK/nothing-here" "$WORK/cache2" "$WORK/out2"
[ $status -ne 0 ] && [ ! -e "$WORK/out2/go2rtc" ] && pass "a missing download fails" || fail "a missing download did not fail"

# 3. --verify fetches nothing and fails on an empty cache.
run "file://$WORK/bad" "$WORK/cache3" "$WORK/out3" --verify
[ $status -ne 0 ] && [ ! -d "$WORK/cache3" ] && pass "--verify fetches nothing" || fail "--verify fetched or passed ($status)"

if [ -n "$SOURCE_DIR" ]; then
  # 4. The real files: accepted, built into a universal binary, the version stamp written.
  run "file://$SOURCE_DIR" "$WORK/cache4" "$WORK/out4"
  if [ $status -eq 0 ] && [ -x "$WORK/out4/go2rtc" ] && lipo -archs "$WORK/out4/go2rtc" | grep -q arm64 && lipo -archs "$WORK/out4/go2rtc" | grep -q x86_64; then
    pass "the pinned release is accepted and built into a universal binary"
  else
    fail "the real release was not accepted ($status): $log"
  fi
  # 5. A second run reuses the cache and the binary, and works with no source at all.
  run "file://$WORK/nothing-here" "$WORK/cache4" "$WORK/out4"
  [ $status -eq 0 ] && echo "$log" | grep -q "up to date" && pass "a second run needs nothing from the network" || fail "second run ($status): $log"
  # 6. --verify passes on the finished state.
  run "file://$WORK/nothing-here" "$WORK/cache4" "$WORK/out4" --verify
  [ $status -eq 0 ] && pass "--verify passes on a good cache" || fail "--verify failed ($status): $log"
  # 7. A damaged cache entry is noticed (and replaced from the source when it is there).
  echo "damaged" >> "$WORK/cache4/go2rtc_mac_arm64.zip"
  run "file://$WORK/nothing-here" "$WORK/cache4" "$WORK/out4" --verify
  [ $status -ne 0 ] && pass "a damaged cache entry fails --verify" || fail "damage not noticed"
  run "file://$SOURCE_DIR" "$WORK/cache4" "$WORK/out5"
  [ $status -eq 0 ] && [ -x "$WORK/out5/go2rtc" ] && pass "a damaged cache entry is downloaded again" || fail "no repair ($status): $log"
  # 8. The built binary runs and reports the pinned version.
  if "$WORK/out5/go2rtc" -v 2>&1 | grep -q "go2rtc version 1.9.14"; then pass "the binary reports the pinned version"; else fail "binary does not run or reports another version"; fi
fi

[ $failures -eq 0 ] && echo "all fetch tests passed" || echo "$failures fetch test(s) failed"
exit $failures
