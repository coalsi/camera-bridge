#!/bin/sh
# Makes the fixture clips the dev archive server repeats: fragmented MP4, video only, H.264 (one H.265), a 90 kHz time scale, with the
# fragments cut like the recorder cuts them (at every keyframe and after 2.5 s). Each clip ends where a group of pictures ends, so it can
# be played again and again. Pictures are ffmpeg's test pattern (it draws the time and the frame number in the top left corner).
#
# Usage: sh linux/web-dev/make-fixtures.sh [--force]      writes linux/web-dev/fixtures/<name>.mp4 and <name>.jpg (CB_FIXTURE_DIR overrides)
# Needs ffmpeg and ffprobe with libx264 and an H.265 encoder (libx265, or hevc_videotoolbox on a Mac). Nothing else is read or written.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${CB_FIXTURE_DIR:-$HERE/fixtures}
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

need() { command -v "$1" >/dev/null 2>&1 || { echo "make-fixtures: $1 is not installed." >&2; exit 2; }; }
need ffmpeg
need ffprobe
ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)
echo "$ENCODERS" | grep -q libx264 || { echo "make-fixtures: this ffmpeg has no libx264." >&2; exit 2; }
HEVC=
echo "$ENCODERS" | grep -q libx265 && HEVC=libx265
[ -z "$HEVC" ] && echo "$ENCODERS" | grep -q hevc_videotoolbox && HEVC=hevc_videotoolbox
[ -n "$HEVC" ] || { echo "make-fixtures: this ffmpeg has no H.265 encoder (libx265 or hevc_videotoolbox)." >&2; exit 2; }

mkdir -p "$OUT"
FRAG="-movflags +frag_keyframe+empty_moov+default_base_moof+skip_trailer -frag_duration 2500000 -video_track_timescale 90000 -an"

# make_h264 NAME SIZE RATE SECONDS GOP_FRAMES KBPS PROFILE
make_h264() {
  name=$1; size=$2; rate=$3; seconds=$4; gop=$5; kbps=$6; profile=$7
  [ "$FORCE" = 0 ] && [ -s "$OUT/$name.mp4" ] && [ "$OUT/$name.mp4" -nt "$0" ] && return 0
  echo "make-fixtures: $name"
  # shellcheck disable=SC2086
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=$size:rate=$rate:duration=$seconds" \
    -c:v libx264 -preset veryfast -profile:v "$profile" -pix_fmt yuv420p -bf 0 -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
    -b:v "${kbps}k" -maxrate "${kbps}k" -bufsize "$((kbps * 2))k" $FRAG -f mp4 "$OUT/$name.mp4.partial.$$"
  mv "$OUT/$name.mp4.partial.$$" "$OUT/$name.mp4"
}

make_hevc() {
  name=hevc
  [ "$FORCE" = 0 ] && [ -s "$OUT/$name.mp4" ] && [ "$OUT/$name.mp4" -nt "$0" ] && return 0
  echo "make-fixtures: $name ($HEVC)"
  if [ "$HEVC" = libx265 ]; then
    CODEC="-c:v libx265 -preset veryfast -x265-params keyint=50:min-keyint=50:scenecut=0:bframes=0:log-level=error"
  else
    CODEC="-c:v hevc_videotoolbox -g 50 -bf 0"
  fi
  # shellcheck disable=SC2086
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=20" \
    $CODEC -tag:v hvc1 -pix_fmt yuv420p -b:v 800k $FRAG -f mp4 "$OUT/$name.mp4.partial.$$"
  mv "$OUT/$name.mp4.partial.$$" "$OUT/$name.mp4"
}

# name        size      rate         seconds gop  kbps  profile
make_h264 gop2    640x360   25           60  50   800   main
make_h264 hd      1280x720  25           40  50   4000  high
make_h264 longgop 640x360   25           60  300  800   main
make_h264 ntsc    640x360   30000/1001   60.06 60 800   main
make_hevc
make_h264 res-b   960x540   25           30  50   900   main
make_h264 quiet   320x180   25           30  50   200   baseline

for name in gop2 hd longgop ntsc hevc res-b quiet; do
  if [ "$FORCE" = 1 ] || [ ! -s "$OUT/$name.jpg" ] || [ "$OUT/$name.mp4" -nt "$OUT/$name.jpg" ]; then
    ffmpeg -hide_banner -loglevel error -y -ss 3.2 -i "$OUT/$name.mp4" -frames:v 1 -q:v 5 "$OUT/$name.jpg"
  fi
done
echo "make-fixtures: done in $OUT"
