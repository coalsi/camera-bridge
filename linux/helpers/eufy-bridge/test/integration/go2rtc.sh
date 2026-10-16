#!/bin/sh
# shellcheck disable=SC2016,SC2034,SC2086  # the checks are strings for eval: they expand there, and use these variables
# Fake-mode helper → go2rtc (pinned commit) as an http:// source → RTSP → ffprobe/ffmpeg.
set -u
B=${EUFY_BRIDGE:-/opt/eufy-bridge/eufy-bridge}   # run.sh sets it for the image layout
TOKEN=g2r-token-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
PORT=18081
LOG=/tmp/eufy-g2r.log
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

export CB_EUFY_TOKEN="$TOKEN" CB_EUFY_STATE_DIR=/tmp/eufy-g2r-state CB_EUFY_FAKE=1 CB_EUFY_FFMPEG=/usr/bin/ffmpeg CB_EUFY_LISTEN=127.0.0.1:$PORT
rm -rf /tmp/eufy-g2r-state "$LOG"
"$B" 2>>"$LOG" &
HP=$!
for i in $(seq 1 50); do grep -q "event=listening" "$LOG" && break; sleep 0.1; done
curl -s -H "Authorization: Bearer $TOKEN" -X POST 127.0.0.1:$PORT/sign-in -d '{"email":"owner@example.com","password":"pw"}' >/dev/null

LINE="solocam: http://127.0.0.1:$PORT/stream/$TOKEN/T8134FAKE0000001"
cat > /tmp/go2rtc.yaml <<EOF
api:
  listen: "127.0.0.1:1984"
rtsp:
  listen: "127.0.0.1:8554"
webrtc:
  listen: ""
log:
  level: info
streams:
  $LINE
EOF
go2rtc -version
go2rtc -config /tmp/go2rtc.yaml > /tmp/go2rtc.log 2>&1 &
GP=$!
for i in $(seq 1 50); do curl -s -o /dev/null 127.0.0.1:1984/api/streams && break; sleep 0.1; done
check "helper idle before anyone watches" '! grep -q "event=stream_start" "$LOG"'

S=$(ffprobe -v error -rtsp_transport tcp -timeout 20000000 -show_entries stream=codec_name,width,height,sample_rate -of csv=p=0 rtsp://127.0.0.1:8554/solocam 2>&1 | sort -u | tr "\n" " ")
check "go2rtc RTSP: ffprobe sees h264 1280x720 + aac 16000 ($S)" 'echo "$S" | grep -q "h264,1280,720" && echo "$S" | grep -q "aac,16000"'

ffmpeg -v error -rtsp_transport tcp -i rtsp://127.0.0.1:8554/solocam -t 6 -c copy -y /tmp/g2r.mp4 2>/tmp/g2r.err
END=$(date +%s)
check "pulled 6 s over RTSP and remuxed (-c copy) cleanly" '[ -s /tmp/g2r.mp4 ] && [ ! -s /tmp/g2r.err ]'
D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/g2r.mp4)
check "recording is ~6 s long ($D)" 'awk "BEGIN{exit !($D > 4.5 && $D < 7.5)}"'
DEC=$(ffmpeg -v error -i /tmp/g2r.mp4 -f null - 2>&1 | grep -v "non monotonically" | head -5)
check "recording decodes without errors" '[ -z "$DEC" ]'

# go2rtc drops an idle producer; the helper must then stop the camera promptly.
for i in $(seq 1 150); do grep -q "event=stream_end" "$LOG" && break; sleep 0.1; done
check "helper stopped the camera after go2rtc let go ($(( $(date +%s) - END )) s)" 'grep -q "event=stream_end serial=T8134FAKE0000001 reason=no_clients" "$LOG" && [ $(( $(date +%s) - END )) -le 15 ]'
check "one livestream for probe + pull" '[ "$(grep -c "event=stream_start" "$LOG")" -le 2 ]'

echo "go2rtc stream line that works: $(echo "$LINE" | sed "s/$TOKEN/<TOKEN>/")"
echo "--- go2rtc log ---"; sed "s/$TOKEN/<TOKEN>/g" /tmp/go2rtc.log | tail -20
echo "--- helper stderr ---"; cat "$LOG"
kill $GP $HP 2>/dev/null; wait 2>/dev/null
echo "--- $FAILS failure(s) ---"
[ $FAILS -eq 0 ]
