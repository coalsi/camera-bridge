// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"errors"
)

// Access-unit assembly from RTP: H.264 (RFC 6184: single NAL, STAP-A, FU-A) and H.265 (RFC 7798: single NAL, AP, FU; no DONL,
// which is only present when sprop-max-don-diff > 0, which the gateway does not offer). The output is Annex B: every NAL unit
// prefixed with 00 00 00 01. A keyframe that arrives without its parameter sets gets the last ones seen put in front.

type videoCodec int

const (
	codecH264 videoCodec = iota + 1
	codecH265
)

func (c videoCodec) String() string {
	switch c {
	case codecH264:
		return "h264"
	case codecH265:
		return "hevc"
	}
	return "unknown"
}

// accessUnit is one picture.
type accessUnit struct {
	Data      []byte // Annex B
	Timestamp uint32 // RTP, 90 kHz
	Key       bool   // IDR (H.264) or IRAP (H.265)
	Codec     videoCodec
}

type depacketizer struct {
	codec videoCodec

	nals    [][]byte // NAL units of the current access unit
	ts      uint32
	haveTS  bool
	broken  bool   // a packet of the current AU was lost
	fu      []byte // FU being reassembled (with its rebuilt NAL header)
	inFU    bool
	waitKey bool // after a loss: drop pictures until the next keyframe

	vps, sps, pps []byte

	// statistics
	Dropped uint64 // access units dropped because they were damaged or depended on a damaged one
}

var annexB = []byte{0, 0, 0, 1}

func newDepacketizer(c videoCodec) *depacketizer {
	return &depacketizer{codec: c, waitKey: true}
}

// lost tells the depacketizer packets are missing before the next one it is given. The picture in progress is damaged, and
// every picture until the next keyframe may refer to the lost data, so they are dropped too (a frozen picture rather than a
// smeared one; a keyframe is asked for at once).
func (d *depacketizer) lost() {
	d.broken = true
	d.waitKey = true
	d.inFU = false
	d.fu = nil
}

// push adds one in-order RTP payload and returns a finished access unit, if this packet completed one (or started a new one).
// A finished access unit is returned at most once per call; the marker bit ends an access unit, and so does a new timestamp.
func (d *depacketizer) push(payload []byte, ts uint32, marker bool) (*accessUnit, error) {
	var done *accessUnit
	if d.haveTS && ts != d.ts && (len(d.nals) > 0 || d.inFU || d.broken) {
		done = d.finish()
	}
	if !d.haveTS || ts != d.ts {
		d.ts, d.haveTS = ts, true
	}
	var err error
	switch d.codec {
	case codecH264:
		err = d.pushH264(payload)
	case codecH265:
		err = d.pushH265(payload)
	default:
		err = errors.New("depacketizer: no codec")
	}
	if err != nil {
		d.broken = true
	}
	if marker {
		if au := d.finish(); au != nil {
			if done != nil {
				// Both the previous (unterminated) picture and this one ended here; keep the newer, count the older as dropped.
				d.Dropped++
			}
			done = au
		}
	}
	return done, err
}

func (d *depacketizer) finish() *accessUnit {
	nals, broken := d.nals, d.broken || d.inFU
	d.nals, d.broken, d.inFU, d.fu = nil, false, false, nil
	if len(nals) == 0 {
		return nil
	}
	key := false
	hasParams := false
	for _, n := range nals {
		switch d.nalKind(n) {
		case nalKey:
			key = true
		case nalParam:
			hasParams = true
		}
	}
	if broken {
		d.Dropped++
		d.waitKey = true
		return nil
	}
	if d.waitKey && !key {
		d.Dropped++
		return nil
	}
	if key {
		d.waitKey = false
	}
	size := 0
	for _, n := range nals {
		size += 4 + len(n)
	}
	var pre [][]byte
	if key && !hasParams {
		pre = d.paramSets()
		for _, n := range pre {
			size += 4 + len(n)
		}
	}
	out := make([]byte, 0, size)
	for _, n := range pre {
		out = append(append(out, annexB...), n...)
	}
	for _, n := range nals {
		out = append(append(out, annexB...), n...)
	}
	return &accessUnit{Data: out, Timestamp: d.ts, Key: key, Codec: d.codec}
}

type nalClass int

const (
	nalOther nalClass = iota
	nalKey
	nalParam
)

func (d *depacketizer) nalKind(n []byte) nalClass {
	if len(n) == 0 {
		return nalOther
	}
	if d.codec == codecH264 {
		switch n[0] & 0x1f {
		case 5:
			return nalKey
		case 7, 8:
			return nalParam
		}
		return nalOther
	}
	t := (n[0] >> 1) & 0x3f
	switch {
	case t >= 16 && t <= 21:
		return nalKey
	case t >= 32 && t <= 34:
		return nalParam
	}
	return nalOther
}

func (d *depacketizer) paramSets() [][]byte {
	var out [][]byte
	for _, p := range [][]byte{d.vps, d.sps, d.pps} {
		if p != nil {
			out = append(out, p)
		}
	}
	return out
}

// addNAL appends a complete NAL unit to the current access unit and remembers parameter sets.
func (d *depacketizer) addNAL(n []byte) {
	if len(n) == 0 {
		return
	}
	n = append([]byte(nil), n...)
	if d.codec == codecH264 {
		switch n[0] & 0x1f {
		case 7:
			d.sps = n
		case 8:
			d.pps = n
		case 9: // access unit delimiter: dropped, the muxer does not need it
			return
		}
	} else {
		switch (n[0] >> 1) & 0x3f {
		case 32:
			d.vps = n
		case 33:
			d.sps = n
		case 34:
			d.pps = n
		case 35: // AUD
			return
		}
	}
	d.nals = append(d.nals, n)
}

var errShort = errors.New("depacketizer: payload too short")

func (d *depacketizer) pushH264(p []byte) error {
	if len(p) < 1 {
		return errShort
	}
	switch t := p[0] & 0x1f; {
	case t >= 1 && t <= 23:
		d.inFU = false
		d.addNAL(p)
	case t == 24: // STAP-A: [hdr][size16][nal]...
		d.inFU = false
		p = p[1:]
		for len(p) > 0 {
			if len(p) < 2 {
				return errShort
			}
			n := int(p[0])<<8 | int(p[1])
			p = p[2:]
			if n == 0 || n > len(p) {
				return errors.New("depacketizer: bad STAP-A size")
			}
			d.addNAL(p[:n])
			p = p[n:]
		}
	case t == 28: // FU-A: [indicator][S E R type][data]
		if len(p) < 2 {
			return errShort
		}
		start, end := p[1]&0x80 != 0, p[1]&0x40 != 0
		if start {
			d.fu = append([]byte{p[0]&0xe0 | p[1]&0x1f}, p[2:]...)
			d.inFU = true
		} else {
			if !d.inFU {
				return errors.New("depacketizer: FU-A without its start")
			}
			d.fu = append(d.fu, p[2:]...)
		}
		if end {
			d.inFU = false
			d.addNAL(d.fu)
			d.fu = nil
		}
	default: // STAP-B, MTAP, FU-B: not used in packetization-mode 1
		return errors.New("depacketizer: unsupported H.264 packet type")
	}
	return nil
}

func (d *depacketizer) pushH265(p []byte) error {
	if len(p) < 3 {
		return errShort
	}
	switch t := (p[0] >> 1) & 0x3f; t {
	case 48: // AP: [hdr2][size16][nal]...
		d.inFU = false
		p = p[2:]
		for len(p) > 0 {
			if len(p) < 2 {
				return errShort
			}
			n := int(p[0])<<8 | int(p[1])
			p = p[2:]
			if n < 2 || n > len(p) {
				return errors.New("depacketizer: bad AP size")
			}
			d.addNAL(p[:n])
			p = p[n:]
		}
	case 49: // FU: [hdr2][S E type6][data]
		start, end := p[2]&0x80 != 0, p[2]&0x40 != 0
		ft := p[2] & 0x3f
		if start {
			hdr0 := p[0]&0x81 | ft<<1
			d.fu = append([]byte{hdr0, p[1]}, p[3:]...)
			d.inFU = true
		} else {
			if !d.inFU {
				return errors.New("depacketizer: FU without its start")
			}
			d.fu = append(d.fu, p[3:]...)
		}
		if end {
			d.inFU = false
			d.addNAL(d.fu)
			d.fu = nil
		}
	case 50: // PACI: not produced by the gateway; skip without breaking the picture
		return nil
	default:
		d.inFU = false
		d.addNAL(p)
	}
	return nil
}
