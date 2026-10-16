// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"encoding/binary"
	"io"
)

// tsMuxer wraps access units in MPEG-TS so ffmpeg gets each picture's own timestamp (the camera's RTP clock) instead of
// stamping raw Annex B by arrival time. One video stream and optionally one audio stream, PAT/PMT before every keyframe, PCR
// on keyframes, PTS = DTS (WebRTC senders do not use B-frames). ISO/IEC 13818-1.
//
// Audio is carried the way ffmpeg's own muxer and demuxer do it: Opus as private data (stream type 0x06, registration "Opus",
// DVB extension descriptor 0x80 with the channel count, ETSI TS 102 366 control header in front of every packet); G.711, once
// decoded and upsampled, as Blu-ray LPCM (stream type 0x80 in a program registered "HDMV", 48 kHz 16-bit, mono in two slots).
type tsMuxer struct {
	w        io.Writer
	codec    videoCodec
	audio    *audioFormat // nil: video only
	cc       [4]byte      // continuity counters: PAT, PMT, video, audio
	started  bool
	firstExt int64
	lastTS   uint32
	ext      int64
	buf      []byte
}

const (
	tsPMTPID    = 0x1000
	tsVideoPID  = 0x0100
	tsAudioPID  = 0x0101
	tsBaseDelay = 90000 // PTS starts at 1 s
)

func newTSMuxer(w io.Writer, codec videoCodec, audio *audioFormat) *tsMuxer {
	return &tsMuxer{w: w, codec: codec, audio: audio}
}

func (m *tsMuxer) streamType() byte {
	if m.codec == codecH264 {
		return 0x1b
	}
	return 0x24
}

// pts unwraps the 32-bit RTP timestamp into a 33-bit PTS.
func (m *tsMuxer) pts(ts uint32) int64 {
	if !m.started {
		m.started, m.lastTS, m.ext, m.firstExt = true, ts, int64(ts), int64(ts)
	} else {
		m.ext += int64(int32(ts - m.lastTS))
		m.lastTS = ts
	}
	return (m.ext - m.firstExt + tsBaseDelay) & (1<<33 - 1)
}

func (m *tsMuxer) writeAU(au *accessUnit) error {
	pts := m.pts(au.Timestamp)
	m.buf = m.buf[:0]
	if au.Key {
		m.buf = m.psi(m.buf, 0, 0, m.pat())
		m.buf = m.psi(m.buf, tsPMTPID, 1, m.pmt())
	}
	// PES: an access unit delimiter first (required for H.264 in TS, harmless for H.265), then the picture.
	var aud []byte
	if m.codec == codecH264 {
		aud = []byte{0, 0, 0, 1, 0x09, 0xf0}
	} else {
		aud = []byte{0, 0, 0, 1, 0x46, 0x01, 0x50}
	}
	pes := make([]byte, 0, 14+len(aud)+len(au.Data))
	pes = append(pes, 0, 0, 1, 0xe0, 0, 0, 0x80, 0x80, 5)
	pes = appendTimestamp(pes, 0x2, pts)
	pes = append(pes, aud...)
	pes = append(pes, au.Data...)
	m.buf = m.packetize(m.buf, tsVideoPID, 2, pes, au.Key, pts)
	_, err := m.w.Write(m.buf)
	return err
}

// videoExt places a 32-bit video RTP timestamp on the unwrapped video timeline (nearest to the last picture).
func (m *tsMuxer) videoExt(ts uint32) (int64, bool) {
	if !m.started {
		return 0, false
	}
	return m.ext + int64(int32(ts-m.lastTS)), true
}

// writeAudio writes one audio payload (already framed for its stream type) at the given point of the video RTP timeline.
// Audio from before the first picture is dropped.
func (m *tsMuxer) writeAudio(payload []byte, videoExt int64) error {
	if m.audio == nil || !m.started {
		return nil
	}
	pts := videoExt - m.firstExt + tsBaseDelay
	if pts < 0 {
		return nil
	}
	pts &= 1<<33 - 1
	n := len(payload) + 8
	pes := make([]byte, 0, 14+len(payload))
	pes = append(pes, 0, 0, 1, 0xbd, byte(n>>8), byte(n), 0x80, 0x80, 5)
	pes = appendTimestamp(pes, 0x2, pts)
	pes = append(pes, payload...)
	m.buf = m.packetize(m.buf[:0], tsAudioPID, 3, pes, false, 0)
	_, err := m.w.Write(m.buf)
	return err
}

// packetize cuts a PES into 188-byte packets; a keyframe's first packet carries random_access and the PCR.
func (m *tsMuxer) packetize(buf []byte, pid uint16, ccIdx int, pes []byte, key bool, pts int64) []byte {
	first := true
	for len(pes) > 0 {
		var af []byte // adaptation field after its length byte
		hasAF := false
		if first && key {
			// random_access_indicator + PCR (a little before the PTS)
			pcr := pts - 9000
			if pcr < 0 {
				pcr = 0
			}
			af = []byte{0x50, byte(pcr >> 25), byte(pcr >> 17), byte(pcr >> 9), byte(pcr >> 1), byte(pcr<<7) | 0x7e, 0}
			hasAF = true
		}
		room := 184
		if hasAF {
			room = 183 - len(af)
		}
		if len(pes) < room { // the last packet: stuff with the adaptation field
			if !hasAF {
				hasAF = true
				room = 183
				if len(pes) < room {
					af = []byte{0x00}
					room = 182
				}
			}
			for len(pes) < room {
				af = append(af, 0xff)
				room--
			}
		}
		pkt := make([]byte, 0, 188)
		b1 := byte(pid >> 8 & 0x1f)
		if first {
			b1 |= 0x40
		}
		ctrl := byte(0x10)
		if hasAF {
			ctrl = 0x30
		}
		pkt = append(pkt, 0x47, b1, byte(pid&0xff), ctrl|m.cc[ccIdx]&0x0f)
		if hasAF {
			pkt = append(pkt, byte(len(af)))
			pkt = append(pkt, af...)
		}
		pkt = append(pkt, pes[:room]...)
		pes = pes[room:]
		m.cc[ccIdx]++
		buf = append(buf, pkt...)
		first = false
	}
	return buf
}

func appendTimestamp(b []byte, prefix byte, ts int64) []byte {
	return append(b,
		prefix<<4|byte(ts>>29)&0x0e|1,
		byte(ts>>22), byte(ts>>14)|1,
		byte(ts>>7), byte(ts<<1)|1)
}

func (m *tsMuxer) pat() []byte {
	s := []byte{0x00, 0xb0, 0, 0x00, 0x01, 0xc1, 0x00, 0x00, 0x00, 0x01, 0xe0 | tsPMTPID>>8, tsPMTPID & 0xff}
	return finishSection(s)
}

func (m *tsMuxer) pmt() []byte {
	s := []byte{0x02, 0xb0, 0, 0x00, 0x01, 0xc1, 0x00, 0x00, 0xe0 | tsVideoPID>>8, tsVideoPID & 0xff}
	var progInfo []byte
	if m.audio != nil && m.audio.Kind == audioLPCM {
		progInfo = []byte{0x05, 4, 'H', 'D', 'M', 'V'}
	}
	s = append(s, 0xf0|byte(len(progInfo)>>8), byte(len(progInfo)))
	s = append(s, progInfo...)
	s = append(s, m.streamType(), 0xe0|tsVideoPID>>8, tsVideoPID&0xff, 0xf0, 0x00)
	if m.audio != nil {
		switch m.audio.Kind {
		case audioOpus:
			desc := []byte{0x05, 4, 'O', 'p', 'u', 's', 0x7f, 2, 0x80, byte(m.audio.Channels)}
			s = append(s, 0x06, 0xe0|tsAudioPID>>8, tsAudioPID&0xff, 0xf0, byte(len(desc)))
			s = append(s, desc...)
		case audioLPCM:
			s = append(s, 0x80, 0xe0|tsAudioPID>>8, tsAudioPID&0xff, 0xf0, 0x00)
		}
	}
	return finishSection(s)
}

// finishSection fills section_length and appends the CRC.
func finishSection(s []byte) []byte {
	l := len(s) - 3 + 4
	s[1] = 0xb0 | byte(l>>8)&0x0f
	s[2] = byte(l)
	return binary.BigEndian.AppendUint32(s, crc32MPEG(s))
}

// psi writes one section in one TS packet (pointer field 0, 0xff fill).
func (m *tsMuxer) psi(b []byte, pid uint16, ccIdx int, section []byte) []byte {
	pkt := make([]byte, 188)
	for i := range pkt {
		pkt[i] = 0xff
	}
	pkt[0], pkt[1], pkt[2], pkt[3], pkt[4] = 0x47, 0x40|byte(pid>>8)&0x1f, byte(pid), 0x10|m.cc[ccIdx]&0x0f, 0
	copy(pkt[5:], section)
	m.cc[ccIdx]++
	return append(b, pkt...)
}

func crc32MPEG(b []byte) uint32 {
	crc := uint32(0xffffffff)
	for _, x := range b {
		crc ^= uint32(x) << 24
		for i := 0; i < 8; i++ {
			if crc&0x80000000 != 0 {
				crc = crc<<1 ^ 0x04c11db7
			} else {
				crc <<= 1
			}
		}
	}
	return crc
}
