// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"context"

	"errors"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/pion/rtp"
)

// runSelfTest checks everything after the network without a camera or an account: an Annex B file is packetised as the
// gateway would send it (aggregation and fragmentation, 1200-byte payloads), every 50th packet is held back 150 positions (a
// NACK repair arriving late), neighbours are swapped, and the result runs through the reorder buffer, the depacketiser, the
// writer and the configured output (stdout, or ffmpeg pushing RTSP to go2rtc) in real time at 15 pictures a second. With an
// audio file (Opus in Ogg, or raw 8 kHz G.711 as .ulaw/.alaw) its packets run alongside through the audio path, 20 ms apart.
func runSelfTest(c *config, path, audioPath string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		status("event=config_error reason=%s", q("self test: "+err.Error()))
		return exitConfig
	}
	vc := c.codec
	aus := groupAccessUnits(vc, splitAnnexB(raw))
	if len(aus) == 0 {
		status("event=config_error reason=%s", q("self test: no access units in the file"))
		return exitConfig
	}
	var apkts [][]byte
	var af *audioFormat
	if audioPath != "" {
		if apkts, af, err = loadSelfTestAudio(audioPath); err != nil {
			status("event=config_error reason=%s", q("self test audio: "+err.Error()))
			return exitConfig
		}
	}
	status("event=start mode=self_test codec=%s pictures=%d audio_packets=%d output=%s", vc, len(aus), len(apkts), redactURL(c.output))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)

	pz := &packetizer{codec: vc, mtu: 1200, pt: payloadH265, ssrc: 0x1234, seq: 65000} // starts near the wrap on purpose
	var pkts []*rtp.Packet
	for i, au := range aus {
		pkts = append(pkts, pz.packets(au, uint32(i*6000))...)
	}
	pkts = scramble(pkts, 50, 150)

	frames := make(chan *accessUnit, 256)
	audioCh := make(chan audioPacket, 256)
	fail := make(chan sessionEnd, 2)
	first := make(chan struct{})
	cnt := &counters{}
	clk := newAVClock()
	as := &audioState{}
	if af != nil {
		as.announced.Store(true)
		as.format.Store(af)
		status("event=audio_track codec=%s clock=%d channels=%d", af.Codec, af.Clock, af.Channels)
	}
	out := newLazySink(c.output, c.ffmpeg, c.ffmpegLevel)
	defer out.Close()
	go writeFrames(ctx, frames, audioCh, out, cnt, first, fail, as, clk, "self-test")

	start := time.Now()
	if af != nil {
		go func() {
			step := uint32(af.Clock / 50)
			ts := uint32(0x7ffff000) // arbitrary, unrelated to the video clock
			for k, p := range apkts {
				if d := time.Until(start.Add(time.Duration(k) * 20 * time.Millisecond)); d > 0 {
					time.Sleep(d)
				}
				select {
				case audioCh <- audioPacket{SSRC: 0x5678, TS: ts, Payload: p, Arrived: time.Now()}:
				case <-ctx.Done():
					return
				}
				ts += step
			}
		}()
	}

	rb := newReorderBuffer(4096, reorderMaxDelay)
	dp := newDepacketizer(vc)
	var ro []reorderOut
	produced := 0
	perPicture := time.Second / 15
	perPacket := perPicture * time.Duration(len(aus)) / time.Duration(len(pkts))
	for i, p := range pkts {
		if d := time.Until(start.Add(time.Duration(i) * perPacket)); d > 0 {
			time.Sleep(d)
		}
		select {
		case s := <-sig:
			status("event=stopped reason=%s", q(s.String()))
			return exitOK
		case e := <-fail:
			status("event=%s code=%d reason=%s", e.event, e.code, q(e.reason))
			return e.code
		default:
		}
		now := time.Now()
		clk.videoPacket(p.SSRC, p.Timestamp, now)
		ro = rb.push(p, now, ro)
		for _, o := range ro {
			if o.Pkt == nil {
				dp.lost()
				continue
			}
			if au, _ := dp.push(o.Pkt.Payload, o.Pkt.Timestamp, o.Pkt.Marker); au != nil {
				produced++
				frames <- au
			}
		}
		ro = ro[:0]
	}
	time.Sleep(reorderMaxDelay + 100*time.Millisecond)
	for _, o := range rb.tick(time.Now().Add(time.Hour), nil) {
		if o.Pkt != nil {
			if au, _ := dp.push(o.Pkt.Payload, o.Pkt.Timestamp, o.Pkt.Marker); au != nil {
				produced++
				frames <- au
			}
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for cnt.frames.Load() < uint64(produced) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(time.Second) // let ffmpeg push the tail
	ok := rb.Lost == 0 && dp.Dropped == 0 && produced == len(aus)
	if af != nil && cnt.audioFrames.Load() == 0 {
		ok = false
	}
	status("event=self_test_done pictures_in=%d pictures_out=%d written=%d audio_in=%d audio_written=%d lost=%d dropped=%d reordered=%d ok=%t",
		len(aus), produced, cnt.frames.Load(), len(apkts), cnt.audioFrames.Load(), rb.Lost, dp.Dropped, rb.Reordered, ok)
	if !ok {
		return exitSession
	}
	return exitOK
}

// loadSelfTestAudio reads 20 ms audio packets: Opus packets from an Ogg file, or raw G.711 cut into 160-byte packets.
func loadSelfTestAudio(path string) ([][]byte, *audioFormat, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	switch {
	case strings.HasSuffix(path, ".ulaw") || strings.HasSuffix(path, ".alaw"):
		var out [][]byte
		for i := 0; i+160 <= len(raw); i += 160 {
			out = append(out, raw[i:i+160])
		}
		codec := "pcmu"
		if strings.HasSuffix(path, ".alaw") {
			codec = "pcma"
		}
		return out, &audioFormat{Kind: audioLPCM, Codec: codec, Clock: 8000, Channels: 1}, nil
	case strings.HasSuffix(path, ".ogg") || strings.HasSuffix(path, ".opus"):
		pk, err := oggPackets(raw)
		if err != nil {
			return nil, nil, err
		}
		if len(pk) < 3 || !strings.HasPrefix(string(pk[0]), "OpusHead") {
			return nil, nil, errors.New("not an Ogg Opus file")
		}
		ch := int(pk[0][9])
		return pk[2:], &audioFormat{Kind: audioOpus, Codec: "opus", Clock: 48000, Channels: ch}, nil
	}
	return nil, nil, errors.New("audio file must be .ogg/.opus, .ulaw or .alaw")
}

// oggPackets splits an Ogg stream (one logical stream) into its packets.
func oggPackets(b []byte) ([][]byte, error) {
	var out [][]byte
	var cur []byte
	for len(b) >= 27 {
		if string(b[:4]) != "OggS" {
			return nil, errors.New("ogg: lost sync")
		}
		n := int(b[26])
		if len(b) < 27+n {
			return nil, errors.New("ogg: short page")
		}
		segs := b[27 : 27+n]
		body := b[27+n:]
		for _, l := range segs {
			if int(l) > len(body) {
				return nil, errors.New("ogg: short segment")
			}
			cur = append(cur, body[:l]...)
			body = body[l:]
			if l < 255 {
				out = append(out, cur)
				cur = nil
			}
		}
		b = body
	}
	return out, nil
}

// scramble holds every nth packet back by `lag` positions and swaps the neighbours of every 7th, like a network with NACK repairs.
func scramble(in []*rtp.Packet, every, lag int) []*rtp.Packet {
	out := make([]*rtp.Packet, 0, len(in))
	held := map[int][]*rtp.Packet{}
	for i, p := range in {
		if i > 0 && i%every == 0 && i+lag < len(in) {
			held[i+lag] = append(held[i+lag], p)
		} else {
			out = append(out, p)
		}
		out = append(out, held[i]...)
		delete(held, i)
	}
	for i := 3; i+1 < len(out); i += 7 {
		out[i], out[i+1] = out[i+1], out[i]
	}
	return out
}
