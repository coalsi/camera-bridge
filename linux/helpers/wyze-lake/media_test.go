// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"bytes"
	"os"
	"testing"
	"time"

	"github.com/pion/rtp"
)

func annex(nals ...[]byte) []byte {
	var b []byte
	for _, n := range nals {
		b = append(append(b, 0, 0, 0, 1), n...)
	}
	return b
}

func rep(b byte, n int) []byte { return bytes.Repeat([]byte{b}, n) }

// H.265 NAL header: type<<1, layer 0, tid 1.
func hevc(t byte, body ...byte) []byte { return append([]byte{t << 1, 1}, body...) }

func TestDepackH264SingleSTAPFU(t *testing.T) {
	d := newDepacketizer(codecH264)
	sps := []byte{0x67, 0x42, 0x00, 0x1f}
	pps := []byte{0x68, 0xce, 0x3c, 0x80}
	idr := append([]byte{0x65, 0x88}, rep(0xaa, 3000)...)
	// STAP-A with SPS+PPS
	stap := []byte{0x78, 0, byte(len(sps))}
	stap = append(stap, sps...)
	stap = append(stap, 0, byte(len(pps)))
	stap = append(stap, pps...)
	if au, err := d.push(stap, 1000, false); au != nil || err != nil {
		t.Fatal(au, err)
	}
	// FU-A IDR in three parts
	body := idr[1:]
	parts := [][]byte{body[:1000], body[1000:2000], body[2000:]}
	for i, p := range parts {
		fh := byte(5)
		if i == 0 {
			fh |= 0x80
		}
		if i == 2 {
			fh |= 0x40
		}
		au, err := d.push(append([]byte{0x7c, fh}, p...), 1000, i == 2)
		if err != nil {
			t.Fatal(err)
		}
		if i < 2 && au != nil {
			t.Fatal("early AU")
		}
		if i == 2 {
			if au == nil || !au.Key || au.Timestamp != 1000 || au.Codec != codecH264 {
				t.Fatalf("%+v", au)
			}
			if !bytes.Equal(au.Data, annex(sps, pps, idr)) {
				t.Fatal("annex B mismatch")
			}
		}
	}
	// a P slice as a single NAL, ended by the marker
	p := []byte{0x41, 0x9a, 1, 2, 3}
	au, _ := d.push(p, 4000, true)
	if au == nil || au.Key || !bytes.Equal(au.Data, annex(p)) {
		t.Fatalf("%+v", au)
	}
}

func TestDepackH265APFU(t *testing.T) {
	d := newDepacketizer(codecH265)
	vps, sps, pps := hevc(32, 0x0c, 1), hevc(33, 0x01, 2), hevc(34, 0xc1, 3)
	idr := hevc(19, append([]byte{0xaf}, rep(0x55, 2500)...)...) // IDR_W_RADL
	ap := []byte{48 << 1, 1}
	for _, n := range [][]byte{vps, sps, pps} {
		ap = append(ap, byte(len(n)>>8), byte(len(n)))
		ap = append(ap, n...)
	}
	if au, err := d.push(ap, 9000, false); au != nil || err != nil {
		t.Fatal(au, err)
	}
	payload := idr[2:]
	chunks := [][]byte{payload[:1200], payload[1200:2400], payload[2400:]}
	var au *accessUnit
	for i, c := range chunks {
		fh := byte(19)
		if i == 0 {
			fh |= 0x80
		}
		if i == len(chunks)-1 {
			fh |= 0x40
		}
		var err error
		au, err = d.push(append([]byte{49 << 1, 1, fh}, c...), 9000, i == len(chunks)-1)
		if err != nil {
			t.Fatal(err)
		}
	}
	if au == nil || !au.Key || au.Codec != codecH265 || !bytes.Equal(au.Data, annex(vps, sps, pps, idr)) {
		t.Fatalf("%+v", au)
	}
	// TRAIL_R single NAL; the access unit is ended by the next timestamp (marker lost)
	trail := hevc(1, 0xd0, 7, 7)
	if au, _ := d.push(trail, 12000, false); au != nil {
		t.Fatal("early")
	}
	au, _ = d.push(hevc(1, 0xd0, 8), 15000, true)
	if au == nil || au.Timestamp != 15000 {
		t.Fatalf("%+v", au)
	}
	if d.Dropped != 1 { // the unterminated picture was superseded in the same call
		t.Fatalf("dropped %d", d.Dropped)
	}
}

func TestDepackLossWaitsForKeyframeAndPrependsParams(t *testing.T) {
	d := newDepacketizer(codecH265)
	vps, sps, pps := hevc(32, 1), hevc(33, 2), hevc(34, 3)
	key := hevc(20, 0x80, 1) // CRA... type 20 is IDR_N_LP
	d.push(vps, 0, false)
	d.push(sps, 0, false)
	d.push(pps, 0, false)
	if au, _ := d.push(key, 0, true); au == nil || !au.Key {
		t.Fatal("first keyframe")
	}
	d.lost()
	if au, _ := d.push(hevc(1, 0x80, 9), 3000, true); au != nil {
		t.Fatal("picture after a loss passed")
	}
	if au, _ := d.push(hevc(1, 0x80, 9), 6000, true); au != nil {
		t.Fatal("dependent picture passed")
	}
	// keyframe without parameter sets: the cached ones go in front
	au, _ := d.push(key, 9000, true)
	if au == nil || !bytes.Equal(au.Data, annex(vps, sps, pps, key)) {
		t.Fatalf("%x", au.Data)
	}
	// FU continuation without its start breaks the picture
	if au, err := d.push([]byte{49 << 1, 1, 0x01, 1, 2}, 12000, true); au != nil || err == nil {
		t.Fatal("orphan FU accepted")
	}
	// starts dropping until a keyframe at the very beginning
	d2 := newDepacketizer(codecH264)
	if au, _ := d2.push([]byte{0x41, 0x9a}, 0, true); au != nil {
		t.Fatal("non-key first picture passed")
	}
}

func TestPacketizerRoundTripBothCodecs(t *testing.T) {
	for _, vc := range []videoCodec{codecH264, codecH265} {
		var aus [][][]byte
		if vc == codecH264 {
			aus = [][][]byte{
				{{0x67, 0x42, 0, 0x1f}, {0x68, 0xce}, append([]byte{0x65, 0x88}, rep(1, 5000)...)},
				{append([]byte{0x41, 0x9a}, rep(2, 300)...)},
				{append([]byte{0x41, 0x9a}, rep(3, 1300)...)},
			}
		} else {
			aus = [][][]byte{
				{hevc(32, 1), hevc(33, 2), hevc(34, 3), hevc(19, append([]byte{0x80}, rep(4, 7000)...)...)},
				{hevc(1, append([]byte{0x80}, rep(5, 200)...)...)},
				{hevc(1, append([]byte{0x80}, rep(6, 1500)...)...)},
			}
		}
		pz := &packetizer{codec: vc, mtu: 1200, pt: 100, ssrc: 1, seq: 65530}
		d := newDepacketizer(vc)
		var got [][]byte
		for i, au := range aus {
			for _, p := range pz.packets(au, uint32(i*3000)) {
				if len(p.Payload) > 1200 {
					t.Fatalf("payload %d > mtu", len(p.Payload))
				}
				if a, err := d.push(p.Payload, p.Timestamp, p.Marker); err != nil {
					t.Fatal(err)
				} else if a != nil {
					got = append(got, a.Data)
				}
			}
		}
		if len(got) != 3 {
			t.Fatalf("%s: %d access units", vc, len(got))
		}
		for i, au := range aus {
			if !bytes.Equal(got[i], annex(au...)) {
				t.Fatalf("%s: AU %d differs", vc, i)
			}
		}
		// and the Annex B splitter / grouper used by the self test agree
		var stream []byte
		for _, au := range aus {
			stream = append(stream, annex(au...)...)
		}
		groups := groupAccessUnits(vc, splitAnnexB(stream))
		if len(groups) != 3 || len(groups[0]) != 4-btoi(vc == codecH264) {
			t.Fatalf("%s: grouped %d", vc, len(groups))
		}
	}
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

func pkt(seq uint16) *rtp.Packet { return &rtp.Packet{Header: rtp.Header{SequenceNumber: seq}} }

func seqs(out []reorderOut) []int {
	var s []int
	for _, o := range out {
		if o.Pkt == nil {
			s = append(s, -o.Lost)
		} else {
			s = append(s, int(o.Pkt.SequenceNumber))
		}
	}
	return s
}

func TestReorderBuffer(t *testing.T) {
	now := time.Unix(0, 0)
	r := newReorderBuffer(4096, time.Second)
	var out []reorderOut
	for _, s := range []uint16{65534, 65535, 1, 0, 2} { // wraps, with 0 and 1 swapped
		out = r.push(pkt(s), now, out)
	}
	if got := seqs(out); len(got) != 5 || got[0] != 65534 || got[2] != 0 || got[3] != 1 || got[4] != 2 {
		t.Fatal(got)
	}
	out = out[:0]
	// 3 goes missing; 4..300 wait; a late repair of 3 within the window fills it
	for s := uint16(4); s <= 300; s++ {
		out = r.push(pkt(s), now.Add(time.Duration(s)*time.Millisecond), out)
	}
	if len(out) != 0 {
		t.Fatal("released across a gap early", seqs(out))
	}
	out = r.push(pkt(3), now.Add(500*time.Millisecond), out)
	if len(out) != 298 || out[0].Pkt.SequenceNumber != 3 || r.Lost != 0 {
		t.Fatal(len(out), r.Lost)
	}
	out = out[:0]
	// duplicate and late
	out = r.push(pkt(300), now, out)
	out = r.push(pkt(5), now, out)
	if len(out) != 0 || r.Late != 2 {
		t.Fatal(len(out), r.Late, r.Duplicate)
	}
	// 301 lost for good: the gap is skipped after maxDelay on tick
	t0 := now.Add(10 * time.Second)
	out = r.push(pkt(302), t0, out)
	out = r.tick(t0.Add(500*time.Millisecond), out)
	if len(out) != 0 {
		t.Fatal("skipped too early")
	}
	out = r.tick(t0.Add(1100*time.Millisecond), out)
	if got := seqs(out); len(got) != 2 || got[0] != -1 || got[1] != 302 || r.Lost != 1 {
		t.Fatal(got, r.Lost)
	}
	out = out[:0]
	// far ahead: everything before is given up
	out = r.push(pkt(302+5000), t0, out)
	if got := seqs(out); len(got) != 2 || got[0] != -(5000-1) || got[1] != 5302 {
		t.Fatal(got)
	}
}

func TestPacer(t *testing.T) {
	p := &pacer{delay: 200 * time.Millisecond}
	t0 := time.Unix(100, 0)
	if d := p.due(90000, t0); !d.Equal(t0.Add(200 * time.Millisecond)) {
		t.Fatal(d)
	}
	// 1/3 s later in RTP time, arriving early: due at its RTP time
	if d := p.due(90000+30000, t0.Add(10*time.Millisecond)); !d.Equal(t0.Add(200*time.Millisecond + time.Second/3)) {
		t.Fatal(d)
	}
	// wraps the 32-bit RTP clock
	p2 := &pacer{delay: 0}
	p2.due(0xffffff00, t0)
	if d := p2.due(0x00000100, t0); d.Sub(t0) != time.Duration(0x200)*time.Second/90000 {
		t.Fatal(d.Sub(t0))
	}
	// very late: rebased to now+delay instead of bursting
	if d := p.due(90000+60000, t0.Add(5*time.Second)); !d.Equal(t0.Add(5*time.Second + 200*time.Millisecond)) {
		t.Fatal(d)
	}
}

func TestRedaction(t *testing.T) {
	r := &redactor{}
	r.add("SUPERSECRETTOKEN123", "abc") // too short: ignored
	cases := map[string]string{
		"token is SUPERSECRETTOKEN123 here":              "token is *** here",
		"rtsp://user:pass@127.0.0.1:8554/x":              "rtsp://***@127.0.0.1:8554/x",
		"wss://1-2-3-4.edge.agora.io:4701/?key=v&t=1 ok": "wss://1-2-3-4.edge.agora.io:4701/?*** ok",
		`{"rtc_token":"zzz","uid":5}`:                    `{"rtc_token":***,"uid":5}`,
		"channel_name=foo keyframes=3":                   "channel_name=*** keyframes=3",
		"abc stays":                                      "abc stays",
	}
	for in, want := range cases {
		if got := r.apply(in); got != want {
			t.Errorf("%q -> %q, want %q", in, got, want)
		}
	}
	if got := q(`say "hi"` + "\nnext"); got != `"say 'hi' next"` {
		t.Fatal(got)
	}
}

func setEnv(t *testing.T, kv map[string]string) {
	for _, k := range []string{"CB_LAKE_ACCESS_TOKEN", "CB_LAKE_USER_ID", "CB_LAKE_PHONE_ID", "CB_LAKE_DEVICE_MAC", "CB_LAKE_DEVICE_MODEL",
		"CB_LAKE_OUTPUT", "CB_LAKE_QUALITY", "CB_LAKE_CODEC", "CB_LAKE_START_TIMEOUT", "CB_LAKE_STALL_TIMEOUT", "CB_LAKE_RCVBUF",
		"CB_LAKE_FFMPEG"} {
		t.Setenv(k, "")
		os.Unsetenv(k)
	}
	for k, v := range kv {
		t.Setenv(k, v)
	}
}

func goodEnv() map[string]string {
	return map[string]string{"CB_LAKE_ACCESS_TOKEN": "tok-123456", "CB_LAKE_USER_ID": "u-1", "CB_LAKE_PHONE_ID": "phone-abcdef",
		"CB_LAKE_DEVICE_MAC": "D03F27A1B2C3", "CB_LAKE_DEVICE_MODEL": "HL_PAN4", "CB_LAKE_OUTPUT": "rtsp://127.0.0.1:8554/cam"}
}

func TestLoadConfig(t *testing.T) {
	setEnv(t, goodEnv())
	c, err := loadConfig(false)
	if err != nil {
		t.Fatal(err)
	}
	if c.accessToken != "tok-123456" || c.mac != "D03F27A1B2C3" || c.resolution != "HD" || c.codec != codecH265 ||
		c.startTimeout != 90*time.Second || c.stallTimeout != 30*time.Second || c.ffmpeg != "ffmpeg" || c.rcvbuf != 8<<20 {
		t.Fatalf("%+v", c)
	}
	if os.Getenv("CB_LAKE_ACCESS_TOKEN") != "" || os.Getenv("CB_LAKE_PHONE_ID") != "" {
		t.Fatal("secrets left in the environment")
	}
	// the MAC is kept exactly as given
	e := goodEnv()
	e["CB_LAKE_DEVICE_MAC"] = "d0:3f:27:a1:b2:c3"
	e["CB_LAKE_QUALITY"] = "sd"
	e["CB_LAKE_STALL_TIMEOUT"] = "45"
	setEnv(t, e)
	c, err = loadConfig(false)
	if err != nil || c.mac != "d0:3f:27:a1:b2:c3" || c.resolution != "360p" || c.stallTimeout != 45*time.Second {
		t.Fatal(c, err)
	}

	bad := []func(map[string]string){
		func(m map[string]string) { delete(m, "CB_LAKE_ACCESS_TOKEN") },
		func(m map[string]string) { delete(m, "CB_LAKE_USER_ID") },
		func(m map[string]string) { delete(m, "CB_LAKE_DEVICE_MAC") },
		func(m map[string]string) { m["CB_LAKE_DEVICE_MAC"] = "has space" },
		func(m map[string]string) { delete(m, "CB_LAKE_DEVICE_MODEL") },
		func(m map[string]string) { delete(m, "CB_LAKE_OUTPUT") },
		func(m map[string]string) { m["CB_LAKE_OUTPUT"] = "udp://x" },
		func(m map[string]string) { m["CB_LAKE_QUALITY"] = "ultra" },
		func(m map[string]string) { m["CB_LAKE_CODEC"] = "vp8" },
		func(m map[string]string) { m["CB_LAKE_START_TIMEOUT"] = "-5s" },
		func(m map[string]string) { m["CB_LAKE_RCVBUF"] = "12" },
	}
	for i, f := range bad {
		e := goodEnv()
		f(e)
		setEnv(t, e)
		if _, err := loadConfig(false); err == nil {
			t.Errorf("bad config %d accepted", i)
		}
	}
	// the self test needs only the output
	setEnv(t, map[string]string{"CB_LAKE_OUTPUT": "stdout"})
	if _, err := loadConfig(true); err != nil {
		t.Fatal(err)
	}
}
