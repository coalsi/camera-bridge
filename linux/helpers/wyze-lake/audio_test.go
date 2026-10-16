// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

func TestFFmpegArgs(t *testing.T) {
	a := strings.Join(ffmpegArgs("warning", codecH265, "rtsp://127.0.0.1:8554/cam", false), " ")
	for _, want := range []string{"-f mpegts -i pipe:0", "-map 0:v:0 -c:v copy", "-f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/cam"} {
		if !strings.Contains(a, want) {
			t.Errorf("args lack %q: %s", want, a)
		}
	}
	if strings.Contains(a, "aac") {
		t.Fatal("audio args without audio")
	}
	a = strings.Join(ffmpegArgs("warning", codecH265, "rtsp://127.0.0.1:8554/cam", true), " ")
	if !strings.Contains(a, "-map 0:v:0 -c:v copy -map 0:a:0? -c:a aac -b:a 64k -ar 16000 -ac 1 -af aresample=async=1 -f rtsp") {
		t.Fatal(a)
	}
}

type pes struct {
	pts     int64
	payload []byte
	sid     byte
	off     int // byte offset of its first TS packet
}

// demuxTS is a tiny reader for our own output: it checks packet framing, continuity and the PSI CRCs, and returns the PES
// of each PID and the PMT's stream types and descriptors.
func demuxTS(t *testing.T, b []byte) (streams map[int][]pes, types map[int]byte, pmt []byte) {
	t.Helper()
	if len(b)%188 != 0 {
		t.Fatalf("length %d is not a multiple of 188", len(b))
	}
	streams, types = map[int][]pes{}, map[int]byte{}
	cc := map[int]int{}
	cur := map[int]*pes{}
	for off := 0; off < len(b); off += 188 {
		p := b[off : off+188]
		if p[0] != 0x47 {
			t.Fatalf("sync byte at %d", off)
		}
		pid := int(p[1]&0x1f)<<8 | int(p[2])
		c := int(p[3] & 0x0f)
		if last, ok := cc[pid]; ok && c != (last+1)&0x0f {
			t.Fatalf("continuity on pid %d: %d after %d", pid, c, last)
		}
		cc[pid] = c
		pos := 4
		if p[3]&0x20 != 0 {
			pos += 1 + int(p[4])
		}
		data := p[pos:]
		pusi := p[1]&0x40 != 0
		switch pid {
		case 0:
			sec := data[1:]
			l := int(sec[1]&0x0f)<<8 | int(sec[2])
			if crc32MPEG(sec[:3+l]) != 0 {
				t.Fatal("PAT CRC")
			}
		case tsPMTPID:
			sec := data[1:]
			l := int(sec[1]&0x0f)<<8 | int(sec[2])
			if crc32MPEG(sec[:3+l]) != 0 {
				t.Fatal("PMT CRC")
			}
			pmt = append([]byte(nil), sec[:3+l]...)
			pil := int(sec[10]&0x0f)<<8 | int(sec[11])
			es := sec[12+pil : 3+l-4]
			for len(es) >= 5 {
				epid := int(es[1]&0x1f)<<8 | int(es[2])
				types[epid] = es[0]
				il := int(es[3]&0x0f)<<8 | int(es[4])
				es = es[5+il:]
			}
		default:
			if pusi {
				if cur[pid] != nil {
					streams[pid] = append(streams[pid], *cur[pid])
				}
				if data[0] != 0 || data[1] != 0 || data[2] != 1 || data[7]&0x80 == 0 {
					t.Fatalf("PES header %x", data[:9])
				}
				x := data[9:14]
				ts := int64(x[0]>>1&7)<<30 | int64(x[1])<<22 | int64(x[2]>>1)<<15 | int64(x[3])<<7 | int64(x[4]>>1)
				cur[pid] = &pes{pts: ts, sid: data[3], off: off, payload: append([]byte(nil), data[9+int(data[8]):]...)}
			} else if cur[pid] != nil {
				cur[pid].payload = append(cur[pid].payload, data...)
			}
		}
	}
	for pid, c := range cur {
		streams[pid] = append(streams[pid], *c)
	}
	return
}

func TestTSMuxerVideo(t *testing.T) {
	for _, vc := range []videoCodec{codecH265, codecH264} {
		var buf bytes.Buffer
		m := newTSMuxer(&buf, vc, nil)
		aus := []*accessUnit{
			{Data: annex(hevc(32, 1), hevc(19, rep(0x55, 5000)...)), Timestamp: 0xfffff000, Key: true},
			{Data: annex(hevc(1, rep(0x56, 182-14-7+3)...)), Timestamp: 0xfffff000 + 3000}, // near a packet boundary
			{Data: annex(hevc(1, rep(0x57, 10)...)), Timestamp: 0x00000400},                // across the 32-bit wrap
			{Data: annex(hevc(1, rep(0x58, 183*3)...)), Timestamp: 0x00000400 + 6000, Key: true},
		}
		for _, au := range aus {
			if err := m.writeAU(au); err != nil {
				t.Fatal(err)
			}
		}
		st, types, _ := demuxTS(t, buf.Bytes())
		if want := map[videoCodec]byte{codecH265: 0x24, codecH264: 0x1b}[vc]; types[tsVideoPID] != want || len(types) != 1 {
			t.Fatalf("stream types %v", types)
		}
		v := st[tsVideoPID]
		wantPTS := []int64{90000, 93000, 90000 + 0x1400, 90000 + 0x1400 + 6000}
		if len(v) != 4 {
			t.Fatalf("%d PES", len(v))
		}
		for i := range v {
			if v[i].pts != wantPTS[i] || !bytes.HasSuffix(v[i].payload, aus[i].Data) {
				t.Fatalf("PES %d: pts %d", i, v[i].pts)
			}
		}
	}
}

func TestTSMuxerAudio(t *testing.T) {
	for _, f := range []*audioFormat{{Kind: audioOpus, Codec: "opus", Clock: 48000, Channels: 2}, {Kind: audioLPCM, Codec: "pcmu", Clock: 8000, Channels: 1}} {
		var buf bytes.Buffer
		m := newTSMuxer(&buf, codecH265, f)
		if err := m.writeAudio([]byte{1, 2, 3}, 1000); err != nil || buf.Len() != 0 {
			t.Fatal("audio before the first picture must be dropped")
		}
		m.writeAU(&accessUnit{Data: annex(hevc(32, 1), hevc(19, 0x80, 1)), Timestamp: 1000, Key: true})
		pay := bytes.Repeat([]byte{9}, 400)
		if err := m.writeAudio(pay, 1000+4500); err != nil {
			t.Fatal(err)
		}
		m.writeAudio(pay, 1000-90000*2) // before the timeline start: dropped
		st, types, pmt := demuxTS(t, buf.Bytes())
		a := st[tsAudioPID]
		if len(a) != 1 || a[0].pts != 90000+4500 || a[0].sid != 0xbd || !bytes.Equal(a[0].payload, pay) {
			t.Fatalf("%s: audio PES %+v", f.Codec, a)
		}
		switch f.Kind {
		case audioOpus:
			if types[tsAudioPID] != 0x06 || !bytes.Contains(pmt, []byte{0x05, 4, 'O', 'p', 'u', 's', 0x7f, 2, 0x80, 2}) {
				t.Fatalf("opus PMT %x", pmt)
			}
		case audioLPCM:
			if types[tsAudioPID] != 0x80 || !bytes.Contains(pmt[:20], []byte{0x05, 4, 'H', 'D', 'M', 'V'}) {
				t.Fatalf("lpcm PMT %x", pmt)
			}
		}
	}
}

func TestG711(t *testing.T) {
	// Reference values: ffmpeg's G.711 decoders (-f mulaw / -f alaw to s16le) over all 256 codes.
	for in, want := range map[byte]int16{0xff: 0, 0x7f: 0, 0x80: 32124, 0x00: -32124, 0xf0: 120, 0x70: -120, 0xcf: 924, 0xd5: 716, 0x2a: -5372} {
		if got := ulawToLinear(in); got != want {
			t.Errorf("ulaw %#x = %d, want %d", in, got, want)
		}
	}
	for in, want := range map[byte]int16{0xd5: 8, 0x55: -8, 0xaa: 32256, 0x2a: -32256, 0xd4: 24, 0xff: 848, 0x80: 5504, 0x00: -5504, 0xcf: 424} {
		if got := alawToLinear(in); got != want {
			t.Errorf("alaw %#x = %d, want %d", in, got, want)
		}
	}
	// and all 256 codes against ffmpeg, when it is installed
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		return
	}
	all := make([]byte, 256)
	for i := range all {
		all[i] = byte(i)
	}
	for _, f := range []string{"mulaw", "alaw"} {
		cmd := exec.Command(ff, "-v", "error", "-f", f, "-ar", "8000", "-ac", "1", "-i", "pipe:0", "-f", "s16le", "pipe:1")
		cmd.Stdin = bytes.NewReader(all)
		out, err := cmd.Output()
		if err != nil || len(out) != 512 {
			t.Fatal(f, err, len(out))
		}
		for i := 0; i < 256; i++ {
			want := int16(binary.LittleEndian.Uint16(out[i*2:]))
			got := ulawToLinear(byte(i))
			if f == "alaw" {
				got = alawToLinear(byte(i))
			}
			if got != want {
				t.Fatalf("%s %#x = %d, ffmpeg %d", f, i, got, want)
			}
		}
	}
}

func TestLPCMFromG711(t *testing.T) {
	out, last := lpcmFromG711([]byte{0x80, 0x00}, false, 0) // +32124 then -32124
	if len(out) != 4+2*6*4 || out[0] != 0 || out[1] != 48 || out[2] != 0x11 || out[3] != 0x40 {
		t.Fatalf("header %x len %d", out[:4], len(out))
	}
	if last != -32124 {
		t.Fatal(last)
	}
	sample := func(i int) int16 { return int16(binary.BigEndian.Uint16(out[4+i*4:])) }
	if sample(5) != 32124 || sample(11) != -32124 || sample(0) != 32124/6 {
		t.Fatalf("%d %d %d", sample(0), sample(5), sample(11))
	}
	for i := 0; i < 12; i++ {
		if out[4+i*4+2] != 0 || out[4+i*4+3] != 0 {
			t.Fatal("right slot not empty")
		}
	}
}

func TestOpusTSFrame(t *testing.T) {
	for n, hdr := range map[int][]byte{10: {0x7f, 0xe0, 10}, 255: {0x7f, 0xe0, 255, 0}, 300: {0x7f, 0xe0, 255, 45}, 510: {0x7f, 0xe0, 255, 255, 0}} {
		f := opusTSFrame(bytes.Repeat([]byte{1}, n))
		if !bytes.Equal(f[:len(hdr)], hdr) || len(f) != len(hdr)+n {
			t.Errorf("%d: %x", n, f[:len(hdr)])
		}
	}
}

func TestAudioFormatFor(t *testing.T) {
	if f, ok := audioFormatFor(webrtc.MimeTypeOpus, 48000, 2); !ok || f.Kind != audioOpus || f.Channels != 2 {
		t.Fatal(f)
	}
	if f, ok := audioFormatFor("audio/PCMU", 8000, 0); !ok || f.Kind != audioLPCM || f.Codec != "pcmu" {
		t.Fatal(f)
	}
	if f, ok := audioFormatFor(webrtc.MimeTypePCMA, 8000, 0); !ok || f.Codec != "pcma" {
		t.Fatal(f)
	}
	if _, ok := audioFormatFor("audio/G722", 8000, 1); ok {
		t.Fatal("G.722 accepted")
	}
}

func ntpOf(tm time.Time) uint64 {
	secs := uint64(tm.Unix() + 2208988800)
	frac := uint64(tm.Nanosecond()) << 32 / 1e9
	return secs<<32 | frac
}

func TestAVClockSenderReports(t *testing.T) {
	c := newAVClock()
	base := time.Unix(1_800_000_000, 0)
	// video: RTP 1000 at base; audio (8 kHz): RTP 50000 at base + 0.5 s
	c.senderReports([]rtcp.Packet{
		&rtcp.SenderReport{SSRC: 1, NTPTime: ntpOf(base), RTPTime: 1000},
		&rtcp.SenderReport{SSRC: 2, NTPTime: ntpOf(base.Add(500 * time.Millisecond)), RTPTime: 50000},
	})
	c.videoPacket(1, 1000, time.Now())
	// audio 50000 + 8000 (1 s later) is base + 1.5 s, which is video RTP 1000 + 135000
	v, how, ok := c.anchor(2, 58000, 8000, time.Now())
	if !ok || how != "sr" || v < 1000+135000-2 || v > 1000+135000+2 {
		t.Fatal(v, how, ok)
	}
	// without the audio's report: arrival alignment
	c2 := newAVClock()
	at := time.Now()
	c2.videoPacket(1, 5000, at)
	v, how, ok = c2.anchor(2, 123, 8000, at.Add(100*time.Millisecond))
	if !ok || how != "arrival" || v != 5000+9000 {
		t.Fatal(v, how)
	}
	if _, _, ok := newAVClock().anchor(2, 1, 8000, at); ok {
		t.Fatal("anchored without any video")
	}
}

func TestAudioMapper(t *testing.T) {
	var buf bytes.Buffer
	mux := newTSMuxer(&buf, codecH265, &audioFormat{Kind: audioLPCM, Codec: "pcmu", Clock: 8000, Channels: 1})
	mux.writeAU(&accessUnit{Data: annex(hevc(19, 0x80)), Timestamp: 9000, Key: true}) // video timeline starts at 9000
	clk := newAVClock()
	at := time.Now()
	clk.videoPacket(1, 9000, at)
	f := &audioFormat{Kind: audioLPCM, Codec: "pcmu", Clock: 8000, Channels: 1}
	var m audioMapper
	base := uint32(0xffffff00)
	v, ok := m.videoPoint(audioPacket{SSRC: 2, TS: base, Arrived: at}, f, mux, clk)
	if !ok || v != 9000 {
		t.Fatal(v, ok)
	}
	// 20 ms later in audio time (160 samples, across the 32-bit wrap) is 1800 video ticks later
	if v, _ := m.videoPoint(audioPacket{SSRC: 2, TS: base + 160, Arrived: at}, f, mux, clk); v != 9000+1800 {
		t.Fatal(v)
	}
	// a 10 s jump re-anchors on arrival instead of drifting 10 s away
	if v, _ := m.videoPoint(audioPacket{SSRC: 2, TS: base + 160 + 80000, Arrived: at.Add(40 * time.Millisecond)}, f, mux, clk); v != 9000+3600 {
		t.Fatal(v)
	}
}

// TestTSWithFFmpeg runs our MPEG-TS (H.265 + LPCM from G.711, and H.264 + Opus when the encoder exists) through the real ffmpeg
// with the helper's own arguments, into a file instead of RTSP, and checks the result has video and AAC audio.
func TestTSWithFFmpeg(t *testing.T) {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	dir := t.TempDir()
	// video: 2 s of 1080p HEVC from ffmpeg itself; audio: 2 s of a 440 Hz tone in u-law
	vfile, afile := filepath.Join(dir, "v.h265"), filepath.Join(dir, "a.ulaw")
	if out, err := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=15", "-t", "2",
		"-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "keyint=15:bframes=0:repeat-headers=1:log-level=error", "-f", "hevc", vfile).CombinedOutput(); err != nil {
		t.Skip("no libx265: ", string(out))
	}
	if out, err := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=f=440:r=8000", "-t", "2",
		"-f", "mulaw", "-ar", "8000", "-ac", "1", afile).CombinedOutput(); err != nil {
		t.Fatal(string(out))
	}
	raw, _ := os.ReadFile(vfile)
	aus := groupAccessUnits(codecH265, splitAnnexB(raw))
	ulaw, _ := os.ReadFile(afile)
	var ts bytes.Buffer
	f := &audioFormat{Kind: audioLPCM, Codec: "pcmu", Clock: 8000, Channels: 1}
	mux := newTSMuxer(&ts, codecH265, f)
	ai := 0
	var prev int16
	for i, au := range aus {
		d := []byte{}
		for _, n := range au {
			d = append(d, annex(n)...)
		}
		key := false
		for _, n := range au {
			if t := (n[0] >> 1) & 0x3f; t >= 16 && t <= 21 {
				key = true
			}
		}
		mux.writeAU(&accessUnit{Data: d, Timestamp: uint32(i * 6000), Key: key, Codec: codecH265})
		// audio up to this picture's time: 160 samples (20 ms = 1800 ticks) per packet
		for ; ai*1800 <= i*6000 && (ai+1)*160 <= len(ulaw); ai++ {
			var pl []byte
			pl, prev = lpcmFromG711(ulaw[ai*160:(ai+1)*160], false, prev)
			mux.writeAudio(pl, int64(ai*1800))
		}
	}
	args := ffmpegArgs("error", codecH265, "unused", true)
	args = append(args[:len(args)-5], "-f", "matroska", filepath.Join(dir, "out.mkv"))
	cmd := exec.Command(ff, args...)
	cmd.Stdin = &ts
	if out, err := cmd.CombinedOutput(); err != nil || len(out) > 0 {
		t.Fatalf("ffmpeg: %v %s", err, out)
	}
	probe, _ := exec.Command("ffprobe", "-v", "error", "-count_packets", "-show_entries", "stream=codec_name,sample_rate,channels,nb_read_packets",
		"-of", "compact", filepath.Join(dir, "out.mkv")).Output()
	if !strings.Contains(string(probe), "codec_name=hevc") || !strings.Contains(string(probe), "codec_name=aac|sample_rate=16000|channels=1|nb_read_packets=") {
		t.Fatalf("probe: %s", probe)
	}
	// 2 s of 16 kHz AAC is about 31 frames of 1024 samples
	if i := strings.Index(string(probe), "codec_name=aac"); i >= 0 {
		var n int
		fmt.Sscanf(string(probe)[strings.Index(string(probe)[i:], "nb_read_packets=")+i+len("nb_read_packets="):], "%d", &n)
		if n < 25 {
			t.Fatalf("only %d AAC frames: %s", n, probe)
		}
	}
}

func TestAudioMapperSRRefinement(t *testing.T) {
	var buf bytes.Buffer
	f := &audioFormat{Kind: audioOpus, Codec: "opus", Clock: 48000, Channels: 2}
	mux := newTSMuxer(&buf, codecH265, f)
	mux.writeAU(&accessUnit{Data: annex(hevc(19, 0x80)), Timestamp: 0, Key: true})
	clk := newAVClock()
	at := time.Now()
	clk.videoPacket(1, 0, at)
	var m audioMapper
	if v, _ := m.videoPoint(audioPacket{SSRC: 2, TS: 1000, Arrived: at}, f, mux, clk); v != 0 || m.sync != "arrival" {
		t.Fatal(v, m.sync)
	}
	// Sender reports arrive: audio 1000 was really captured 200 ms after video 0.
	base := time.Unix(1_800_000_000, 0)
	clk.senderReports([]rtcp.Packet{
		&rtcp.SenderReport{SSRC: 1, NTPTime: ntpOf(base), RTPTime: 0},
		&rtcp.SenderReport{SSRC: 2, NTPTime: ntpOf(base.Add(200 * time.Millisecond)), RTPTime: 1000},
	})
	v, _ := m.videoPoint(audioPacket{SSRC: 2, TS: 1000 + 960, Arrived: at}, f, mux, clk)
	if m.sync != "sr" || v < 18000+1800-2 || v > 18000+1800+2 {
		t.Fatalf("refined to %d (%s)", v, m.sync)
	}
	// only once
	if v, _ := m.videoPoint(audioPacket{SSRC: 2, TS: 1000 + 1920, Arrived: at}, f, mux, clk); v < 18000+3600-2 || v > 18000+3600+2 {
		t.Fatal(v)
	}
}

// The answer pion gets: audio sendonly with the gateway's codec, its SSRC declared when it was announced in time, and no
// MID/RID header extensions; pion must accept it.
func TestAnswerWithAudio(t *testing.T) {
	testLoopback = true
	defer func() { testLoopback = false }()
	var got atomic.Int64
	pc, err := newPeerConnection(codecH265, 1<<20, &got)
	if err != nil {
		t.Fatal(err)
	}
	defer pc.Close()
	offer, _ := pc.CreateOffer(nil)
	pc.SetLocalDescription(offer)
	o, err := parseOffer(pc.LocalDescription().SDP)
	if err != nil {
		t.Fatal(err)
	}
	var vcodec, acodec object
	var exts []any
	for _, m := range o.Medias {
		for _, e := range m.Exts {
			exts = append(exts, object{"entry": e.ID, "extensionName": e.URI})
		}
		if m.Kind == "video" {
			vcodec = m.Codecs[0].ortc()
		} else {
			for _, c := range m.Codecs {
				if c.Name == "PCMU" {
					acodec = c.ortc()
				}
			}
		}
	}
	exts = append(exts, object{"entry": 9, "extensionName": "urn:ietf:params:rtp-hdrext:sdes:mid"})
	gw := object{
		"iceParameters":   object{"iceUfrag": "gwufrag1", "icePwd": "gwpassword0123456789ab", "candidates": []any{object{"ip": "203.0.113.5", "port": 4701, "type": "host"}}},
		"dtlsParameters":  object{"fingerprints": []any{object{"hashFunction": "sha-256", "fingerprint": strings.TrimSuffix(strings.Repeat("AB:", 32), ":")}}},
		"rtpCapabilities": object{"send": object{"videoCodecs": []any{vcodec}, "audioCodecs": []any{acodec}, "videoExtensions": exts, "audioExtensions": exts}},
	}
	ans, err := buildAnswer(o, gw, remoteVideo{SSRC: 1111}, 2222, "")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(ans, "sdes:mid") || !strings.Contains(ans, "a=ssrc:2222 cname:lake") || !strings.Contains(ans, "a=rtpmap:0 PCMU/8000") {
		t.Fatal(ans)
	}
	if strings.Count(ans, "a=sendonly") != 2 {
		t.Fatal("audio is not sendonly:\n" + ans)
	}
	if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: ans}); err != nil {
		t.Fatal(err)
	}
	// and the undeclared form
	ans2, _ := buildAnswer(o, gw, remoteVideo{SSRC: 1111}, 0, "")
	if strings.Contains(ans2, "a=ssrc:2222") || strings.Count(ans2, "a=sendonly") != 2 {
		t.Fatal(ans2)
	}
}

// dyingSink fails as soon as it is opened with audio, like an ffmpeg that cannot make sense of the audio.
type dyingSink struct {
	captureSink
	dead bool
}

func (d *dyingSink) Write(p []byte) (int, error) {
	if d.dead {
		return 0, os.ErrClosed
	}
	return d.captureSink.Write(p)
}

// An output that dies right after it was opened with audio is reopened video-only; the session goes on.
func TestAudioFailureKeepsVideo(t *testing.T) {
	logs := &syncBuffer{}
	log.SetOutput(logs)
	defer log.SetOutput(os.Stderr)
	var mu sync.Mutex
	var opens []string
	var last *dyingSink
	old := openSinkHook
	defer func() { openSinkHook = old }()
	openSinkHook = func(vc videoCodec, af *audioFormat) (sink, error) {
		mu.Lock()
		defer mu.Unlock()
		d := &dyingSink{captureSink: captureSink{done: make(chan struct{})}}
		if af != nil {
			opens = append(opens, af.Codec)
			d.dead = true
			close(d.done)
		} else {
			opens = append(opens, "none")
		}
		last = d
		return d, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	frames := make(chan *accessUnit, 64)
	audioCh := make(chan audioPacket, 64)
	fail := make(chan sessionEnd, 1)
	first := make(chan struct{})
	cnt := &counters{}
	as := &audioState{}
	as.announced.Store(true)
	as.format.Store(&audioFormat{Kind: audioLPCM, Codec: "pcmu", Clock: 8000, Channels: 1})
	clk := newAVClock()
	out := newLazySink("rtsp://127.0.0.1:1/x", "ffmpeg", "warning")
	go writeFrames(ctx, frames, audioCh, out, cnt, first, fail, as, clk, "test")
	audioCh <- audioPacket{SSRC: 2, TS: 1, Payload: make([]byte, 160), Arrived: time.Now()}
	time.Sleep(50 * time.Millisecond)
	for i := 0; i < 40; i++ {
		frames <- &accessUnit{Data: annex(hevc(19, 0x80)), Timestamp: uint32(i * 6000), Key: i%10 == 0, Codec: codecH265}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(200 * time.Millisecond)
	select {
	case e := <-fail:
		t.Fatalf("session failed: %+v", e)
	default:
	}
	mu.Lock()
	defer mu.Unlock()
	if len(opens) != 2 || opens[0] != "pcmu" || opens[1] != "none" || last.count() == 0 {
		t.Fatalf("opens %v, writes %d", opens, last.count())
	}
	if !strings.Contains(logs.String(), "event=audio_problem") {
		t.Fatal("no audio_problem line")
	}
}
