#!/bin/sh
# Makes the fixtures of the browser smoke test: three H.264 test clips as fragmented MP4, each split into init.mp4 and one file per fragment.
#   sh linux/web-tests/player-smoke/make-fixtures.sh OUTDIR        (needs ffmpeg and node; OUTDIR must be outside the repository)
set -eu
out="${1:?usage: sh make-fixtures.sh OUTDIR}"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out"

# 1280x720, 25 fps, no B-frames, a keyframe every 2 s and a fragment at every keyframe: every fragment starts a GOP. 20 s.
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=25" -t 20 -c:v libx264 -preset veryfast -profile:v main -level 4.0 -bf 0 -g 50 -keyint_min 50 -sc_threshold 0 -pix_fmt yuv420p \
  -movflags +frag_keyframe+empty_moov+default_base_moof "$out/gop2.mp4"
# The same picture with a keyframe every 8 s and a fragment every 2 s: three of every four fragments continue a GOP. 24 s.
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1280x720:rate=25" -t 24 -c:v libx264 -preset veryfast -profile:v main -level 4.0 -bf 0 -g 200 -keyint_min 200 -sc_threshold 0 -pix_fmt yuv420p \
  -movflags +empty_moov+default_base_moof -frag_duration 2000000 "$out/gop8.mp4"
# Another codec string and size (High profile, 1920x1080), for the codec-change cases. 10 s.
ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1920x1080:rate=25" -t 10 -c:v libx264 -preset veryfast -profile:v high -level 4.1 -bf 0 -g 50 -keyint_min 50 -sc_threshold 0 -pix_fmt yuv420p \
  -movflags +frag_keyframe+empty_moov+default_base_moof "$out/high1080.mp4"

for name in gop2 gop8 high1080; do node "$here/split-fmp4.mjs" "$out/$name.mp4" "$out/$name"; done
