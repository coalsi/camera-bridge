#!/bin/sh
# Captures ~10 s of a camera's RTSP stream (untouched, no re-encoding) plus per-packet and per-NAL details,
# so stream quirks can be reproduced in tests. The password is read silently and never printed or saved.
# Usage: sh Tools/capture_stream.sh 192.0.2.44 stream1 [username]
set -u
IP="${1:?usage: capture_stream.sh <ip> <rtsp-path> [username]}"; PATH_PART="${2:?rtsp path, e.g. stream1}"
USER_NAME="${3:-}"; [ -z "$USER_NAME" ] && { printf "Camera username: "; read -r USER_NAME; }
printf "Camera password (hidden): "; stty -echo; read -r CAM_PASS; stty echo; echo
OUT="$(cd "$(dirname "$0")" && pwd)/captures/$(echo "$IP" | tr . _)-$(date +%H%M%S)"; mkdir -p "$OUT"
ENC_PASS=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$CAM_PASS")
ENC_USER=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$USER_NAME")
URL="rtsp://$ENC_USER:$ENC_PASS@$IP:554/$PATH_PART"
echo "Capturing 10 s…"
ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$URL" -t 10 -map 0:v:0 -c copy -bsf:v h264_mp4toannexb "$OUT/video.h264" </dev/null
ffprobe -hide_banner -loglevel error -rtsp_transport tcp -i "$URL" -show_streams -of json > "$OUT/streams.json" 2>/dev/null </dev/null
ffprobe -hide_banner -loglevel error -show_packets -show_entries packet=pts_time,size,flags -of csv "$OUT/video.h264" > "$OUT/packets.csv" 2>/dev/null
ffmpeg -hide_banner -loglevel warning -i "$OUT/video.h264" -f null - 2> "$OUT/decode_check.txt"
python3 - "$OUT/video.h264" > "$OUT/nal_summary.txt" <<'PY'
import sys, collections
d=open(sys.argv[1],'rb').read(); i=0; nals=[]
while True:
    j=d.find(b'\x00\x00\x01',i)
    if j<0: break
    k=d.find(b'\x00\x00\x01',j+3); end=len(d) if k<0 else k
    if j+3<len(d): nals.append((d[j+3]&0x1f, end-j-3, d[j+4] if j+4<len(d) else 0))
    i=j+3
names={1:'slice',5:'IDR',6:'SEI',7:'SPS',8:'PPS',9:'AUD',12:'filler'}
print("NAL count:",len(nals)); print("by type:",dict(collections.Counter(names.get(t,t) for t,_,_ in nals)))
# first_mb_in_slice==0 marks a new picture (ue(v): first bit 1 => 0)
starts=sum(1 for t,_,b in nals if t in (1,5) and b&0x80); slices=sum(1 for t,_,_ in nals if t in (1,5))
print("slices:",slices,"pictures (first_mb==0):",starts,"slices/picture:",round(slices/max(starts,1),2))
print("first 40 NAL types:",[names.get(t,t) for t,_,_ in nals[:40]])
PY
echo "Done: $OUT"; cat "$OUT/nal_summary.txt"; echo "--- decoder check (ffmpeg) ---"; head -20 "$OUT/decode_check.txt"
