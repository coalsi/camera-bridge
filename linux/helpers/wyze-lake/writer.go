// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"context"
	"sync"
	"sync/atomic"
	"time"
)

// audioState is what the signalling and the audio receiver tell the writer.
type audioState struct {
	announced atomic.Bool                 // the camera announced an audio stream (on_add_audio_stream)
	format    atomic.Pointer[audioFormat] // the audio track's format, once pion has it
	flowing   atomic.Bool                 // at least one audio packet reached the writer
	disabled  atomic.Bool                 // given up on audio for this session

	mu       sync.Mutex
	problems map[string]bool
}

// problem reports an audio problem once per distinct reason; the video is never affected.
func (a *audioState) problem(reason string) {
	a.mu.Lock()
	if a.problems == nil {
		a.problems = map[string]bool{}
	}
	seen := a.problems[reason]
	a.problems[reason] = true
	a.mu.Unlock()
	if !seen {
		status("event=audio_problem reason=%s", q(reason))
	}
}

// audioWait is how long the output waits at the first keyframe for announced audio to start flowing, so the TS declares it
// (ffmpeg reads the stream list once, when it starts).
const audioWait = 3 * time.Second

// audioMapper turns audio RTP times into points on the video RTP timeline, anchored once per output.
type audioMapper struct {
	anchored  bool
	aLast     uint32
	aExt      int64 // unwrapped audio RTP time
	aAnchor   int64
	vAnchor   int64 // video timeline point of aAnchor
	clock     int
	prevPCM   int16
	sync      string
	expectExt int64 // next expected aExt, to notice the camera restarting its audio clock
	refined   bool  // an arrival anchor was checked against the sender reports once they came
	since     time.Time
}

// srRefineWindow: for this long after an arrival anchor, the first pair of sender reports may correct it (once).
const srRefineWindow = 30 * time.Second

// srRefineMin: a correction smaller than this (in 90 kHz ticks, 45 ms) is not worth a jump in the audio timestamps.
const srRefineMin = 4050

func (m *audioMapper) videoPoint(p audioPacket, f *audioFormat, mux *tsMuxer, clk *avClock) (int64, bool) {
	if !m.anchored {
		v32, how, ok := clk.anchor(p.SSRC, p.TS, f.Clock, p.Arrived)
		if !ok {
			return 0, false
		}
		vExt, ok := mux.videoExt(v32)
		if !ok {
			return 0, false
		}
		*m = audioMapper{anchored: true, aLast: p.TS, aExt: int64(p.TS), aAnchor: int64(p.TS), vAnchor: vExt, clock: f.Clock,
			sync: how, prevPCM: m.prevPCM, refined: how == "sr", since: time.Now()}
		m.expectExt = m.aExt
		status("event=audio_sync method=%s", how)
	} else {
		m.aExt += int64(int32(p.TS - m.aLast))
		m.aLast = p.TS
		// a jump of more than 2 s either way: the sender restarted its clock; anchor again
		if d := m.aExt - m.expectExt; d > int64(2*m.clock) || d < -int64(2*m.clock) {
			m.anchored = false
			return m.videoPoint(p, f, mux, clk)
		}
		if !m.refined {
			if time.Since(m.since) > srRefineWindow {
				m.refined = true
			} else if v32, ok := clk.srAnchor(p.SSRC, p.TS, f.Clock); ok {
				m.refined = true
				if vExt, ok := mux.videoExt(v32); ok {
					cur := m.vAnchor + (m.aExt-m.aAnchor)*90000/int64(m.clock)
					if d := vExt - cur; d > srRefineMin || d < -srRefineMin {
						m.aAnchor, m.vAnchor, m.sync = m.aExt, vExt, "sr"
						status("event=audio_sync method=sr correction_ms=%d", d/90)
					}
				}
			}
		}
	}
	m.expectExt = m.aExt + int64(m.clock)/50 // about one 20 ms packet later
	return m.vAnchor + (m.aExt-m.aAnchor)*90000/int64(m.clock), true
}

// writeFrames writes pictures (and audio, when the output carries it) to the sink, opening it at the first keyframe.
func writeFrames(ctx context.Context, frames <-chan *accessUnit, audioIn <-chan audioPacket, out *lazySink, cnt *counters,
	first chan<- struct{}, fail chan<- sessionEnd, as *audioState, clk *avClock, requested string) {
	lastW, lastH := 0, 0
	pc := &pacer{delay: reorderMaxDelay / 4}
	var once sync.Once
	opened := false
	var pending []*accessUnit // pictures held at the first keyframe while waiting for audio
	var waitSince time.Time
	var am audioMapper
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()

	open := func(au *accessUnit) bool {
		var af *audioFormat
		if !as.disabled.Load() && as.flowing.Load() {
			af = as.format.Load()
		}
		if err := out.start(au.Codec, af); err != nil {
			fail <- sessionEnd{exitOutput, "output_error", err.Error()}
			return false
		}
		opened, am = true, audioMapper{}
		if out.hasAudio() {
			status("event=output audio=%s video=%s", af.Codec, au.Codec)
		} else {
			if as.announced.Load() && !as.disabled.Load() && out.carriesAudio() {
				as.problem("the camera's audio did not start in time; this output carries video only")
			}
			status("event=output audio=none video=%s", au.Codec)
		}
		return true
	}
	write := func(au *accessUnit) bool {
		if out.paced() {
			if wait := time.Until(pc.due(au.Timestamp, time.Now())); wait > 0 {
				select {
				case <-time.After(wait):
				case <-ctx.Done():
					return false
				}
			}
		}
		if err := out.writeAU(au); err != nil {
			if out.failedForAudio() && out.wantsReopen() {
				as.disabled.Store(true)
				opened = false
				return true // the next keyframe opens a video-only output
			}
			fail <- sessionEnd{exitOutput, "output_error", "write: " + err.Error()}
			return false
		}
		cnt.frames.Add(1)
		cnt.bytes.Add(uint64(len(au.Data)))
		if au.Key {
			cnt.keyframes.Add(1)
			if w, h, ok := spsSize(au.Codec, au.Data); ok && (w != lastW || h != lastH) {
				lastW, lastH = w, h
				status("event=resolution requested=%s got=%dx%d", requested, w, h)
			}
		}
		cnt.lastWrite.Store(time.Now().UnixNano())
		once.Do(func() { close(first) })
		return true
	}
	flushPending := func() bool {
		if !open(pending[0]) {
			return false
		}
		for _, p := range pending {
			if !write(p) {
				return false
			}
		}
		pending, waitSince = nil, time.Time{}
		return true
	}
	readyToOpen := func() bool {
		if as.disabled.Load() || !as.announced.Load() || !out.carriesAudio() {
			return true
		}
		return (as.flowing.Load() && as.format.Load() != nil) || time.Since(waitSince) >= audioWait
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if opened && out.wantsReopen() {
				as.disabled.Store(true)
				opened = false
			}
			if !opened && len(pending) > 0 && readyToOpen() && !flushPending() {
				return
			}
		case p := <-audioIn:
			as.flowing.Store(true)
			if !opened || as.disabled.Load() {
				continue
			}
			mux := out.muxer()
			f := as.format.Load()
			if mux == nil || !out.hasAudio() || f == nil {
				if !out.hasAudio() && out.carriesAudio() && !as.disabled.Load() {
					as.problem("the camera's audio started after the output opened; this session carries video only")
				}
				continue
			}
			v, ok := am.videoPoint(p, f, mux, clk)
			if !ok {
				continue
			}
			var payload []byte
			if f.Kind == audioOpus {
				payload = opusTSFrame(p.Payload)
			} else {
				payload, am.prevPCM = lpcmFromG711(p.Payload, f.Codec == "pcma", am.prevPCM)
			}
			if err := mux.writeAudio(payload, v); err != nil {
				// the same pipe as the video: the next picture write sees the failure and handles it
				continue
			}
			cnt.audioFrames.Add(1)
		case au := <-frames:
			if opened && out.wantsReopen() {
				as.disabled.Store(true)
				opened = false
			}
			if !opened {
				if len(pending) == 0 {
					if !au.Key {
						continue
					}
					waitSince = time.Now()
				}
				pending = append(pending, au)
				if readyToOpen() || len(pending) > 300 {
					if !flushPending() {
						return
					}
				}
				continue
			}
			if !write(au) {
				return
			}
		}
	}
}
