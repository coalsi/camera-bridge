#!/bin/bash
# The load cameras of the soak: N looping H.264 clips at about 8 Mbit/s, served as RTSP on loopback by the go2rtc helper (the one the app already
# bundles) with ffmpeg copying each clip in real time. The daemon adds them as "RTSP URL" cameras, like any camera on a network.
#
#   load-sources.sh clips DIR N [--like PROFILE.json]    make N clips of 60 s in DIR/clips (about 60 MB each, deleted with the run)
#   load-sources.sh start DIR N                           start go2rtc on 127.0.0.1:$CB_SOAK_RTSP_PORT (default 18554); streams load1 ... loadN
#   load-sources.sh status DIR                            exit 0 while go2rtc runs
#   load-sources.sh stop DIR                              stop go2rtc (and with it the ffmpeg copies)
#
# The clips (profile for camera n, unless --like): 1-5 steady 8 Mbit/s 2560x1440 25 fps, key frame every 2 s; 6 the same with a key frame every
# 12 s (a "smart codec" camera); 7 bursty (3.5 Mbit/s, 6 to 7 Mbit/s for 6 s of every 20 s); 8 steady 8 Mbit/s 1920x1080 30 fps. With
# --like all clips take their size, frame rate, key frame interval and bit rate from the JSON that `budget-from-captures.mjs --like` prints.
# Environment: CB_GO2RTC (default: build/helpers/go2rtc in the main checkout), CB_SOAK_RTSP_PORT, CB_SOAK_API_PORT (default 18984), CB_SOAK_SRC_BIND (default 127.0.0.1),
#   CB_SOAK_CLIPS (a folder with load1.mp4 ... loadN.mp4 from an earlier `clips` run: they are linked, not encoded again; ignored with --like).
set -u
action="${1:?clips|start|status|stop}"; DIR="${2:?folder}"; N="${3:-8}"
CLIP_SECONDS=60
RTSP_PORT="${CB_SOAK_RTSP_PORT:-18554}"; API_PORT="${CB_SOAK_API_PORT:-18984}"; BIND="${CB_SOAK_SRC_BIND:-127.0.0.1}"
here="$(cd "$(dirname "$0")" && pwd)"
GO2RTC="${CB_GO2RTC:-$(cd "$here/../.." && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')/build/helpers/go2rtc}"

die() { echo "load-sources: $*" >&2; exit 1; }

make_clip() {   # n width height fps gop_seconds kbps mode
    local n=$1 w=$2 h=$3 fps=$4 gop=$5 kbps=$6 mode=$7
    local keyint=$((gop * fps)) out="$DIR/clips/load$n.mp4"
    local src="testsrc2=size=${w}x${h}:rate=${fps}"
    if [ "$mode" = bursty ]; then
        src="$src,noise=alls=1:allf=t:all_seed=$n,noise=alls=70:allf=t+u:all_seed=$((n + 50)):enable='between(mod(t,20),14,20)'"
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$src" -t $CLIP_SECONDS -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
            -crf 30 -maxrate "${kbps}k" -bufsize "${kbps}k" -x264-params "keyint=$keyint:min-keyint=$keyint:scenecut=0:bframes=0" -an "$out" || return 1
    else
        src="$src,noise=alls=18:allf=t+u:all_seed=$n"
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$src" -t $CLIP_SECONDS -c:v libx264 -preset veryfast -profile:v main -pix_fmt yuv420p \
            -b:v "${kbps}k" -minrate "${kbps}k" -maxrate "${kbps}k" -bufsize "$((kbps / 2))k" \
            -x264-params "nal-hrd=cbr:force-cfr=1:keyint=$keyint:min-keyint=$keyint:scenecut=0:bframes=0" -an "$out" || return 1
    fi
}

case "$action" in
    clips)
        mkdir -p "$DIR/clips"
        # Clips are made once and reused: with CB_SOAK_CLIPS set to a folder that holds load1.mp4 ... loadN.mp4, the run links them instead of encoding again.
        if [ -n "${CB_SOAK_CLIPS:-}" ] && [ "${4:-}" != "--like" ]; then
            n=1; while [ "$n" -le "$N" ]; do [ -f "$CB_SOAK_CLIPS/load$n.mp4" ] || break; n=$((n + 1)); done
            if [ "$n" -gt "$N" ]; then
                n=1; while [ "$n" -le "$N" ]; do ln -sf "$CB_SOAK_CLIPS/load$n.mp4" "$DIR/clips/load$n.mp4"; n=$((n + 1)); done
                echo "load-sources: $N clips linked from $CB_SOAK_CLIPS"; exit 0
            fi
        fi
        command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg is required"
        like=""; [ "${4:-}" = "--like" ] && like="${5:?--like needs a profile json}"
        n=1
        while [ "$n" -le "$N" ]; do
            if [ -n "$like" ]; then
                read -r w h fps gop kbps <<EOP
$(node -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log(p.width,p.height,p.fps,Math.max(1,Math.round(p.gopSeconds)),p.bitrateKbps)' "$like")
EOP
                make_clip "$n" "$w" "$h" "$fps" "$gop" "$kbps" steady || die "ffmpeg failed for clip $n"
            else
                case "$n" in
                    6) make_clip "$n" 2560 1440 25 12 8000 steady ;;
                    7) make_clip "$n" 2560 1440 25 2 8000 bursty ;;
                    8) make_clip "$n" 1920 1080 30 2 8000 steady ;;
                    *) make_clip "$n" 2560 1440 25 2 8000 steady ;;
                esac || die "ffmpeg failed for clip $n"
            fi
            n=$((n + 1))
        done
        echo "load-sources: $N clips in $DIR/clips" ;;
    start)
        [ -x "$GO2RTC" ] || die "go2rtc not found at $GO2RTC (set CB_GO2RTC; 'sh Tools/fetch-go2rtc.sh' downloads the pinned release, which needs the owner's OK)"
        [ -f "$DIR/clips/load1.mp4" ] || die "no clips in $DIR/clips (run: load-sources.sh clips $DIR $N)"
        if [ -s "$DIR/go2rtc.pid" ] && kill -0 "$(cat "$DIR/go2rtc.pid")" 2>/dev/null; then die "go2rtc already runs for this run"; fi
        { echo "api:"; echo "  listen: \"$BIND:$API_PORT\""
          echo "rtsp:"; echo "  listen: \"$BIND:$RTSP_PORT\""
          echo "webrtc:"; echo "  listen: \"127.0.0.1:$((RTSP_PORT + 1))\""
          echo "srtp:"; echo "  listen: \"\""
          echo "log:"; echo "  level: warn"
          echo "streams:"
          n=1; while [ "$n" -le "$N" ]; do
              echo "  load$n: exec:ffmpeg -hide_banner -loglevel error -re -stream_loop -1 -i $DIR/clips/load$n.mp4 -c copy -f rtsp {output}"
              n=$((n + 1))
          done; } > "$DIR/go2rtc.yaml"
        nohup "$GO2RTC" -c "$DIR/go2rtc.yaml" > "$DIR/go2rtc.log" 2>&1 &
        echo $! > "$DIR/go2rtc.pid"
        i=0; until nc -z "$BIND" "$RTSP_PORT" 2>/dev/null; do i=$((i + 1)); [ "$i" -gt 50 ] && die "go2rtc did not listen on $BIND:$RTSP_PORT within 5 s (see $DIR/go2rtc.log)"; sleep 0.1; done
        echo "load-sources: go2rtc on $BIND:$RTSP_PORT, streams load1..load$N" ;;
    status)
        [ -s "$DIR/go2rtc.pid" ] && kill -0 "$(cat "$DIR/go2rtc.pid")" 2>/dev/null ;;
    stop)
        if [ -s "$DIR/go2rtc.pid" ]; then
            pid="$(cat "$DIR/go2rtc.pid")"; kill -TERM "$pid" 2>/dev/null
            i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
            rm -f "$DIR/go2rtc.pid"
        fi ;;
    *) die "unknown action $action" ;;
esac
