// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

// sink is where Annex B access units go: stdout, or ffmpeg pushing RTSP into go2rtc.
type sink interface {
	io.Writer
	Close() error
	Done() <-chan struct{} // closed when the sink can no longer take data
}

type stdoutSink struct {
	once sync.Once
	done chan struct{}
}

func newStdoutSink() *stdoutSink { return &stdoutSink{done: make(chan struct{})} }

func (s *stdoutSink) Write(p []byte) (int, error) {
	n, err := os.Stdout.Write(p)
	if err != nil {
		s.once.Do(func() { close(s.done) })
	}
	return n, err
}
func (s *stdoutSink) Close() error          { return nil }
func (s *stdoutSink) Done() <-chan struct{} { return s.done }

// ffmpegArgs is the command line: MPEG-TS in on stdin (each picture and audio frame carries its RTP time as PTS), video
// stream copy, audio (when the TS has it) transcoded to AAC-LC 16 kHz mono with gaps filled, RTSP ANNOUNCE/RECORD over TCP
// to go2rtc. The codec only names the stream in logs: the PMT tells ffmpeg.
func ffmpegArgs(level string, codec videoCodec, url string, audio bool) []string {
	_ = codec
	a := []string{
		"-hide_banner", "-nostdin", "-loglevel", level,
		"-fflags", "+genpts",
		"-probesize", "8M", "-analyzeduration", "1000000",
		"-f", "mpegts", "-i", "pipe:0",
		"-map", "0:v:0", "-c:v", "copy",
	}
	if audio {
		a = append(a, "-map", "0:a:0?", "-c:a", "aac", "-b:a", "64k", "-ar", "16000", "-ac", "1", "-af", "aresample=async=1")
	}
	return append(a, "-f", "rtsp", "-rtsp_transport", "tcp", url)
}

type ffmpegSink struct {
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	done    chan struct{}
	exitErr error // valid once done is closed
}

func startFFmpeg(bin, level string, codec videoCodec, url string, audio bool) (*ffmpegSink, error) {
	cmd := exec.Command(bin, ffmpegArgs(level, codec, url, audio)...)
	cmd.Env = os.Environ() // the secrets were unset when they were read
	cmd.Stdout = os.Stderr
	cmd.Stderr = &redactingWriter{w: os.Stderr}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	s := &ffmpegSink{cmd: cmd, stdin: stdin, done: make(chan struct{})}
	go func() {
		err := cmd.Wait()
		s.exitErr = err
		status("event=ffmpeg_exit reason=%s", q(fmt.Sprint(err)))
		close(s.done)
	}()
	return s, nil
}

func (s *ffmpegSink) Write(p []byte) (int, error) {
	select {
	case <-s.done:
		return 0, errors.New("ffmpeg exited")
	default:
	}
	return s.stdin.Write(p)
}

func (s *ffmpegSink) Close() error {
	_ = s.stdin.Close()
	select {
	case <-s.done:
	case <-time.After(3 * time.Second):
		_ = s.cmd.Process.Kill()
		<-s.done
	}
	return nil
}
func (s *ffmpegSink) Done() <-chan struct{} { return s.done }

// redactingWriter passes ffmpeg's stderr through the redactor (ffmpeg prints the output URL).
type redactingWriter struct{ w io.Writer }

func (r *redactingWriter) Write(p []byte) (int, error) {
	if _, err := io.WriteString(r.w, secrets.apply(string(p))); err != nil {
		return 0, err
	}
	return len(p), nil
}

// openSinkHook replaces the real output in tests (it is fed MPEG-TS, like ffmpeg).
var openSinkHook func(codec videoCodec, audio *audioFormat) (sink, error)

// lazySink opens the real sink at the first keyframe, when the codec (and whether audio flows) is known. If ffmpeg fails soon
// after it was opened with audio, the audio is blamed: the sink asks to be reopened video-only instead of ending the session.
type lazySink struct {
	output, ffmpeg, level string
	open                  func(codec videoCodec, audio *audioFormat) (sink, error)

	mu       sync.Mutex
	cur      sink
	ts       *tsMuxer // set unless the output is stdout: pictures go in as MPEG-TS with their own timestamps
	audio    *audioFormat
	openedAt time.Time
	reopen   bool // ffmpeg died early with audio: open again without it
	retried  bool
	closing  bool
	done     chan struct{}
	once     sync.Once
}

// audioRetryWindow: an ffmpeg exit this soon after opening with audio is treated as an audio problem.
const audioRetryWindow = 20 * time.Second

func newLazySink(output, ffmpeg, level string) *lazySink {
	l := &lazySink{output: output, ffmpeg: ffmpeg, level: level, done: make(chan struct{})}
	l.open = func(codec videoCodec, audio *audioFormat) (sink, error) {
		if openSinkHook != nil {
			return openSinkHook(codec, audio)
		}
		if l.output == "stdout" {
			return newStdoutSink(), nil
		}
		return startFFmpeg(l.ffmpeg, l.level, codec, l.output, audio != nil)
	}
	return l
}

// carriesAudio tells whether this output can carry audio at all (raw Annex B on stdout cannot).
func (l *lazySink) carriesAudio() bool { return l.output != "stdout" || openSinkHook != nil }

func (l *lazySink) start(codec videoCodec, audio *audioFormat) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.cur != nil {
		return nil
	}
	if !l.carriesAudio() {
		audio = nil
	}
	s, err := l.open(codec, audio)
	if err != nil {
		return err
	}
	l.cur, l.audio, l.openedAt, l.reopen = s, audio, time.Now(), false
	l.ts = nil
	if l.carriesAudio() {
		l.ts = newTSMuxer(s, codec, audio)
	}
	go func() {
		<-s.Done()
		l.mu.Lock()
		defer l.mu.Unlock()
		failed := true
		if fs, ok := s.(*ffmpegSink); ok && fs.exitErr == nil {
			failed = false // a clean exit (stdin closed by us) is not an audio problem
		}
		if !l.closing && failed && l.cur == s && l.audio != nil && !l.retried && time.Since(l.openedAt) < audioRetryWindow {
			l.retried, l.reopen = true, true
			status("event=audio_problem reason=%s", q("ffmpeg stopped soon after audio was added; going on with video only"))
			return
		}
		l.once.Do(func() { close(l.done) })
	}()
	return nil
}

// wantsReopen reports (once) that the output must be opened again, video only; the old one is dropped.
func (l *lazySink) wantsReopen() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.reopen {
		return false
	}
	l.reopen, l.cur, l.ts, l.audio = false, nil, nil, nil
	return true
}

// failedForAudio waits briefly after a write error to learn whether the failure is the early-audio case.
func (l *lazySink) failedForAudio() bool {
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-l.done:
			return false
		default:
		}
		l.mu.Lock()
		r := l.reopen
		l.mu.Unlock()
		if r {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func (l *lazySink) hasAudio() bool { l.mu.Lock(); defer l.mu.Unlock(); return l.audio != nil }

// paced tells whether pictures must be written at their RTP time (raw Annex B carries no timestamps; MPEG-TS does).
func (l *lazySink) paced() bool { l.mu.Lock(); defer l.mu.Unlock(); return l.ts == nil }

// writeAU writes one picture: as MPEG-TS, or as raw Annex B.
func (l *lazySink) writeAU(au *accessUnit) error {
	l.mu.Lock()
	cur, ts := l.cur, l.ts
	l.mu.Unlock()
	if cur == nil {
		return errors.New("sink not started")
	}
	if ts != nil {
		return ts.writeAU(au)
	}
	_, err := cur.Write(au.Data)
	return err
}

// muxer is the TS muxer, for the audio path (nil for stdout or before the first picture).
func (l *lazySink) muxer() *tsMuxer { l.mu.Lock(); defer l.mu.Unlock(); return l.ts }

func (l *lazySink) Close() error {
	l.mu.Lock()
	cur := l.cur
	l.closing = true
	l.mu.Unlock()
	if cur != nil {
		return cur.Close()
	}
	return nil
}

func (l *lazySink) Done() <-chan struct{} { return l.done }

// pacer writes each access unit at its RTP time plus a fixed playout delay, so that the arrival clock ffmpeg stamps with is the
// camera's picture clock and the bursts the reorder buffer releases after a repaired gap don't squeeze timestamps together.
type pacer struct {
	delay    time.Duration
	baseWall time.Time
	basePTS  int64
	lastTS   uint32
	ext      int64 // unwrapped RTP timestamp
	started  bool
}

// due returns when an access unit with RTP timestamp ts should be written; now is the current time.
func (p *pacer) due(ts uint32, now time.Time) time.Time {
	if !p.started {
		p.started, p.lastTS, p.ext = true, ts, int64(ts)
		p.rebase(now)
		return now.Add(p.delay)
	}
	p.ext += int64(int32(ts - p.lastTS))
	p.lastTS = ts
	at := p.baseWall.Add(time.Duration(p.ext-p.basePTS) * time.Second / 90000)
	// Running late by more than the delay again (a stall, the camera's clock drifting from ours) or far ahead (a timestamp
	// jump): start a new timeline here rather than burst or wait.
	if lag := now.Sub(at); lag > p.delay || lag < -(p.delay+2*time.Second) {
		p.rebase(now)
		at = now.Add(p.delay)
	}
	return at
}

func (p *pacer) rebase(now time.Time) {
	p.baseWall = now.Add(p.delay)
	p.basePTS = p.ext
}
