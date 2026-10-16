// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"context"
	"errors"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

// The camera's microphone. Agora announces it like the video (on_add_audio_stream with its SSRC); we subscribe, receive it
// as Opus or G.711 (what the camera publishes; the Web SDK's createClient uses audioCodec "pcmu" in Wyze's viewer), carry it
// in the MPEG-TS next to the video on the same clock, and ffmpeg makes AAC-LC of it. Audio is best effort: a problem with it
// is reported as event=audio_problem and the video goes on alone.

type audioKind int

const (
	audioOpus audioKind = iota + 1
	audioLPCM           // G.711 decoded and upsampled to 48 kHz 16-bit
)

// audioFormat is what the output carries.
type audioFormat struct {
	Kind     audioKind
	Codec    string // as received: opus | pcmu | pcma
	Clock    int    // RTP clock rate
	Channels int
}

func audioFormatFor(mime string, clock uint32, channels uint16) (*audioFormat, bool) {
	switch strings.ToLower(mime) {
	case strings.ToLower(webrtc.MimeTypeOpus):
		ch := int(channels)
		if ch < 1 || ch > 2 {
			ch = 2
		}
		return &audioFormat{Kind: audioOpus, Codec: "opus", Clock: 48000, Channels: ch}, true
	case strings.ToLower(webrtc.MimeTypePCMU):
		return &audioFormat{Kind: audioLPCM, Codec: "pcmu", Clock: int(clock), Channels: 1}, clock == 8000
	case strings.ToLower(webrtc.MimeTypePCMA):
		return &audioFormat{Kind: audioLPCM, Codec: "pcma", Clock: int(clock), Channels: 1}, clock == 8000
	}
	return nil, false
}

// ---- G.711 (ITU-T G.711, the classic sign/exponent/mantissa expansion) ------------------------------------------------------

func ulawToLinear(u byte) int16 {
	u = ^u
	t := (int(u&0x0f) << 3) + 0x84
	t <<= (u & 0x70) >> 4
	if u&0x80 != 0 {
		return int16(0x84 - t)
	}
	return int16(t - 0x84)
}

func alawToLinear(a byte) int16 {
	a ^= 0x55
	t := int(a&0x0f) << 4
	seg := (a & 0x70) >> 4
	switch seg {
	case 0:
		t += 8
	case 1:
		t += 0x108
	default:
		t += 0x108
		t <<= seg - 1
	}
	if a&0x80 != 0 {
		return int16(t)
	}
	return int16(-t)
}

// lpcmFromG711 decodes one G.711 payload (8 kHz) and frames it as one Blu-ray LPCM access unit: a 4-byte header (payload
// size, mono, 48 kHz, 16-bit), then each sample upsampled six times by linear interpolation from the previous one, big
// endian, in the left slot of a two-slot frame (Blu-ray LPCM always has an even channel count). prev is the last sample of
// the previous payload, so the interpolation is continuous; the new last sample is returned.
func lpcmFromG711(payload []byte, alaw bool, prev int16) ([]byte, int16) {
	n := len(payload) * 6 * 4
	out := make([]byte, 4, 4+n)
	out[0], out[1], out[2], out[3] = byte(n>>8), byte(n), 0x11, 0x40
	for _, b := range payload {
		var s int16
		if alaw {
			s = alawToLinear(b)
		} else {
			s = ulawToLinear(b)
		}
		for k := 1; k <= 6; k++ {
			v := int16(int(prev) + (int(s)-int(prev))*k/6)
			out = append(out, byte(uint16(v)>>8), byte(v), 0, 0)
		}
		prev = s
	}
	return out, prev
}

// opusTSFrame puts the ETSI TS 102 366 control header in front of one Opus packet: 0x7f 0xe0, then the size as a run of
// 0xff bytes and a remainder (a size that is a multiple of 255 ends with a 0).
func opusTSFrame(pkt []byte) []byte {
	out := make([]byte, 0, len(pkt)+3+len(pkt)/255)
	out = append(out, 0x7f, 0xe0)
	n := len(pkt)
	for {
		if n >= 255 {
			out = append(out, 255)
			n -= 255
			continue
		}
		out = append(out, byte(n))
		break
	}
	return append(out, pkt...)
}

// ---- keeping audio and video on one clock ---------------------------------------------------------------------------------

// avClock maps the audio RTP clock onto the video RTP clock. With an RTCP sender report for each stream (the gateway's NTP
// time for an RTP timestamp) both are placed on the sender's wall clock; without them, the first audio packet is aligned with
// the video by arrival time (the video RTP time "now" extrapolated from the last video packet's arrival).
type avClock struct {
	mu        sync.Mutex
	sr        map[uint32]senderReport
	lastV     uint32 // RTP time of the last video packet read (before reordering)
	lastVAt   time.Time
	haveV     bool
	videoSSRC uint32
}

type senderReport struct {
	ntp time.Time
	rtp uint32
}

func newAVClock() *avClock { return &avClock{sr: map[uint32]senderReport{}} }

func ntpToTime(ntp uint64) time.Time {
	secs := int64(ntp>>32) - 2208988800
	frac := int64(ntp & 0xffffffff)
	return time.Unix(secs, frac*1e9>>32)
}

func (c *avClock) senderReports(pkts []rtcp.Packet) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, p := range pkts {
		if sr, ok := p.(*rtcp.SenderReport); ok {
			c.sr[sr.SSRC] = senderReport{ntp: ntpToTime(sr.NTPTime), rtp: sr.RTPTime}
		}
	}
}

func (c *avClock) videoPacket(ssrc, ts uint32, at time.Time) {
	c.mu.Lock()
	c.videoSSRC, c.lastV, c.lastVAt, c.haveV = ssrc, ts, at, true
	c.mu.Unlock()
}

// anchor returns the video RTP time (32-bit) that corresponds to audio RTP time aTS, and how it was found ("sr" or "arrival").
func (c *avClock) anchor(audioSSRC, aTS uint32, aClock int, arrived time.Time) (uint32, string, bool) {
	if v, ok := c.srAnchor(audioSSRC, aTS, aClock); ok {
		return v, "sr", true
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.haveV {
		return 0, "", false
	}
	v := c.lastV + uint32(int64(arrived.Sub(c.lastVAt))*90000/int64(time.Second))
	return v, "arrival", true
}

// srAnchor maps through both streams' sender reports, when there are both.
func (c *avClock) srAnchor(audioSSRC, aTS uint32, aClock int) (uint32, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	srA, okA := c.sr[audioSSRC]
	srV, okV := c.sr[c.videoSSRC]
	if !okA || !okV || !c.haveV || aClock <= 0 {
		return 0, false
	}
	at := srA.ntp.Add(time.Duration(int64(int32(aTS-srA.rtp))) * time.Second / time.Duration(aClock))
	return srV.rtp + uint32(int64(at.Sub(srV.ntp))*90000/int64(time.Second)), true
}

// audioPacket is one received audio payload, in order.
type audioPacket struct {
	SSRC    uint32
	TS      uint32
	Payload []byte
	Arrived time.Time
}

// receiveAudio reads the audio track, restores order, and hands packets to the writer. It never blocks the video: when the
// writer is behind, audio is dropped.
func receiveAudio(ctx context.Context, t *webrtc.TrackRemote, out chan<- audioPacket, problem func(string)) {
	rb := newReorderBuffer(512, 150*time.Millisecond)
	var ro []reorderOut
	dropped := 0
	emit := func() {
		for _, o := range ro {
			if o.Pkt == nil {
				continue // a gap: the AAC encoder's resampler fills it
			}
			select {
			case out <- audioPacket{SSRC: o.Pkt.SSRC, TS: o.Pkt.Timestamp, Payload: o.Pkt.Payload, Arrived: o.Arrived}:
			default:
				dropped++
				if dropped == 1 || dropped%500 == 0 {
					problem("audio dropped: the writer is behind")
				}
			}
		}
		ro = ro[:0]
	}
	for ctx.Err() == nil {
		_ = t.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
		p, _, err := t.ReadRTP()
		now := time.Now()
		if err != nil {
			if isTimeout(err) {
				ro = rb.tick(now, ro)
				emit()
				continue
			}
			if ctx.Err() == nil && !errors.Is(err, io.EOF) { // EOF: the track or the connection was closed
				problem("audio track failed: " + err.Error())
			}
			return
		}
		if len(p.Payload) == 0 {
			continue
		}
		ro = rb.push(p, now, ro)
		emit()
	}
}
