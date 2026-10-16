// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSPSSizeKnown(t *testing.T) {
	// The SPS go2rtc reported for ffmpeg's 640x360 libx264 baseline push (sprop-parameter-sets).
	sps, _ := base64.StdEncoding.DecodeString("Z0LAFtoCgL/lwEQAAAMABAAAAwB4PFi6gA==")
	w, h, ok := spsSize(codecH264, annex(sps))
	if !ok || w != 640 || h != 360 {
		t.Fatal(w, h, ok)
	}
	if _, _, ok := spsSize(codecH265, annex(hevc(19, 1, 2))); ok {
		t.Fatal("no SPS, yet a size")
	}
}

// Real encoders' SPSs at sizes that need cropping (1080 and 360 are not multiples of 16), both codecs, several profiles.
func TestSPSSizeFromEncoders(t *testing.T) {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	dir := t.TempDir()
	cases := []struct {
		codec videoCodec
		w, h  int
		args  []string
	}{
		{codecH265, 1920, 1080, []string{"-c:v", "libx265", "-x265-params", "log-level=error"}},
		{codecH265, 640, 360, []string{"-c:v", "libx265", "-x265-params", "log-level=error"}},
		{codecH265, 3840, 2160, []string{"-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error"}},
		{codecH264, 1280, 720, []string{"-c:v", "libx264", "-profile:v", "baseline"}},
		{codecH264, 1920, 1080, []string{"-c:v", "libx264", "-profile:v", "high"}},
		{codecH264, 642, 362, []string{"-c:v", "libx264", "-profile:v", "high444"}},
	}
	for _, c := range cases {
		f := filepath.Join(dir, fmt.Sprintf("%d.%s", c.w, c.codec))
		args := append([]string{"-v", "error", "-f", "lavfi", "-i", fmt.Sprintf("testsrc2=size=%dx%d:rate=5", c.w, c.h), "-frames:v", "1"}, c.args...)
		args = append(args, "-f", c.codec.String(), f)
		if out, err := exec.Command(ff, args...).CombinedOutput(); err != nil {
			t.Skipf("%v: %s", err, out)
		}
		raw, _ := os.ReadFile(f)
		w, h, ok := spsSize(c.codec, raw)
		if !ok || w != c.w || h != c.h {
			t.Errorf("%s %dx%d: got %dx%d %v", c.codec, c.w, c.h, w, h, ok)
		}
	}
}

func TestQualityMapping(t *testing.T) {
	for q, want := range map[string]string{"": "HD", "hd": "HD", "2k": "2k", "sd": "360p", "SD": "SD", "360p": "360p", "low": ""} {
		res, low, err := qualityToResolution(q)
		if err != nil || res != want || low != (q == "low") {
			t.Errorf("%q -> %q %v %v", q, res, low, err)
		}
	}
	if _, _, err := qualityToResolution("1440p"); err == nil {
		t.Fatal("accepted 1440p")
	}
	j := buildJoinMessage(joinParams{Codec: "h265", LowStream: true})
	raw, _ := json.Marshal(j)
	if !strings.Contains(string(raw), `"default_video_stream":1`) {
		t.Fatal(string(raw))
	}
	if string(cameraCommands("u", "")) != `[{"action":"sight-safe::check-user","cmd":"run_action","params":{"userId":"u"}}]` {
		t.Fatal("low stream must send no resolution command")
	}
}

func TestResolutionEvent(t *testing.T) {
	logs := &syncBuffer{}
	log.SetOutput(logs)
	defer log.SetOutput(os.Stderr)
	old := openSinkHook
	defer func() { openSinkHook = old }()
	capture := &captureSink{done: make(chan struct{})}
	openSinkHook = func(videoCodec, *audioFormat) (sink, error) { return capture, nil }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	frames := make(chan *accessUnit, 8)
	go writeFrames(ctx, frames, make(chan audioPacket), newLazySink("rtsp://127.0.0.1:1/x", "ffmpeg", "warning"), &counters{},
		make(chan struct{}), make(chan sessionEnd, 1), &audioState{}, newAVClock(), "HD")
	sps, _ := base64.StdEncoding.DecodeString("Z0LAFtoCgL/lwEQAAAMABAAAAwB4PFi6gA==")
	key := &accessUnit{Data: annex(sps, []byte{0x68, 0xce, 0x0f, 0xc8}, []byte{0x65, 0x88, 1}), Timestamp: 0, Key: true, Codec: codecH264}
	frames <- key
	frames <- &accessUnit{Data: annex([]byte{0x41, 0x9a}), Timestamp: 3000, Codec: codecH264}
	k2 := *key
	k2.Timestamp = 6000
	frames <- &k2
	time.Sleep(200 * time.Millisecond)
	if n := strings.Count(logs.String(), "event=resolution requested=HD got=640x360"); n != 1 {
		t.Fatalf("%d resolution lines:\n%s", n, logs.String())
	}
}
