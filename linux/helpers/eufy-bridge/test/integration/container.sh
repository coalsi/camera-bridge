#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC2086  # the checks are strings for eval: they expand there, and use these variables
# Exercise the built helper (/opt/eufy-bridge) in fake mode with curl, inside the test container.
set -u
B=${EUFY_BRIDGE:-/opt/eufy-bridge/eufy-bridge}   # run.sh sets it for the image layout
TOKEN=itest-token-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
PORT=18080
ST=/tmp/eufy-state
LOG=/tmp/eufy.log
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
api() { curl -s -H "Authorization: Bearer $TOKEN" "$@"; }

export CB_EUFY_TOKEN="$TOKEN" CB_EUFY_STATE_DIR="$ST" CB_EUFY_FAKE=1 CB_EUFY_FFMPEG=/usr/bin/ffmpeg

# 1. Bad configuration → 2
CB_EUFY_LISTEN=0.0.0.0:$PORT "$B" 2>/tmp/bad.log; rc=$?
check "non-loopback listen refused with exit 2 (got $rc)" '[ $rc -eq 2 ]'
CB_EUFY_LISTEN=127.0.0.1:$PORT CB_EUFY_TOKEN=short "$B" 2>/dev/null; rc=$?
check "short token refused with exit 2 (got $rc)" '[ $rc -eq 2 ]'

start() {
  N0=$(grep -c "event=listening port=$PORT" "$LOG" 2>/dev/null || true)
  N0=${N0:-0}
  CB_EUFY_LISTEN=127.0.0.1:$PORT "$B" 2>>"$LOG" &
  PID=$!
  for i in $(seq 1 50); do [ "$(grep -c "event=listening port=$PORT" "$LOG" 2>/dev/null || true)" -gt "$N0" ] && return 0; sleep 0.1; done
  return 1
}
rm -rf "$ST" "$LOG"
start; check "starts and prints event=listening port=$PORT" '[ $? -eq 0 ]'
check "node is the pinned one" 'head -1 "${EUFY_DIR:-/opt/eufy-bridge}/VERSION" >/dev/null && grep -q "event=start .*node=${NODE_VERSION:?}" "$LOG"'

# 2. Port taken → 5
CB_EUFY_LISTEN=127.0.0.1:$PORT "$B" 2>/tmp/dup.log; rc=$?
check "second instance on a taken port exits 5 (got $rc)" '[ $rc -eq 5 ]'

# 3. Auth
check "status without token is 401" '[ "$(curl -s -o /dev/null -w %{http_code} 127.0.0.1:$PORT/status)" = 401 ]'
check "stream with wrong token is 401" '[ "$(curl -s -o /dev/null -w %{http_code} 127.0.0.1:$PORT/stream/nope-nope-nope-nope/T8134FAKE0000001)" = 401 ]'
check "status signedOut" '[ "$(api 127.0.0.1:$PORT/status)" = "{\"state\":\"signedOut\"}" ]'

# 4. Sign-in with captcha
R=$(api -X POST 127.0.0.1:$PORT/sign-in -d '{"email":"owner@example.com","password":"captcha","country":"US"}')
check "sign-in → needsCaptcha" 'echo "$R" | grep -q "\"state\":\"needsCaptcha\""'
ID=$(echo "$R" | sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p')
R=$(api -X POST 127.0.0.1:$PORT/captcha -d "{\"id\":\"$ID\",\"answer\":\"1234\"}")
check "captcha 1234 → signedIn" '[ "$R" = "{\"state\":\"signedIn\",\"account\":\"owner@example.com\"}" ]'
check "state lines logged" 'grep -q "event=state state=needsCaptcha" "$LOG" && grep -q "event=state state=signedIn" "$LOG"'
R=$(api 127.0.0.1:$PORT/devices)
check "devices lists the fake SoloCam" '[ "$R" = "{\"devices\":[{\"serial\":\"T8134FAKE0000001\",\"name\":\"Fake SoloCam\",\"model\":\"T8134\",\"type\":63,\"online\":true,\"battery\":87,\"livestream\":true,\"codec\":\"h264\"}]}" ]'

# 5. Events
api -N 127.0.0.1:$PORT/events > /tmp/events.ndjson &
EV=$!
sleep 0.5
api -X POST 127.0.0.1:$PORT/fake/motion >/dev/null
sleep 0.5
kill $EV 2>/dev/null
check "events: hello first" 'head -1 /tmp/events.ndjson | grep -q "\"kind\":\"hello\""'
check "events: motion line" 'grep -q "{\"serial\":\"T8134FAKE0000001\",\"kind\":\"motion\",\"at\":\"" /tmp/events.ndjson'
check "stderr: camera event line" 'grep -Eq "^cb-eufy event=camera serial=T8134FAKE0000001 kind=motion at=[0-9T:.-]+Z$" "$LOG"'

# 6. Snapshot
sleep 1
curl -s -o /tmp/snap.jpg -w '%{http_code} %{content_type}' 127.0.0.1:$PORT/snapshot/$TOKEN/T8134FAKE0000001 > /tmp/snap.status
check "snapshot is image/jpeg ($(cat /tmp/snap.status))" 'grep -q "200 image/jpeg" /tmp/snap.status && [ "$(head -c 2 /tmp/snap.jpg | od -An -tx1 | tr -d " ")" = ffd8 ]'

# 7. Stream → ffprobe
curl -s --max-time 9 -o /tmp/live.ts -D /tmp/live.h 127.0.0.1:$PORT/stream/$TOKEN/T8134FAKE0000001
END=$(date +%s)
check "stream content-type video/mp2t" 'grep -qi "content-type: video/mp2t" /tmp/live.h'
S=$(ffprobe -v error -show_entries stream=codec_name,width,height -of csv=p=0 /tmp/live.ts | sort -u | tr "\n" " ")
check "ffprobe: h264 1280x720 + aac ($S)" 'echo "$S" | grep -q "aac" && echo "$S" | grep -q "h264,1280,720"'
for i in $(seq 1 50); do grep -q "event=fake_camera serial=T8134FAKE0000001 camera=asleep" "$LOG" && break; sleep 0.1; done
check "camera stopped within 5 s of the reader leaving" '[ $(( $(date +%s) - END )) -le 5 ] && grep -q "event=stream_end serial=T8134FAKE0000001 reason=no_clients" "$LOG"'
check "first_video logged after ~2 s wake" 'grep -Eq "event=first_video serial=T8134FAKE0000001 ms=(19|2[0-9]|3[0-9])[0-9]{2} codec=h264 audio=aac" "$LOG"'

# 8. Two readers share one livestream
BEFORE=$(grep -c "event=stream_start" "$LOG")
curl -s --max-time 8 -o /tmp/a.ts 127.0.0.1:$PORT/stream/$TOKEN/T8134FAKE0000001 &
A=$!
sleep 3
curl -s --max-time 4 -o /tmp/b.ts 127.0.0.1:$PORT/stream/$TOKEN/T8134FAKE0000001
wait $A
AFTER=$(grep -c "event=stream_start" "$LOG")
check "two overlapping readers → one stream_start ($BEFORE → $AFTER)" '[ $((AFTER - BEFORE)) -eq 1 ]'
S=$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 /tmp/b.ts | sort -u | tr "\n" " ")
check "late joiner gets decodable h264 + aac ($S)" 'echo "$S" | grep -q aac && echo "$S" | grep -q h264'

# 9. Files and secrets
check "state dir 0700" '[ "$(stat -c %a "$ST")" = 700 ]'
check "state files 0600" '[ -z "$(find "$ST" -type f ! -perm 600)" ]'
check "token never logged" '! grep -q "$TOKEN" "$LOG"'

# 10. SIGTERM → 0, restart keeps the session
kill -TERM $PID; wait $PID; rc=$?
check "SIGTERM exits 0 (got $rc)" '[ $rc -eq 0 ] && grep -q "event=stopped" "$LOG"'
start
R=$(api 127.0.0.1:$PORT/status)
check "restart: still signedIn ($R)" '[ "$R" = "{\"state\":\"signedIn\",\"account\":\"owner@example.com\"}" ]'
R=$(api -X POST 127.0.0.1:$PORT/sign-out)
check "sign-out" '[ "$R" = "{\"state\":\"signedOut\"}" ]'
kill -TERM $PID; wait $PID

# 11. Real mode (no Eufy traffic): the bundled SDK loads, starts signed out, refuses data calls.
R=$(CB_EUFY_SELFTEST=1 "$B")
check "self-test: SDK + protobufjs load from the bundle ($R)" 'echo "$R" | grep -q "\"protobuf\":\"loaded\""'
( unset CB_EUFY_FAKE; CB_EUFY_LISTEN=127.0.0.1:18090 CB_EUFY_STATE_DIR=/tmp/eufy-real "$B" 2>/tmp/real.log ) &
RP=$!
for i in $(seq 1 50); do grep -q "event=listening" /tmp/real.log 2>/dev/null && break; sleep 0.1; done
check "real mode: signedOut" '[ "$(api 127.0.0.1:18090/status)" = "{\"state\":\"signedOut\"}" ]'
check "real mode: devices before sign-in is 409" '[ "$(curl -s -o /dev/null -w %{http_code} -H "Authorization: Bearer $TOKEN" 127.0.0.1:18090/devices)" = 409 ]'
check "real mode: fake endpoint absent (404)" '[ "$(curl -s -o /dev/null -w %{http_code} -X POST -H "Authorization: Bearer $TOKEN" 127.0.0.1:18090/fake/motion)" = 404 ]'
kill -TERM $RP; wait $RP; rc=$?
check "real mode: SIGTERM exits 0 (got $rc)" '[ $rc -eq 0 ]'
cat /tmp/real.log

echo "--- helper stderr ---"
cat "$LOG"
echo "--- $FAILS failure(s) ---"
[ $FAILS -eq 0 ]
