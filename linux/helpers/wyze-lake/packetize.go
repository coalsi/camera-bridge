// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"bytes"

	"github.com/pion/rtp"
)

// The sender's side of RFC 6184 / RFC 7798, used by the self test and the unit tests: split an Annex B stream into NAL units
// and access units, and packetise them the way a WebRTC sender does (small NAL units aggregated, large ones fragmented).

// splitAnnexB returns the NAL units of an Annex B buffer (start codes removed).
func splitAnnexB(b []byte) [][]byte {
	var out [][]byte
	start := -1
	i := 0
	for i+2 < len(b) {
		if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 {
			if start >= 0 {
				end := i
				for end > start && b[end-1] == 0 {
					end--
				}
				out = append(out, b[start:end])
			}
			i += 3
			start = i
			continue
		}
		i++
	}
	if start >= 0 && start < len(b) {
		out = append(out, b[start:])
	}
	return out
}

// groupAccessUnits groups NAL units into pictures: a new picture begins at a parameter set or AUD that follows a slice, or
// at a slice that is the first of its picture.
func groupAccessUnits(codec videoCodec, nals [][]byte) [][][]byte {
	var aus [][][]byte
	var cur [][]byte
	sawSlice := false
	for _, n := range nals {
		if len(n) == 0 {
			continue
		}
		isSlice, first, prefix := false, false, false
		if codec == codecH264 {
			t := n[0] & 0x1f
			isSlice = t >= 1 && t <= 5
			first = isSlice && len(n) > 1 && n[1]&0x80 != 0 // first_mb_in_slice == 0 (ue(v) "1")
			prefix = t == 6 || t == 7 || t == 8 || t == 9
		} else {
			if len(n) < 3 {
				continue
			}
			t := (n[0] >> 1) & 0x3f
			isSlice = t <= 31
			first = isSlice && n[2]&0x80 != 0 // first_slice_segment_in_pic_flag
			prefix = t >= 32 && t <= 39
		}
		if sawSlice && (prefix || first) {
			aus = append(aus, cur)
			cur, sawSlice = nil, false
		}
		cur = append(cur, n)
		if isSlice {
			sawSlice = true
		}
	}
	if len(cur) > 0 {
		aus = append(aus, cur)
	}
	return aus
}

// packetizer makes RTP packets of one access unit.
type packetizer struct {
	codec videoCodec
	mtu   int
	pt    uint8
	ssrc  uint32
	seq   uint16
}

func (p *packetizer) packets(au [][]byte, ts uint32) []*rtp.Packet {
	var payloads [][]byte
	var agg [][]byte
	aggSize := 0
	flush := func() {
		switch len(agg) {
		case 0:
		case 1:
			payloads = append(payloads, agg[0])
		default:
			var b bytes.Buffer
			if p.codec == codecH264 {
				b.WriteByte(agg[0][0]&0x60 | 24)
			} else {
				b.WriteByte(48 << 1)
				b.WriteByte(1)
			}
			for _, n := range agg {
				b.WriteByte(byte(len(n) >> 8))
				b.WriteByte(byte(len(n)))
				b.Write(n)
			}
			payloads = append(payloads, b.Bytes())
		}
		agg, aggSize = nil, 0
	}
	hdrLen := 1
	if p.codec == codecH265 {
		hdrLen = 2
	}
	for _, n := range au {
		if len(n)+hdrLen+2 <= p.mtu {
			if aggSize+len(n)+2+hdrLen > p.mtu {
				flush()
			}
			agg = append(agg, n)
			aggSize += len(n) + 2
			continue
		}
		flush()
		// fragment
		data := n[hdrLen:]
		chunk := p.mtu - hdrLen - 1
		for off := 0; off < len(data); off += chunk {
			end := off + chunk
			if end > len(data) {
				end = len(data)
			}
			var b []byte
			if p.codec == codecH264 {
				fh := n[0] & 0x1f
				if off == 0 {
					fh |= 0x80
				}
				if end == len(data) {
					fh |= 0x40
				}
				b = append([]byte{n[0]&0xe0 | 28, fh}, data[off:end]...)
			} else {
				t := (n[0] >> 1) & 0x3f
				fh := t
				if off == 0 {
					fh |= 0x80
				}
				if end == len(data) {
					fh |= 0x40
				}
				b = append([]byte{n[0]&0x81 | 49<<1, n[1], fh}, data[off:end]...)
			}
			payloads = append(payloads, b)
		}
	}
	flush()
	out := make([]*rtp.Packet, len(payloads))
	for i, pl := range payloads {
		out[i] = &rtp.Packet{Header: rtp.Header{Version: 2, PayloadType: p.pt, SequenceNumber: p.seq, Timestamp: ts,
			SSRC: p.ssrc, Marker: i == len(payloads)-1}, Payload: pl}
		p.seq++
	}
	return out
}
