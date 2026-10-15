#!/bin/sh
# Builds the spike fixtures into out/<id>/ (git-ignored): fragmented MP4s shaped like the recorder's files (ftyp+moov, then prft+moof+mdat,
# default-base-is-moof, 90 kHz video timescale, a fragment at every keyframe and after 2.5 s), split into init.mp4 + pNNNN.m4s + manifest.json
# by split-fmp4.mjs. ffmpeg writes its own sample tables (default sample flags), not FMP4Muxer's per-sample ones: pass B of the plan adds
# FMP4Muxer output. Needs ffmpeg (libx264, libx265, aac, drawbox), ffprobe and node.
#
#   sh make-fixtures.sh              build what is missing
#   sh make-fixtures.sh --force      rebuild everything
#   sh make-fixtures.sh bar gop30    build only these
#
# The repo capture (Tools/captures/tapo.h264, git-ignored, so only in the main checkout) is used for `cap`: found through the git common
# directory from a worktree, or set CAMERABRIDGE_TAPO_CAPTURE (a file) or CB_CAPTURE_DIR (a folder holding tapo.h264). Without it `cap` is a
# synthetic stand-in of the same size, rate and GOP (its keyframes are about twice the real 0.64 MB).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${CB_SPIKE_OUT:-$HERE/out}
WORK="$OUT/.work"
FORCE=0
WANT=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) WANT="$WANT $arg" ;;
    esac
done

for tool in ffmpeg ffprobe node; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
done

mkdir -p "$OUT" "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

# The capture lives only in the main checkout (Tools/captures is git-ignored), so look there when this is a worktree.
find_capture() {
    if [ -n "${CAMERABRIDGE_TAPO_CAPTURE:-}" ]; then printf '%s' "$CAMERABRIDGE_TAPO_CAPTURE"; return; fi
    if [ -n "${CB_CAPTURE_DIR:-}" ] && [ -f "$CB_CAPTURE_DIR/tapo.h264" ]; then printf '%s' "$CB_CAPTURE_DIR/tapo.h264"; return; fi
    if [ -f "$HERE/../../../Tools/captures/tapo.h264" ]; then printf '%s' "$HERE/../../../Tools/captures/tapo.h264"; return; fi
    common=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    if [ -n "$common" ] && [ -f "$(dirname "$common")/Tools/captures/tapo.h264" ]; then printf '%s' "$(dirname "$common")/Tools/captures/tapo.h264"; return; fi
    printf ''
}

Q="-hide_banner -loglevel error -y"
MOV="frag_keyframe+empty_moov+default_base_moof"
# shellcheck disable=SC2086
muxer_flags() { printf '%s' "-video_track_timescale 90000 -movflags $MOV -frag_duration 2500000 -write_prft pts -f mp4"; }

# A 16-bit frame counter drawn as 16 black/white blocks of 32 px in the top-left corner (frame n + base), so the page can read back which
# picture is on screen. Blocks are macroblock aligned and survive compression.
barcode_filter() {
    base=$1
    f="drawbox=x=0:y=0:w=512:h=32:color=black:t=fill"
    k=0
    while [ "$k" -lt 16 ]; do
        low=$((1 << k)); high=$((1 << (k + 1)))
        f="$f,drawbox=x=$((k * 32)):y=0:w=32:h=32:color=white:t=fill:enable='gte(mod(n+$base,$high),$low)'"
        k=$((k + 1))
    done
    printf '%s' "$f"
}

check_mime() { # id file: the codec string split-fmp4.mjs derives must equal ffprobe's when ffprobe has one (it has none for HEVC)
    probe=$(ffprobe -v error -select_streams v:0 -show_entries stream=mime_codec_string -of default=nw=1:nk=1 "$2" 2>/dev/null || true)
    mine=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).mime.replace(/^.*codecs="|"$/g, ""))' "$OUT/$1/manifest.json")
    if [ -n "$probe" ] && [ "$probe" != "$mine" ]; then
        echo "mime mismatch for $1: split-fmp4.mjs says $mine, ffprobe says $probe" >&2
        exit 1
    fi
    echo "    codec $mine"
}

finish() { # id source [extra split args...]
    id=$1; source=$2; shift 2
    rm -rf "${OUT:?}/$id"
    node "$HERE/split-fmp4.mjs" "$WORK/$id.mp4" "$OUT/$id" --id "$id" --source "$source" "$@"
    check_mime "$id" "$WORK/$id.mp4"
    rm -f "$WORK/$id.mp4"
}

wanted() { # id -> 0 when this fixture should be built
    if [ -n "$WANT" ]; then case " $WANT " in *" $1 "*) ;; *) return 1 ;; esac; fi
    [ "$FORCE" -eq 1 ] || [ ! -f "$OUT/$1/manifest.json" ]
}

# synth id size rate gop seconds profile level base x264params [crf]
synth() {
    id=$1; size=$2; rate=$3; gop=$4; secs=$5; profile=$6; level=$7; base=$8; xp=$9; crf=${10:-28}
    # shellcheck disable=SC2046,SC2086
    ffmpeg $Q -f lavfi -i "testsrc2=size=$size:rate=$rate" -t "$secs" -vf "$(barcode_filter "$base"),format=yuv420p" \
        -c:v libx264 -preset veryfast -profile:v "$profile" -level "$level" -crf "$crf" -g "$gop" -keyint_min "$gop" \
        -x264-params "scenecut=0:bframes=0:$xp" $(muxer_flags) "$WORK/$id.mp4"
    stored=""
    [ "$id" = bar ] && stored="--stored"      # the stored form (with prft) is only needed once, to see whether browsers accept a prft
    finish "$id" synthetic --barcode-base "$base" $stored
}

# bar: 720p Main 3.1, 20 fps, 2 s GOP, 12 s. The all-purpose fixture; frame identity by barcode.
wanted bar && { echo "==> bar"; synth bar 1280x720 20 40 12 main 3.1 0 ref=1; }
# barB: the same codec string as bar (avc1.4d401f) but another SPS: 960x540 and num_ref_frames 4. Same mime, different init and picture size,
# which is what a camera whose stream settings changed between two files looks like.
wanted barB && { echo "==> barB"; synth barB 960x540 20 40 12 main 3.1 10000 ref=4; }
# barH: 1080p High 4.0: another codec string (avc1.640028) for the mime-change case.
wanted barH && { echo "==> barH"; synth barH 1920x1080 20 40 12 high 4.0 20000 ref=1; }
# ntsc: 30000/1001 fps (3003 ticks per frame), 60-frame GOP.
wanted ntsc && { echo "==> ntsc"; synth ntsc 1280x720 30000/1001 60 12 main 3.1 30000 ref=1; }
# gop30: a 30 s GOP cut into 2.5 s continuation fragments, 65 s.
wanted gop30 && { echo "==> gop30"; synth gop30 1280x720 20 600 65 main 3.1 40000 ref=1 30; }

# av: video + AAC sound (fragments with two trafs); avv: the same video-only (stand-in for ArchiveMedia's output until T03 lands).
if wanted av || wanted avv; then
    echo "==> av"
    # shellcheck disable=SC2046,SC2086
    ffmpeg $Q -f lavfi -i "testsrc2=size=1280x720:rate=20" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 12 \
        -vf "$(barcode_filter 50000),format=yuv420p" -map 0:v -map 1:a \
        -c:v libx264 -preset veryfast -profile:v main -level 3.1 -crf 28 -g 40 -keyint_min 40 -x264-params scenecut=0:bframes=0:ref=1 \
        -c:a aac -b:a 64k -ac 2 $(muxer_flags) "$WORK/av.mp4"
    rm -rf "${OUT:?}/av"
    node "$HERE/split-fmp4.mjs" "$WORK/av.mp4" "$OUT/av" --id av --source synthetic --barcode-base 50000
    check_mime av "$WORK/av.mp4"
    # shellcheck disable=SC2046,SC2086
    ffmpeg $Q -i "$WORK/av.mp4" -map 0:v -c copy $(muxer_flags) "$WORK/avv.mp4"
    rm -f "$WORK/av.mp4"
    finish avv synthetic --barcode-base 50000
fi

# hevc: HEVC Main (hvc1), 720p, 20 fps, 2 s GOP.
wanted hevc && {
    echo "==> hevc"
    # shellcheck disable=SC2046,SC2086
    ffmpeg $Q -f lavfi -i "testsrc2=size=1280x720:rate=20" -t 12 -vf "$(barcode_filter 60000),format=yuv420p" \
        -c:v libx265 -preset veryfast -crf 28 -tag:v hvc1 -g 40 \
        -x265-params "bframes=0:keyint=40:min-keyint=40:scenecut=0:log-level=error" $(muxer_flags) "$WORK/hevc.mp4"
    finish hevc synthetic --barcode-base 60000
}

# big: 4256x1888 (8 MP, the ANNKE FCD800's size), High 5.1, about 8 Mbps, 20 fps, 2 s GOP, 10 s.
wanted big && {
    echo "==> big"
    # shellcheck disable=SC2046,SC2086
    ffmpeg $Q -f lavfi -i "testsrc2=size=4256x1888:rate=20" -t 10 -vf "format=yuv420p" \
        -c:v libx264 -preset veryfast -profile:v high -level 5.1 -b:v 8M -maxrate 8M -bufsize 16M -g 40 -keyint_min 40 \
        -x264-params scenecut=0:bframes=0:ref=1 $(muxer_flags) "$WORK/big.mp4"
    finish big synthetic
}

# uhd: 3840x2160 (the largest size a hardware H.264 decoder commonly takes), High 5.1, about 8 Mbps, 20 fps, 2 s GOP, 10 s.
wanted uhd && {
    echo "==> uhd"
    # shellcheck disable=SC2046,SC2086
    ffmpeg $Q -f lavfi -i "testsrc2=size=3840x2160:rate=20" -t 10 -vf "format=yuv420p" \
        -c:v libx264 -preset veryfast -profile:v high -level 5.1 -b:v 8M -maxrate 8M -bufsize 16M -g 40 -keyint_min 40 \
        -x264-params scenecut=0:bframes=0:ref=1 $(muxer_flags) "$WORK/uhd.mp4"
    finish uhd synthetic
}

# cap: the repo capture, copied without re-encoding (2688x1520, 20 fps, 2 s GOP, keyframes about 0.65 MB).
wanted cap && {
    echo "==> cap"
    capture=$(find_capture)
    if [ -n "$capture" ] && [ -f "$capture" ]; then
        # shellcheck disable=SC2046,SC2086
        ffmpeg $Q -f h264 -framerate 20 -i "$capture" -c:v copy $(muxer_flags) "$WORK/cap.mp4" 2>/dev/null
        finish cap capture
    else
        echo "    no capture found (set CAMERABRIDGE_TAPO_CAPTURE): building a synthetic stand-in of the same size and GOP" >&2
        # shellcheck disable=SC2046,SC2086
        ffmpeg $Q -f lavfi -i "testsrc2=size=2688x1520:rate=20" -t 10.4 -vf "format=yuv420p" \
            -c:v libx264 -preset veryfast -profile:v main -level 5.0 -b:v 3M -g 40 -keyint_min 40 -x264-params scenecut=0:bframes=0:ref=1 \
            $(muxer_flags) "$WORK/cap.mp4"
        finish cap synthetic-standin
    fi
}

echo "==> done: $OUT"
du -sh "$OUT"/* 2>/dev/null || true
