// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"time"

	"github.com/pion/rtp"
)

// reorderBuffer puts RTP packets back in sequence order. Agora's gateway answers NACKs by resending the lost packet with its
// original sequence number on the same SSRC, so a repaired packet can arrive hundreds of positions late (docker-wyze-bridge
// PR #161 measured 277). Packets wait up to maxDelay for a gap to fill; then the gap is skipped and reported as loss.
type reorderBuffer struct {
	size     int
	maxDelay time.Duration
	slots    []reorderSlot
	next     uint16
	started  bool
	count    int

	// statistics
	Late, Duplicate, Lost, Reordered uint64
}

type reorderSlot struct {
	used    bool
	seq     uint16
	arrived time.Time
	pkt     *rtp.Packet
}

// reorderOut is one emitted packet, or a loss marker (Pkt nil, Lost = number of skipped packets) before the packet after a gap.
type reorderOut struct {
	Pkt     *rtp.Packet
	Lost    int
	Arrived time.Time
}

func newReorderBuffer(size int, maxDelay time.Duration) *reorderBuffer {
	return &reorderBuffer{size: size, maxDelay: maxDelay, slots: make([]reorderSlot, size)}
}

func seqDiff(a, b uint16) int { return int(int16(a - b)) }

// push stores one packet and returns whatever is now ready, in order.
func (r *reorderBuffer) push(p *rtp.Packet, now time.Time, out []reorderOut) []reorderOut {
	seq := p.SequenceNumber
	if !r.started {
		r.started, r.next = true, seq
	}
	d := seqDiff(seq, r.next)
	switch {
	case d < 0:
		if d < -r.size*4 { // the sender restarted its sequence: start over
			out = r.flushAll(out)
			r.next = seq
			d = 0
		} else {
			r.Late++
			return out
		}
	case d >= r.size: // too far ahead to hold: give up on everything before it
		out = r.flushAll(out)
		if r.next != seq {
			gap := seqDiff(seq, r.next)
			r.Lost += uint64(gap)
			out = append(out, reorderOut{Lost: gap})
		}
		r.next = seq
		d = 0
	}
	s := &r.slots[int(seq)%r.size]
	if s.used && s.seq == seq {
		r.Duplicate++
		return out
	}
	if d > 0 {
		r.Reordered++ // it arrived before something older; counted when buffered out of order
	}
	*s = reorderSlot{used: true, seq: seq, arrived: now, pkt: p}
	r.count++
	return r.drain(now, out)
}

// tick releases packets held behind a gap that has waited too long; call it regularly.
func (r *reorderBuffer) tick(now time.Time, out []reorderOut) []reorderOut {
	return r.drain(now, out)
}

func (r *reorderBuffer) drain(now time.Time, out []reorderOut) []reorderOut {
	for r.count > 0 {
		s := &r.slots[int(r.next)%r.size]
		if s.used && s.seq == r.next {
			out = append(out, reorderOut{Pkt: s.pkt, Arrived: s.arrived})
			*s = reorderSlot{}
			r.count--
			r.next++
			continue
		}
		// A gap at r.next: find the first held packet after it.
		first := -1
		for i := 1; i < r.size; i++ {
			c := &r.slots[int(r.next+uint16(i))%r.size]
			if c.used && c.seq == r.next+uint16(i) {
				first = i
				break
			}
		}
		if first < 0 {
			return out
		}
		c := &r.slots[int(r.next+uint16(first))%r.size]
		if now.Sub(c.arrived) < r.maxDelay && r.count < r.size*3/4 {
			return out
		}
		r.Lost += uint64(first)
		out = append(out, reorderOut{Lost: first})
		r.next += uint16(first)
	}
	return out
}

func (r *reorderBuffer) flushAll(out []reorderOut) []reorderOut {
	for r.count > 0 {
		s := &r.slots[int(r.next)%r.size]
		if s.used && s.seq == r.next {
			out = append(out, reorderOut{Pkt: s.pkt, Arrived: s.arrived})
			*s = reorderSlot{}
			r.count--
		} else {
			skipped := 0
			for !(s.used && s.seq == r.next) && skipped < r.size {
				r.next++
				skipped++
				s = &r.slots[int(r.next)%r.size]
			}
			r.Lost += uint64(skipped)
			out = append(out, reorderOut{Lost: skipped})
			continue
		}
		r.next++
	}
	return out
}
