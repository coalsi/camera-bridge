// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import "errors"

// Picture size from a sequence parameter set (ITU-T H.264 7.3.2.1.1, H.265 7.3.2.2), cropping applied. Only the fields
// before the size are walked.

type bitReader struct {
	b   []byte
	pos int // bit position
}

var errSPS = errors.New("sps: truncated")

func (r *bitReader) u(n int) (uint, error) {
	var v uint
	for i := 0; i < n; i++ {
		if r.pos >= len(r.b)*8 {
			return 0, errSPS
		}
		v = v<<1 | uint(r.b[r.pos/8]>>(7-r.pos%8)&1)
		r.pos++
	}
	return v, nil
}

func (r *bitReader) ue() (uint, error) {
	zeros := 0
	for {
		b, err := r.u(1)
		if err != nil {
			return 0, err
		}
		if b == 1 {
			break
		}
		zeros++
		if zeros > 31 {
			return 0, errSPS
		}
	}
	v, err := r.u(zeros)
	return (1<<zeros - 1) + v, err
}

func (r *bitReader) se() (int, error) {
	v, err := r.ue()
	if v&1 == 1 {
		return int(v+1) / 2, err
	}
	return -int(v / 2), err
}

func (r *bitReader) skip(n int) { r.pos += n }

// unescapeRBSP removes emulation prevention bytes (00 00 03 -> 00 00).
func unescapeRBSP(b []byte) []byte {
	out := make([]byte, 0, len(b))
	zeros := 0
	for _, c := range b {
		if zeros >= 2 && c == 3 {
			zeros = 0
			continue
		}
		if c == 0 {
			zeros++
		} else {
			zeros = 0
		}
		out = append(out, c)
	}
	return out
}

// spsSize finds the SPS in an Annex B access unit and returns its picture size.
func spsSize(codec videoCodec, au []byte) (int, int, bool) {
	for _, n := range splitAnnexB(au) {
		if codec == codecH264 && len(n) > 4 && n[0]&0x1f == 7 {
			w, h, err := h264SPSSize(unescapeRBSP(n[1:]))
			return w, h, err == nil
		}
		if codec == codecH265 && len(n) > 4 && (n[0]>>1)&0x3f == 33 {
			w, h, err := h265SPSSize(unescapeRBSP(n[2:]))
			return w, h, err == nil
		}
	}
	return 0, 0, false
}

func h264SPSSize(b []byte) (int, int, error) {
	r := &bitReader{b: b}
	profile, _ := r.u(8)
	r.skip(16)                        // constraint flags, level
	if _, err := r.ue(); err != nil { // sps id
		return 0, 0, err
	}
	chroma := uint(1)
	switch profile {
	case 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135:
		chroma, _ = r.ue()
		if chroma == 3 {
			r.skip(1)
		}
		r.ue() // bit depth luma
		r.ue() // bit depth chroma
		r.skip(1)
		if f, _ := r.u(1); f == 1 { // scaling matrices
			lists := 8
			if chroma == 3 {
				lists = 12
			}
			for i := 0; i < lists; i++ {
				if p, _ := r.u(1); p == 1 {
					size := 16
					if i >= 6 {
						size = 64
					}
					last, next := 8, 8
					for j := 0; j < size; j++ {
						if next != 0 {
							d, err := r.se()
							if err != nil {
								return 0, 0, err
							}
							next = (last + d + 256) % 256
						}
						if next != 0 {
							last = next
						}
					}
				}
			}
		}
	}
	r.ue() // log2_max_frame_num_minus4
	poc, _ := r.ue()
	switch poc {
	case 0:
		r.ue()
	case 1:
		r.skip(1)
		r.se()
		r.se()
		n, _ := r.ue()
		for i := uint(0); i < n; i++ {
			r.se()
		}
	}
	r.ue()    // max_num_ref_frames
	r.skip(1) // gaps
	wmb, _ := r.ue()
	hmap, _ := r.ue()
	frameMbsOnly, _ := r.u(1)
	if frameMbsOnly == 0 {
		r.skip(1)
	}
	r.skip(1) // direct_8x8
	w := int(wmb+1) * 16
	h := int(2-frameMbsOnly) * int(hmap+1) * 16
	crop, err := r.u(1)
	if err != nil {
		return 0, 0, err
	}
	if crop == 1 {
		l, _ := r.ue()
		rt, _ := r.ue()
		t, _ := r.ue()
		bt, err := r.ue()
		if err != nil {
			return 0, 0, err
		}
		cx, cy := 1, int(2-frameMbsOnly)
		if chroma == 1 || chroma == 2 {
			cx = 2
		}
		if chroma == 1 {
			cy *= 2
		}
		w -= cx * int(l+rt)
		h -= cy * int(t+bt)
	}
	return w, h, nil
}

func h265SPSSize(b []byte) (int, int, error) {
	r := &bitReader{b: b}
	r.skip(4) // vps id
	maxSub, _ := r.u(3)
	r.skip(1)
	// profile_tier_level(1, maxSub)
	r.skip(96)
	subProfile := make([]uint, maxSub)
	subLevel := make([]uint, maxSub)
	for i := uint(0); i < maxSub; i++ {
		subProfile[i], _ = r.u(1)
		subLevel[i], _ = r.u(1)
	}
	if maxSub > 0 {
		r.skip(int(8-maxSub) * 2)
	}
	for i := uint(0); i < maxSub; i++ {
		if subProfile[i] == 1 {
			r.skip(88)
		}
		if subLevel[i] == 1 {
			r.skip(8)
		}
	}
	r.ue() // sps id
	chroma, _ := r.ue()
	if chroma == 3 {
		r.skip(1)
	}
	w, _ := r.ue()
	h, _ := r.ue()
	win, err := r.u(1)
	if err != nil {
		return 0, 0, err
	}
	W, H := int(w), int(h)
	if win == 1 {
		l, _ := r.ue()
		rt, _ := r.ue()
		t, _ := r.ue()
		bt, err := r.ue()
		if err != nil {
			return 0, 0, err
		}
		sx, sy := 1, 1
		if chroma == 1 || chroma == 2 {
			sx = 2
		}
		if chroma == 1 {
			sy = 2
		}
		W -= sx * int(l+rt)
		H -= sy * int(t+bt)
	}
	if W <= 0 || H <= 0 || W > 16384 || H > 16384 {
		return 0, 0, errSPS
	}
	return W, H, nil
}
