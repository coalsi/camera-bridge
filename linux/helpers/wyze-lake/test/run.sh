#!/bin/sh
# Manual end-to-end check (not part of the build): wyze-lake --self-test pushes test media into a real go2rtc through ffmpeg;
# ffprobe/ffmpeg read the RTSP stream back. The media is made here with ffmpeg (nothing is committed). From linux/helpers/wyze-lake:
#
#   ./build.sh && ../../os/fetch-go2rtc.sh --arch amd64 --output out/go2rtc-amd64 && docker run --rm --platform linux/amd64 \
#     -v "$PWD/out/wyze-lake":/t/wyze-lake:ro -v "$PWD/out/go2rtc-amd64/go2rtc":/t/go2rtc:ro -v "$PWD/test":/t/test:ro \
#     debian:trixie-slim /t/test/run.sh
set -u
apt-get update -qq >/dev/null && apt-get install -y -qq ffmpeg >/dev/null 2>&1
M=/tmp/media
mkdir -p "$M"
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=15 -t 12 -c:v libx265 -preset ultrafast \
    -x265-params keyint=15:bframes=0:repeat-headers=1:log-level=error -f hevc "$M/sample.h265"
ffmpeg -v error -f lavfi -i testsrc2=size=1280x720:rate=15 -t 12 -c:v libx264 -profile:v main -bf 0 -g 15 -f h264 "$M/sample.h264"
ffmpeg -v error -f lavfi -i sine=f=440:r=8000 -t 12 -f mulaw -ar 8000 -ac 1 "$M/sample.ulaw"
ffmpeg -v error -f lavfi -i sine=f=440:r=48000 -t 12 -c:a libopus -b:a 32k -ac 1 "$M/sample.ogg"

/t/go2rtc -config /t/test/go2rtc.yaml >/tmp/go2rtc.log 2>&1 &
sleep 2
for combo in "h265 sample.ulaw" "h265 sample.ogg" "h264 -"; do
  # shellcheck disable=SC2086
  set -- $combo; c=$1; a=$2; [ "$a" = - ] && a=""
  echo "== $c ${a:-no audio}"
  CB_LAKE_OUTPUT=rtsp://127.0.0.1:8554/lake_test CB_LAKE_CODEC=$c CB_LAKE_FFMPEG=/usr/bin/ffmpeg \
    /t/wyze-lake --self-test "$M/sample.$c" ${a:+"$M/$a"} 2>/tmp/lake.log &
  P=$!
  sleep 6
  ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name,profile,width,height,sample_rate,channels -of compact rtsp://127.0.0.1:8554/lake_test
  ffmpeg -v error -rtsp_transport tcp -i rtsp://127.0.0.1:8554/lake_test -t 5 -map 0 -c copy -y /tmp/rec.mkv
  ffprobe -v error -count_frames -show_entries stream=codec_name,nb_read_frames,start_time:format=duration -of compact /tmp/rec.mkv
  echo "decode errors/warnings:"; ffmpeg -v warning -i /tmp/rec.mkv -f null - 2>&1 | head -3
  ffprobe -v error -select_streams v -show_entries packet=pts_time -of csv=p=0 /tmp/rec.mkv | head -4 | tr "\n" " "; echo
  ffprobe -v error -select_streams v -show_entries packet=pts_time -of csv=p=0 /tmp/rec.mkv | awk 'NR>1{d=$1-p; if(d<=0)bad++; s+=d; n++} {p=$1} END{printf "video packets %d, mean interval %.4f s, non-increasing %d\n", n+1, s/n, bad+0}'
  wait $P; echo "wyze-lake exit $?"
  grep -E "cb-lake event=(output|audio|self_test_done|ffmpeg_exit)" /tmp/lake.log
  sleep 2
done
echo "== go2rtc warnings"; grep -i -E "err|warn" /tmp/go2rtc.log | tail -5
