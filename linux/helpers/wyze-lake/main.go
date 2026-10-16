// wyze-lake: one Wyze "lake" camera (Wyze Cam Pan v4, HL_PAN4) -> its video through Wyze's cloud (Agora RTC) -> RTSP on
// loopback (go2rtc), or raw Annex B on stdout.
//
// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE). EXPERIMENTAL and unofficial: it makes the same calls as Wyze's
// own web viewer (my.wyze.com), with the account's own access token, for the account's own camera.
//
// One camera session per process; the process exits when the session ends, and the supervisor (camerabridged) owns restarts,
// backoff and the Wyze access token (minting and refreshing it). Everything else the session needs (the Agora channel, app id,
// RTC token, media key and salt) the helper fetches itself with that token, and it renews the RTC token inside the session.
//
// All configuration comes from the environment, never argv (the access token is a secret). Secret variables are removed from
// the environment as soon as they are read, so ffmpeg never inherits them.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
)

// Test seams: the Wyze web API and the client for Agora's access points.
var (
	wyzeBase = wyzeWebAPI
	apClient = &http.Client{Timeout: 10 * time.Second}
)

// Set with -ldflags "-X main.version=...".
var version = "dev"

// Exit codes (the contract with the supervisor; the same as wyze-gwell).
const (
	exitOK         = 0 // stopped by SIGTERM/SIGINT
	exitSession    = 1 // session failed (network, Agora, gateway, ICE): restart with backoff
	exitConfig     = 2 // bad or missing environment: do not restart until the configuration changes
	exitAuth       = 3 // Wyze refused the access token: mint a fresh one, then restart
	exitStall      = 4 // no video within the start timeout, or video stopped: restart
	exitOutput     = 5 // output failed (ffmpeg died, stdout closed): restart
	exitCameraGone = 6 // the camera has no lake stream on the account, or never came online: restart with long backoff
)

const usage = `wyze-lake %s - EXPERIMENTAL, unofficial

Streams one Wyze "lake" camera (Wyze Cam Pan v4, HL_PAN4) through Wyze's cloud (Agora) as H.265 (or H.264), with its
microphone (Opus or G.711, sent on as AAC-LC 16 kHz mono) when the camera publishes audio.
Configuration is read from the environment only:

  CB_LAKE_ACCESS_TOKEN   required  Wyze access token (secret, removed after read; refreshing it is the caller's job)
  CB_LAKE_USER_ID        required  Wyze user_id (the camera only publishes after "check-user" with it)
  CB_LAKE_DEVICE_MAC     required  device MAC exactly as Wyze's device list names it
  CB_LAKE_DEVICE_MODEL   required  product model, e.g. HL_PAN4
  CB_LAKE_OUTPUT         required  "stdout" (raw Annex B) or rtsp://127.0.0.1:<port>/<name> (RTSP push via ffmpeg, stream copy)
  CB_LAKE_PHONE_ID       optional  the phone_id the caller signed in with (accepted; the web-signed lake calls don't use it)
  CB_LAKE_QUALITY        optional  hd (default: camera::resolution=HD) | 2k | sd (360p) | low (Agora low/dual stream, no
                                   resolution command); or the camera's own values HD | SD | 360p. On the Pan v4 "HD" and
                                   "2k" are the same level, 3840x2160: the camera has no 1080p (see event=resolution)
  CB_LAKE_CODEC          optional  h265 (default; the Pan v4 sends only H.265) | h264
  CB_LAKE_FFMPEG         optional  ffmpeg path (default: ffmpeg)
  CB_LAKE_FFMPEG_LOGLEVEL optional ffmpeg -loglevel (default: warning)
  CB_LAKE_START_TIMEOUT  optional  max time to first video (default 90s)
  CB_LAKE_STALL_TIMEOUT  optional  max gap in video once started (default 30s)
  CB_LAKE_RCVBUF         optional  UDP receive buffer bytes (default 8388608; see the note on net.core.rmem_max)
  CB_LAKE_CONTROL        optional  127.0.0.1:<port>: serve the pan/tilt control API there (POST /move)
  CB_LAKE_CONTROL_TOKEN  with CONTROL  bearer token for it, at least 16 characters (secret, removed after read)

Arguments: --version, --help, or --self-test <file.h265|file.h264> [<audio.ogg (Opus)|audio.ulaw|audio.alaw (8 kHz)>] (no network: packetises the file as RTP, shuffles and
drops packets, and runs it through the receive path to CB_LAKE_OUTPUT; tests the ffmpeg/go2rtc side without a camera).

Logs go to stderr. Machine-readable lines start with "cb-lake ".
Exit codes: 0 stopped, 1 session error, 2 config, 3 auth (mint a new token), 4 stall, 5 output failed, 6 camera not listed/offline.
`

func logLine(s string) { log.Print(secrets.apply(s)) }

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(0) // the daemon reads "cb-lake " lines; journald adds the time

	args := os.Args[1:]
	selfTest, selfTestAudio := "", ""
	switch {
	case len(args) == 0:
	case len(args) == 1 && (args[0] == "--version" || args[0] == "-version" || args[0] == "-v"):
		fmt.Printf("wyze-lake %s\n", version)
		os.Exit(exitOK)
	case len(args) == 1 && (args[0] == "--help" || args[0] == "-help" || args[0] == "-h"):
		fmt.Printf(usage, version)
		os.Exit(exitOK)
	case (len(args) == 2 || len(args) == 3) && args[0] == "--self-test":
		selfTest = args[1]
		if len(args) == 3 {
			selfTestAudio = args[2]
		}
	default:
		fmt.Fprintf(os.Stderr, "wyze-lake takes no arguments (configuration is environment only); see --help\n")
		os.Exit(exitConfig)
	}

	cfg, err := loadConfig(selfTest != "")
	if err != nil {
		status("event=config_error reason=%s", q(err.Error()))
		os.Exit(exitConfig)
	}
	if selfTest != "" {
		os.Exit(runSelfTest(cfg, selfTest, selfTestAudio))
	}
	os.Exit(run(cfg))
}

// ---- configuration ------------------------------------------------------------------------------------------------------

type config struct {
	accessToken  string
	userID       string
	phoneID      string
	mac          string
	model        string
	output       string
	resolution   string // the camera::resolution value ("" sends none)
	lowStream    bool   // subscribe to Agora's low (dual) stream
	quality      string // as given
	codec        videoCodec
	ffmpeg       string
	ffmpegLevel  string
	startTimeout time.Duration
	stallTimeout time.Duration
	rcvbuf       int
	control      string
	controlToken string
}

// takeSecret reads a variable and removes it from the environment.
func takeSecret(name string) string {
	v := os.Getenv(name)
	_ = os.Unsetenv(name)
	return strings.TrimSpace(v)
}

func durationEnv(name string, def time.Duration) (time.Duration, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		// a bare number means seconds
		if n, e := strconv.Atoi(v); e == nil {
			d, err = time.Duration(n)*time.Second, nil
		}
	}
	if err != nil || d <= 0 {
		return 0, fmt.Errorf("%s: not a positive duration: %q", name, v)
	}
	return d, nil
}

// qualityToResolution maps CB_LAKE_QUALITY to the camera's camera::resolution value. Wyze's web viewer has exactly two
// levels: "high" sends "2k" when the device's metadata_json.res_level lists "2K", else "HD"; "low" sends "SD" when res_level
// lists "SD", else "360p" (the fallback res_level is ["360p","2k"]). On the Pan v4 the high level is 3840x2160 whichever of
// "HD"/"2k" names it: the camera has no 1080p level. "low" asks for Agora's low (dual) stream instead and sends no
// resolution command at all, so the camera's main level is left alone for other viewers.
func qualityToResolution(q string) (res string, lowStream bool, err error) {
	switch q {
	case "", "hd", "HD", "1080p":
		return "HD", false, nil
	case "2k", "4k":
		return "2k", false, nil
	case "sd", "360p":
		return "360p", false, nil
	case "SD":
		return "SD", false, nil
	case "low":
		return "", true, nil
	}
	return "", false, fmt.Errorf("CB_LAKE_QUALITY must be hd, 2k, sd or low (or HD, SD, 360p), got %q", q)
}

func validID(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for _, r := range s {
		if r <= ' ' || r == '"' || r == '\\' || r > '~' {
			return false
		}
	}
	return true
}

func loadConfig(selfTest bool) (*config, error) {
	c := &config{
		accessToken:  takeSecret("CB_LAKE_ACCESS_TOKEN"),
		phoneID:      takeSecret("CB_LAKE_PHONE_ID"),
		userID:       strings.TrimSpace(os.Getenv("CB_LAKE_USER_ID")),
		mac:          strings.TrimSpace(os.Getenv("CB_LAKE_DEVICE_MAC")),
		model:        strings.TrimSpace(os.Getenv("CB_LAKE_DEVICE_MODEL")),
		output:       strings.TrimSpace(os.Getenv("CB_LAKE_OUTPUT")),
		quality:      strings.TrimSpace(os.Getenv("CB_LAKE_QUALITY")),
		ffmpeg:       strings.TrimSpace(os.Getenv("CB_LAKE_FFMPEG")),
		ffmpegLevel:  strings.TrimSpace(os.Getenv("CB_LAKE_FFMPEG_LOGLEVEL")),
		rcvbuf:       8 << 20,
		control:      strings.TrimSpace(os.Getenv("CB_LAKE_CONTROL")),
		controlToken: takeSecret("CB_LAKE_CONTROL_TOKEN"),
	}
	secrets.add(c.accessToken, c.phoneID)
	var err error
	if c.startTimeout, err = durationEnv("CB_LAKE_START_TIMEOUT", 90*time.Second); err != nil {
		return nil, err
	}
	if c.stallTimeout, err = durationEnv("CB_LAKE_STALL_TIMEOUT", 30*time.Second); err != nil {
		return nil, err
	}
	if c.resolution, c.lowStream, err = qualityToResolution(c.quality); err != nil {
		return nil, err
	}
	if c.quality == "" {
		c.quality = "hd"
	}
	switch strings.ToLower(strings.TrimSpace(os.Getenv("CB_LAKE_CODEC"))) {
	case "", "h265", "hevc":
		c.codec = codecH265
	case "h264", "avc":
		c.codec = codecH264
	default:
		return nil, fmt.Errorf("CB_LAKE_CODEC must be h265 or h264")
	}
	if v := strings.TrimSpace(os.Getenv("CB_LAKE_RCVBUF")); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 65536 || n > 1<<30 {
			return nil, fmt.Errorf("CB_LAKE_RCVBUF must be a byte count between 65536 and 1073741824")
		}
		c.rcvbuf = n
	}
	if c.ffmpeg == "" {
		c.ffmpeg = "ffmpeg"
	}
	if c.ffmpegLevel == "" {
		c.ffmpegLevel = "warning"
	}
	switch {
	case c.output == "":
		return nil, errors.New("CB_LAKE_OUTPUT is required (stdout or rtsp://...)")
	case c.output != "stdout" && !strings.HasPrefix(c.output, "rtsp://"):
		return nil, fmt.Errorf("CB_LAKE_OUTPUT must be stdout or rtsp://..., got %q", redactURL(c.output))
	}
	secrets.add(c.controlToken)
	if c.control != "" {
		if err := validControlAddr(c.control); err != nil {
			return nil, err
		}
		if len(c.controlToken) < 16 {
			return nil, errors.New("CB_LAKE_CONTROL_TOKEN (at least 16 characters) is required with CB_LAKE_CONTROL")
		}
	}
	if selfTest {
		return c, nil
	}
	switch {
	case c.accessToken == "":
		return nil, errors.New("CB_LAKE_ACCESS_TOKEN is required")
	case !validID(c.userID):
		return nil, errors.New("CB_LAKE_USER_ID is required (the Wyze user_id)")
	case !validID(c.mac):
		return nil, errors.New("CB_LAKE_DEVICE_MAC is required (as Wyze's device list names it)")
	case !validID(c.model):
		return nil, errors.New("CB_LAKE_DEVICE_MODEL is required (e.g. HL_PAN4)")
	}
	return c, nil
}

// ---- the session ----------------------------------------------------------------------------------------------------------

// sessionEnd is how a session finished.
type sessionEnd struct {
	code   int
	event  string
	reason string
}

func classifyWyze(step string, err error) sessionEnd {
	var we *wyzeError
	switch {
	case errors.As(err, &we) && we.authRejected():
		return sessionEnd{exitAuth, "session_end", step + ": Wyze refused the access token (" + we.Code + ")"}
	case errors.Is(err, errCameraNotLake):
		return sessionEnd{exitCameraGone, "session_end", step + ": Wyze has no lake stream for this camera on the account"}
	case errors.As(err, &we):
		return sessionEnd{exitSession, "session_end", step + ": " + we.Error()}
	}
	return sessionEnd{exitSession, "session_end", step + ": " + err.Error()}
}

// requestedName is what event=resolution reports as requested.
func requestedName(c *config) string {
	if c.lowStream {
		return "low-stream"
	}
	return c.resolution
}

// counters shared between the media goroutines and the watchdog.
type counters struct {
	frames, bytes, keyframes atomic.Uint64
	audioFrames              atomic.Uint64
	lastWrite                atomic.Int64 // unix nanos of the last picture written
	rcvbufGot                atomic.Int64
	plis                     atomic.Uint64
}

func run(c *config) int {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)

	if c.model != "HL_PAN4" {
		status("event=warning reason=%s", q("only HL_PAN4 has been seen on the lake route; trying "+c.model))
	}
	status("event=start model=%s quality=%s resolution=%s codec=%s output=%s version=%s", c.model, c.quality, c.resolution,
		c.codec, redactURL(c.output), version)

	ptz := newPTZQueue()
	if c.control != "" {
		addr, err := startControl(ctx, c.control, c.controlToken, ptz)
		if err != nil {
			status("event=output_error code=%d reason=%s", exitOutput, q("control server: "+err.Error()))
			return exitOutput
		}
		status("event=control_listening port=%d", addr.(*net.TCPAddr).Port)
	}
	end := session(ctx, c, sig, ptz)
	status("event=%s code=%d reason=%s", end.event, end.code, q(end.reason))
	return end.code
}

func session(ctx context.Context, c *config, sig <-chan os.Signal, ptz *ptzQueue) sessionEnd {
	if ptz == nil {
		ptz = newPTZQueue()
	}
	defer ptz.ready.Store(false)
	stepCtx := func(d time.Duration) (context.Context, context.CancelFunc) { return context.WithTimeout(ctx, d) }
	wz := newWyzeClient(c.accessToken)
	wz.base = wyzeBase

	// 1. get-streams: the channel and the wrapped media key and salt.
	sctx, scancel := stepCtx(30 * time.Second)
	stream, err := wz.getStreams(sctx, c.mac, c.model)
	scancel()
	if err != nil {
		return classifyWyze("get-streams", err)
	}
	secrets.add(stream.Channel, stream.WrappedKey, stream.WrappedSalt)
	aesMode, err := aesModeName(stream.EncryptionMode)
	if err != nil {
		return sessionEnd{exitSession, "session_end", "get-streams: " + err.Error()}
	}
	var key, salt string
	if aesMode != "" {
		if key, err = unwrapSecret(stream.WrappedKey, c.accessToken); err != nil {
			return sessionEnd{exitSession, "session_end", "media key: " + err.Error()}
		}
		if salt, err = unwrapSecret(stream.WrappedSalt, c.accessToken); err != nil {
			return sessionEnd{exitSession, "session_end", "media salt: " + err.Error()}
		}
		secrets.add(key, salt)
	}
	status("event=provisioned step=get-streams protocol=%d encryption_mode=%d", stream.Protocol, stream.EncryptionMode)

	// 2. create-connection: a fresh one is what makes the camera join the channel (WRITEUP 7A).
	uid := randInt(10000, 99999)
	cctx, ccancel := stepCtx(30 * time.Second)
	conn, err := wz.createConnection(cctx, c.mac, c.model, uid)
	ccancel()
	if err != nil {
		return classifyWyze("create-connection", err)
	}
	secrets.add(conn.RTCToken, conn.AppID)
	uid = conn.UID
	status("event=provisioned step=create-connection uid=%d device_uid=%d p2p_mode=%t", conn.UID, conn.DeviceUID, conn.P2PMode)

	// 3. Agora access point: the gateways for this channel.
	sid := strings.ToUpper(randHex(16))
	actx, acancel := stepCtx(40 * time.Second)
	ap, err := chooseServer(actx, apClient, agoraAPHosts, conn.AppID, stream.Channel, conn.RTCToken, uid, sid)
	acancel()
	if err != nil {
		return sessionEnd{exitSession, "session_end", "agora access point: " + err.Error()}
	}
	if cert, ok := ap.APResponse["cert"].(string); ok {
		secrets.add(cert)
	}
	status("event=gateways count=%d", len(ap.Edges))

	// 4. Our PeerConnection and its offer.
	cnt := &counters{}
	pc, err := newPeerConnection(c.codec, c.rcvbuf, &cnt.rcvbufGot)
	if err != nil {
		return sessionEnd{exitSession, "session_end", "webrtc: " + err.Error()}
	}
	defer pc.Close()
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		return sessionEnd{exitSession, "session_end", "webrtc offer: " + err.Error()}
	}
	if err := pc.SetLocalDescription(offer); err != nil {
		return sessionEnd{exitSession, "session_end", "webrtc offer: " + err.Error()}
	}
	local, err := parseOffer(pc.LocalDescription().SDP)
	if err != nil {
		return sessionEnd{exitSession, "session_end", err.Error()}
	}
	var aesSecret string
	if aesMode != "" {
		if aesSecret, err = wrapMediaSecret(key); err != nil {
			return sessionEnd{exitSession, "session_end", "media key wrap: " + err.Error()}
		}
		secrets.add(aesSecret)
	}
	codecName := "h265"
	if c.codec == codecH264 {
		codecName = "h264"
	}

	// 5. join_v3 on the first gateway that takes it.
	var gw *gateway
	var gwORTC object
	var edge agoraEdge
	var stash []*gwMessage // notifications that arrived while waiting for the join reply
	lastReason := "no gateway"
	for i, e := range ap.Edges {
		g, err := dialGateway(ctx, e.URL)
		if err != nil {
			lastReason = fmt.Sprintf("gateway %d: connect failed", i)
			status("event=gateway_failed index=%d reason=%s", i, q("connect failed"))
			continue
		}
		join := buildJoinMessage(joinParams{AppID: conn.AppID, Channel: stream.Channel, RTCToken: conn.RTCToken, UID: uid,
			SessionID: sid, Codec: codecName, APResponse: ap.APResponse, ORTC: local.ortc(), AESMode: aesMode,
			AESSecret: aesSecret, AESSalt: salt, Now: time.Now(), LowStream: c.lowStream})
		joinID, err := g.send("join_v3", join)
		if err != nil {
			g.close()
			lastReason = fmt.Sprintf("gateway %d: join send failed", i)
			continue
		}
		ortc, pending, reason := waitJoin(ctx, g, joinID, 20*time.Second)
		if ortc == nil {
			g.close()
			lastReason = fmt.Sprintf("gateway %d: %s", i, reason)
			status("event=gateway_failed index=%d reason=%s", i, q(reason))
			continue
		}
		gw, gwORTC, edge, stash = g, ortc, e, pending
		status("event=joined gateway=%d", i)
		break
	}
	if gw == nil {
		return sessionEnd{exitSession, "session_end", "agora join: " + lastReason}
	}
	defer gw.close()

	// 6. Media: the reorder buffer, depacketiser and pacer run on their own goroutines; this loop owns signalling.
	frames := make(chan *accessUnit, 256)
	mediaErr := make(chan sessionEnd, 4)
	pliNow := make(chan struct{}, 1)
	var videoTrack atomic.Pointer[webrtc.TrackRemote]
	clk := newAVClock()
	as := &audioState{}
	audioCh := make(chan audioPacket, 256)
	pc.OnTrack(func(t *webrtc.TrackRemote, r *webrtc.RTPReceiver) {
		go func() { // keep RTCP flowing through the interceptors; keep the sender reports for A/V sync
			for {
				pkts, _, err := r.ReadRTCP()
				if err != nil {
					return
				}
				clk.senderReports(pkts)
			}
		}()
		if t.Kind() == webrtc.RTPCodecTypeAudio {
			c := t.Codec()
			f, ok := audioFormatFor(c.MimeType, c.ClockRate, c.Channels)
			if !ok {
				as.problem("unsupported audio codec " + c.MimeType)
				return
			}
			as.format.Store(f)
			status("event=audio_track codec=%s clock=%d channels=%d ssrc=%d", f.Codec, f.Clock, f.Channels, uint32(t.SSRC()))
			go receiveAudio(ctx, t, audioCh, as.problem)
			return
		}
		if t.Kind() != webrtc.RTPCodecTypeVideo {
			return
		}
		vc := codecH265
		if strings.EqualFold(t.Codec().MimeType, webrtc.MimeTypeH264) {
			vc = codecH264
		}
		videoTrack.Store(t)
		status("event=track codec=%s ssrc=%d rtx=%t", vc, uint32(t.SSRC()), t.HasRTX())
		go receiveTrack(ctx, t, vc, frames, pliNow, clk)
	})
	pcState := make(chan webrtc.PeerConnectionState, 8)
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		select {
		case pcState <- s:
		default:
		}
	})

	out := newLazySink(c.output, c.ffmpeg, c.ffmpegLevel)
	defer out.Close()
	firstVideo := make(chan struct{})
	go writeFrames(ctx, frames, audioCh, out, cnt, firstVideo, mediaErr, as, clk, requestedName(c))

	// Wake the camera now: it may wait for its viewer's check-user before it even joins (WRITEUP 4, PR #161).
	_ = gw.sendCommands(cameraCommands(c.userID, ""))

	ping := time.NewTicker(3 * time.Second)
	defer ping.Stop()
	control := time.NewTicker(4 * time.Second)
	defer control.Stop()
	watchdog := time.NewTicker(time.Second)
	defer watchdog.Stop()
	statsT := time.NewTicker(60 * time.Second)
	defer statsT.Stop()
	renewAfter := time.Duration(rtcTokenLifetime) * time.Second * 2 / 3 // 40 min
	renewT := time.NewTimer(renewAfter)
	defer renewT.Stop()
	renewDone := make(chan renewResult, 1)
	renewing := false
	renewID := ""

	started := time.Now()
	cameraOnline := false
	var subscribed, answered bool
	seenReplies := map[string]bool{}
	audioSubscribed := map[int64]bool{}
	var audioSSRCKnown int64 // the announced audio SSRC, if it came before the answer
	var video remoteVideo
	videoStarted := false
	lastPLI := time.Time{}

	drv := &ptzDriver{q: ptz}
	ptzTick := time.NewTicker(200 * time.Millisecond)
	defer ptzTick.Stop()
	sendMove := func() {
		if !cameraOnline {
			return
		}
		mv, ok := drv.next(time.Now())
		if !ok {
			return
		}
		if err := gw.sendCommands(moveCommand(mv)); err != nil {
			drv.ack()
			status("event=ptz_problem reason=%s", q("move send failed"))
			return
		}
		status("event=ptz_move direction=%s step=%d speed=%d queued=%d", mv.Direction, mv.Step, mv.Speed, ptz.pending())
	}
	startRenew := func() {
		if renewing {
			return
		}
		renewing = true
		go func() {
			rctx, rcancel := context.WithTimeout(ctx, 30*time.Second)
			tok, err := wz.renewToken(rctx, c.mac, c.model, uid)
			rcancel()
			renewDone <- renewResult{token: tok, err: err}
		}()
	}
	requestPLI := func() {
		t := videoTrack.Load()
		if t == nil || time.Since(lastPLI) < time.Second {
			return
		}
		lastPLI = time.Now()
		if pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: uint32(t.SSRC())}}) == nil {
			cnt.plis.Add(1)
		}
	}

	handle := func(m *gwMessage) *sessionEnd {
		switch m.Type {
		case "on_user_online":
			if u := anyInt(m.Message["uid"]); u != 0 && u != uid {
				if !cameraOnline {
					cameraOnline = true
					ptz.ready.Store(true)
					status("event=camera_online uid=%d", u)
				}
				_ = gw.sendCommands(cameraCommands(c.userID, c.resolution))
			}
		case "on_add_video_stream":
			if m.Message["video"] != true || anyInt(m.Message["ssrcId"]) == 0 {
				return nil
			}
			cameraOnline = true
			ptz.ready.Store(true)
			v := remoteVideo{UID: m.Message["uid"], SSRC: anyInt(m.Message["ssrcId"]), RTXSSRC: anyInt(m.Message["rtxSsrcId"]),
				CName: anyString(m.Message["cname"])}
			if answered && v.SSRC != video.SSRC {
				status("event=video_stream_changed reason=%s", q("the camera republished with a new SSRC"))
			}
			if !subscribed || v.SSRC != video.SSRC {
				if _, err := gw.send("subscribe", subscribeMessage(v.UID, m.Message["ssrcId"], codecName, "video")); err != nil {
					return &sessionEnd{exitSession, "session_end", "subscribe send failed"}
				}
				if c.lowStream { // what the Web SDK's setRemoteVideoStreamType(uid, LOW_STREAM) sends
					if _, err := gw.send("switch_video_stream", object{"stream_id": v.UID, "stream_type": 1}); err != nil {
						return &sessionEnd{exitSession, "session_end", "switch_video_stream send failed"}
					}
				}
				subscribed = true
			}
			if !answered {
				video = v
				ans, err := buildAnswer(local, gwORTC, video, audioSSRCKnown, edge.Fingerprint)
				if err != nil {
					return &sessionEnd{exitSession, "session_end", "answer: " + err.Error()}
				}
				if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: ans}); err != nil {
					return &sessionEnd{exitSession, "session_end", "answer: " + err.Error()}
				}
				answered = true
				status("event=video_stream ssrc=%d rtx_ssrc=%d", v.SSRC, v.RTXSSRC)
			}
		case "on_add_audio_stream":
			if m.Message["audio"] == false {
				return nil
			}
			ssrc := anyInt(m.Message["ssrcId"])
			if ssrc == 0 || audioSubscribed[ssrc] {
				return nil
			}
			audioSubscribed[ssrc] = true
			if !answered {
				audioSSRCKnown = ssrc
			}
			as.announced.Store(true)
			status("event=audio_stream ssrc=%d", ssrc)
			if _, err := gw.send("subscribe", subscribeMessage(m.Message["uid"], m.Message["ssrcId"], codecName, "audio")); err != nil {
				as.problem("audio subscribe send failed")
			}
		case "on_data_stream":
			r, ok := parseDataStream(m.Message)
			if !ok {
				return nil
			}
			if r.Action == ptzAction {
				waited := time.Since(drv.sentAt).Milliseconds()
				if !drv.ack() {
					return nil // the camera answers each move twice; the second finds nothing waiting
				}
				status("event=ptz_ack result=%d action=%s after_ms=%d", r.Result, r.Action, waited)
				if r.Result != 1 {
					status("event=ptz_problem reason=%s", q(fmt.Sprintf("the camera answered the move with result %d", r.Result)))
				}
			} else if k := fmt.Sprintf("%s/%d", r.Action, r.Result); !seenReplies[k] {
				seenReplies[k] = true // each distinct answer once (the resolution command is repeated every few seconds)
				status("event=data_stream action=%s result=%d bytes=%d", r.Action, r.Result, r.Bytes)
			}
		case "on_remove_audio_stream":
			status("event=audio_stream_removed")
		case "on_remove_video_stream":
			status("event=video_stream_removed")
		case "on_user_offline":
			if u := anyInt(m.Message["uid"]); u != uid {
				status("event=camera_offline uid=%d", u)
			}
		case "on_token_privilege_will_expire":
			status("event=token_expiring")
			startRenew()
		case "on_token_privilege_did_expire":
			return &sessionEnd{exitSession, "session_end", "agora: the RTC token expired"}
		case "on_p2p_lost":
			return &sessionEnd{exitSession, "session_end", fmt.Sprintf("agora: gateway lost the media connection (code %d)", m.Code)}
		}
		if m.Result != "" && m.ID == renewID && renewID != "" {
			renewID = ""
			if m.Result == "success" {
				status("event=token_renewed")
			} else {
				status("event=token_renew_rejected code=%d", m.Code)
			}
		} else if m.Result == "error" {
			status("event=gateway_error code=%d", m.Code)
		}
		return nil
	}

	for _, m := range stash {
		if e := handle(m); e != nil {
			return *e
		}
	}

	for {
		select {
		case s := <-sig:
			return sessionEnd{exitOK, "stopped", s.String()}
		case m, ok := <-gw.in:
			if !ok {
				return sessionEnd{exitSession, "session_end", "agora gateway connection closed"}
			}
			if e := handle(m); e != nil {
				return *e
			}
		case e := <-mediaErr:
			return e
		case <-out.Done():
			return sessionEnd{exitOutput, "output_closed", "the output stopped taking video"}
		case s := <-pcState:
			status("event=webrtc state=%s", s.String())
			if s == webrtc.PeerConnectionStateFailed {
				return sessionEnd{exitSession, "session_end", "webrtc connection failed"}
			}
		case <-pliNow:
			requestPLI()
		case <-ping.C:
			if _, err := gw.send("ping", nil); err != nil {
				return sessionEnd{exitSession, "session_end", "agora gateway ping failed"}
			}
		case <-control.C:
			res := ""
			if cameraOnline {
				res = c.resolution
			}
			if err := gw.sendCommands(cameraCommands(c.userID, res)); err != nil {
				return sessionEnd{exitSession, "session_end", "camera command send failed"}
			}
			if videoStarted {
				control.Reset(12 * time.Second)
			}
		case <-renewT.C:
			startRenew()
		case r := <-renewDone:
			renewing = false
			if r.err != nil {
				var we *wyzeError
				if errors.As(r.err, &we) && we.authRejected() {
					return sessionEnd{exitAuth, "session_end", "renew-token: Wyze refused the access token (" + we.Code + ")"}
				}
				status("event=token_renew_failed reason=%s", q(r.err.Error()))
				renewT.Reset(time.Minute)
				continue
			}
			secrets.add(r.token)
			id, err := gw.send("renew_token", object{"token": r.token})
			if err != nil {
				return sessionEnd{exitSession, "session_end", "renew_token send failed"}
			}
			renewID = id
			status("event=token_renew_sent")
			renewT.Reset(renewAfter)
		case <-firstVideo:
			firstVideo = nil
			videoStarted = true
			status("event=first_video codec=%s after_ms=%d", c.codec, time.Since(started).Milliseconds())
		case <-statsT.C:
			status("event=stats frames=%d keyframes=%d audio_frames=%d bytes=%d plis=%d rcvbuf=%d", cnt.frames.Load(), cnt.keyframes.Load(), cnt.audioFrames.Load(),
				cnt.bytes.Load(), cnt.plis.Load(), cnt.rcvbufGot.Load())
		case <-ptz.notify:
			sendMove()
		case <-ptzTick.C:
			if mv, ok := drv.expired(time.Now()); ok {
				status("event=ptz_problem reason=%s", q(fmt.Sprintf("no answer to the %s move within %s", mv.Direction, ptzAckTimeout)))
			}
			sendMove()
		case <-watchdog.C:
			if !videoStarted {
				if answered && time.Since(lastPLI) > 2*time.Second {
					requestPLI()
				}
				if time.Since(started) > c.startTimeout {
					if !cameraOnline {
						return sessionEnd{exitCameraGone, "session_end", "the camera did not join the channel within " + c.startTimeout.String() + " (offline?)"}
					}
					return sessionEnd{exitStall, "stall", "no video within " + c.startTimeout.String()}
				}
				continue
			}
			if last := time.Unix(0, cnt.lastWrite.Load()); time.Since(last) > c.stallTimeout {
				return sessionEnd{exitStall, "stall", "no video for " + c.stallTimeout.String()}
			}
		}
	}
}

type renewResult struct {
	token string
	err   error
}

// waitJoin reads until the reply to join_v3: its ortc on success. Notifications that arrive first are returned for later.
func waitJoin(ctx context.Context, g *gateway, joinID string, timeout time.Duration) (object, []*gwMessage, string) {
	t := time.NewTimer(timeout)
	defer t.Stop()
	var pending []*gwMessage
	for {
		select {
		case <-ctx.Done():
			return nil, nil, "cancelled"
		case <-t.C:
			return nil, nil, "no answer to join"
		case m, ok := <-g.in:
			if !ok {
				return nil, nil, "connection closed"
			}
			if m.ID == joinID || (m.Result != "" && m.Type == "") {
				if m.Result == "success" {
					if o := anyMap(m.Message["ortc"]); len(o) > 0 {
						return o, pending, ""
					}
					return nil, nil, "join reply without ortc"
				}
				if m.Result == "error" {
					return nil, nil, fmt.Sprintf("join refused (code %d)", m.Code)
				}
			}
			if m.Type != "" {
				pending = append(pending, m)
			}
		}
	}
}

// ---- media pipeline ----------------------------------------------------------------------------------------------------------

const reorderMaxDelay = time.Second

// receiveTrack reads RTP, puts it back in order, and assembles access units.
func receiveTrack(ctx context.Context, t *webrtc.TrackRemote, vc videoCodec, frames chan<- *accessUnit, pli chan<- struct{}, clk *avClock) {
	rb := newReorderBuffer(4096, reorderMaxDelay)
	dp := newDepacketizer(vc)
	var out []reorderOut
	askPLI := func() {
		select {
		case pli <- struct{}{}:
		default:
		}
	}
	emit := func() {
		for _, o := range out {
			if o.Pkt == nil {
				dp.lost()
				askPLI()
				continue
			}
			au, _ := dp.push(o.Pkt.Payload, o.Pkt.Timestamp, o.Pkt.Marker)
			if au != nil {
				select {
				case frames <- au:
				case <-ctx.Done():
					return
				}
			}
		}
		out = out[:0]
	}
	lastStats := time.Now()
	for ctx.Err() == nil {
		_ = t.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
		p, _, err := t.ReadRTP()
		now := time.Now()
		if err != nil {
			if isTimeout(err) {
				out = rb.tick(now, out)
				emit()
				continue
			}
			return
		}
		clk.videoPacket(p.SSRC, p.Timestamp, now)
		out = rb.push(p, now, out)
		emit()
		if now.Sub(lastStats) > 60*time.Second {
			lastStats = now
			status("event=rtp_stats lost=%d late=%d duplicate=%d reordered=%d dropped_pictures=%d", rb.Lost, rb.Late, rb.Duplicate,
				rb.Reordered, dp.Dropped)
		}
	}
}

func isTimeout(err error) bool {
	var ne interface{ Timeout() bool }
	return errors.As(err, &ne) && ne.Timeout()
}
