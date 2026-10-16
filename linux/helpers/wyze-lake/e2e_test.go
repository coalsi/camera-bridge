// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

// The whole session against fakes on this machine: a fake Wyze (the three signed calls, with XXTEA-wrapped key and salt), a
// fake Agora access point (TLS), and a fake gateway (WebSocket signalling that speaks join_v3 / data_stream / subscribe /
// renew_token, plus a real pion peer that sends H.265 over ICE, DTLS and SRTP). It proves our signalling, ORTC/SDP translation,
// media path, token renewal and redaction fit together; it cannot prove the real gateway accepts them.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/pion/interceptor"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v4"
)

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}
func (s *syncBuffer) String() string { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

type captureSink struct {
	mu   sync.Mutex
	aus  [][]byte
	done chan struct{}
}

func (c *captureSink) Write(p []byte) (int, error) {
	c.mu.Lock()
	c.aus = append(c.aus, append([]byte(nil), p...))
	c.mu.Unlock()
	return len(p), nil
}
func (c *captureSink) Close() error          { return nil }
func (c *captureSink) Done() <-chan struct{} { return c.done }
func (c *captureSink) count() int            { c.mu.Lock(); defer c.mu.Unlock(); return len(c.aus) }

const (
	e2eToken   = "e2e-wyze-access-token-0123456789"
	e2eChannel = "e2e-channel-name-xyz"
	e2eKey     = "e2e-Media-Key!77"
	e2eRTC     = "e2e-rtc-token-ABCDEFGHIJ"
	e2eRTC2    = "e2e-rtc-token-RENEWED-2"
	e2eAppID   = "e2eagoraappid0001"
	e2eUser    = "wyze-user-42"
	e2eMAC     = "D03F27A1B2C3"
)

func synthHEVC(n int) [][][]byte {
	var aus [][][]byte
	for i := 0; i < n; i++ {
		if i%30 == 0 {
			aus = append(aus, [][]byte{hevc(32, 0x0c, 1), hevc(33, 0x01, 2), hevc(34, 0xc1, 3),
				hevc(19, append([]byte{0x80}, rep(0x55, 9000)...)...)})
		} else {
			aus = append(aus, [][]byte{hevc(1, append([]byte{0x80}, rep(byte(0x56+i%3), 2500+i%7*300)...)...)})
		}
	}
	return aus
}

func TestEndToEndAgainstFakeWyzeAndAgora(t *testing.T) {
	if testing.Short() {
		t.Skip("network loopback test")
	}
	t.Run("streams_and_renews_with_pcmu_audio", func(t *testing.T) { e2eRun(t, "ok") })
	t.Run("opus_audio", func(t *testing.T) { e2eRun(t, "opus") })
	t.Run("no_audio", func(t *testing.T) { e2eRun(t, "noaudio") })
	t.Run("camera_never_joins_exits_6", func(t *testing.T) { e2eRun(t, "offline") })
	t.Run("video_stops_exits_4", func(t *testing.T) { e2eRun(t, "stall") })
}

// opusPackets makes 3 s of 20 ms Opus packets with ffmpeg (libopus), or skips.
func opusPackets(t *testing.T) [][]byte {
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	f := filepath.Join(t.TempDir(), "a.ogg")
	if out, err := exec.Command(ff, "-v", "error", "-f", "lavfi", "-i", "sine=f=440:r=48000", "-t", "3", "-c:a", "libopus",
		"-b:a", "32k", "-frame_duration", "20", "-ac", "1", f).CombinedOutput(); err != nil {
		t.Skip("no libopus: ", string(out))
	}
	pk, _, err := loadSelfTestAudio(f)
	if err != nil {
		t.Fatal(err)
	}
	return pk
}

func e2eRun(t *testing.T, mode string) {
	audioCodec := map[string]string{"ok": "pcmu", "stall": "pcmu", "offline": "pcmu", "opus": "opus"}[mode]
	var opusPk [][]byte
	if audioCodec == "opus" {
		opusPk = opusPackets(t)
	}
	logs := &syncBuffer{}
	log.SetOutput(io.MultiWriter(logs, os.Stderr))
	defer log.SetOutput(os.Stderr)
	testLoopback = true
	defer func() { testLoopback = false }()

	salt := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	wrap := func(s string) string {
		return base64.StdEncoding.EncodeToString(xxteaEncrypt([]byte(s), []byte(e2eToken)))
	}

	// ---- fake Wyze
	var renewCalls atomic.Int32
	var gotUID atomic.Int64
	wyze := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Header.Get("signature2") != signature2(e2eToken, body) || r.Header.Get("access_token") != e2eToken {
			w.Write([]byte(`{"code":"2001"}`))
			return
		}
		var m map[string]any
		json.Unmarshal(body, &m)
		switch r.URL.Path {
		case "/app/v4/camera/get-streams":
			fmt.Fprintf(w, `{"code":"1","data":[{"device_id":%q,"provider":"lake","params":{"channel":%q,"protocol":3,"encryption_mode":7,"encryption_key":%q,"encryption_salt":%q}}]}`,
				e2eMAC, e2eChannel, wrap(e2eKey), wrap(salt))
		case "/app/v4/wcsa/create-connection":
			gotUID.Store(int64(m["uid"].(float64)))
			fmt.Fprintf(w, `{"code":"1","data":{"app_id":%q,"uid":%d,"device_uid":1,"rtc_token":%q,"p2p_mode":true}}`, e2eAppID, int64(m["uid"].(float64)), e2eRTC)
		case "/app/v4/wcsa/renew-token":
			renewCalls.Add(1)
			fmt.Fprintf(w, `{"code":"1","data":{"rtc_token":%q}}`, e2eRTC2)
		default:
			w.WriteHeader(404)
		}
	}))
	defer wyze.Close()

	// ---- fake gateway
	sent := &atomic.Int32{}
	var renewedWith atomic.Value
	var movesSeen atomic.Int32
	var joinChecks atomic.Value
	upgrader := websocket.Upgrader{}
	gwSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		var wmu sync.Mutex
		write := func(v any) { wmu.Lock(); c.WriteJSON(v); wmu.Unlock() }
		var join map[string]any
		if c.ReadJSON(&join) != nil || join["_type"] != "join_v3" {
			t.Error("first frame is not join_v3")
			return
		}
		jm := join["_message"].(map[string]any)
		problems := []string{}
		for k, v := range map[string]any{"channel_name": e2eChannel, "channel_key": e2eRTC, "app_id": e2eAppID, "codec": "h265",
			"mode": "rtc", "aes_mode": "aes-128-gcm2", "aes_salt": salt, "aes_encrypt": true} {
			if jm[k] != v {
				problems = append(problems, fmt.Sprintf("%s=%v", k, jm[k]))
			}
		}
		if jm["aes_secret"] == "" || jm["aes_secret"] == e2eKey {
			problems = append(problems, "aes_secret not wrapped")
		}
		joinChecks.Store(strings.Join(problems, ","))
		ortc := jm["ortc"].(map[string]any)
		ice := ortc["iceParameters"].(map[string]any)
		fp := ortc["dtlsParameters"].(map[string]any)["fingerprints"].([]any)[0].(map[string]any)

		// The gateway's media peer, negotiated from our ORTC as an SDP offer it answers.
		me := &webrtc.MediaEngine{}
		me.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH265, ClockRate: 90000,
			RTCPFeedback: videoFeedback()}, PayloadType: 100}, webrtc.RTPCodecTypeVideo)
		reg := &interceptor.Registry{}
		me.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMU, ClockRate: 8000}, PayloadType: 0}, webrtc.RTPCodecTypeAudio)
		me.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}, PayloadType: 101}, webrtc.RTPCodecTypeAudio)
		webrtc.ConfigureNack(me, reg)
		webrtc.ConfigureRTCPReports(reg) // sender reports, for A/V sync
		se := webrtc.SettingEngine{}
		se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
		se.SetIncludeLoopbackCandidate(true)
		se.SetICEMulticastDNSMode(0)
		api := webrtc.NewAPI(webrtc.WithMediaEngine(me), webrtc.WithInterceptorRegistry(reg), webrtc.WithSettingEngine(se))
		gpc, _ := api.NewPeerConnection(webrtc.Configuration{})
		defer gpc.Close()
		track, _ := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH265, ClockRate: 90000}, "v", "lake")
		sender, _ := gpc.AddTrack(track)
		var atrack *webrtc.TrackLocalStaticRTP
		var asender *webrtc.RTPSender
		audioLines := []string{}
		bundle := "0"
		if audioCodec != "" {
			acap := webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMU, ClockRate: 8000}
			line := "a=rtpmap:0 PCMU/8000"
			pt := "0"
			if audioCodec == "opus" {
				acap = webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}
				line, pt = "a=rtpmap:101 opus/48000/2", "101"
			}
			atrack, _ = webrtc.NewTrackLocalStaticRTP(acap, "a", "lake")
			asender, _ = gpc.AddTrack(atrack)
			go func() {
				for {
					if _, _, err := asender.ReadRTCP(); err != nil {
						return
					}
				}
			}()
			audioLines = []string{"m=audio 9 UDP/TLS/RTP/SAVPF " + pt, "c=IN IP4 0.0.0.0", "a=mid:1", "a=recvonly", "a=rtcp-mux", line}
			bundle = "0 1"
		}
		go func() {
			for {
				if _, _, err := sender.ReadRTCP(); err != nil {
					return
				}
			}
		}()
		sess := []string{"v=0", "o=- 1 1 IN IP4 0.0.0.0", "s=-", "t=0 0", "a=group:BUNDLE " + bundle,
			"a=ice-ufrag:" + ice["iceUfrag"].(string), "a=ice-pwd:" + ice["icePwd"].(string),
			"a=fingerprint:" + fp["hashFunction"].(string) + " " + fp["fingerprint"].(string), "a=setup:actpass",
			"m=video 9 UDP/TLS/RTP/SAVPF 100", "c=IN IP4 0.0.0.0", "a=mid:0", "a=recvonly", "a=rtcp-mux", "a=rtpmap:100 H265/90000",
			"a=rtcp-fb:100 nack", "a=rtcp-fb:100 nack pli"}
		offer := strings.Join(append(sess, audioLines...), "\r\n") + "\r\n"
		if err := gpc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
			t.Error("fake gateway offer:", err)
			return
		}
		ans, _ := gpc.CreateAnswer(nil)
		gather := webrtc.GatheringCompletePromise(gpc)
		gpc.SetLocalDescription(ans)
		<-gather
		local := gpc.LocalDescription().SDP
		g, _ := parseOffer(local)
		var cands []any
		for _, l := range strings.Split(local, "\r\n") {
			if f := strings.Fields(strings.TrimPrefix(l, "a=candidate:")); strings.HasPrefix(l, "a=candidate:") && len(f) >= 8 && f[2] == "udp" {
				prio, _ := strconv.Atoi(f[3])
				port, _ := strconv.Atoi(f[5])
				cands = append(cands, object{"foundation": f[0], "protocol": "udp", "priority": prio, "ip": f[4], "port": port, "type": f[7]})
			}
		}
		gwORTC := object{
			"iceParameters":  object{"iceUfrag": g.Ufrag, "icePwd": g.Pwd, "candidates": cands},
			"dtlsParameters": object{"fingerprints": []any{object{"hashFunction": g.FPHash, "fingerprint": g.FP}}},
			"rtpCapabilities": object{"send": object{"videoCodecs": []any{g.Medias[0].Codecs[0].ortc()}, "audioCodecs": []any{},
				"videoExtensions": []any{}, "audioExtensions": []any{}}},
		}
		if audioCodec != "" {
			anyMap(anyMap(gwORTC["rtpCapabilities"])["send"])["audioCodecs"] = []any{g.Medias[1].Codecs[0].ortc()}
		}
		write(object{"_id": join["_id"], "_result": "success", "_message": object{"ortc": gwORTC}})

		connected := make(chan struct{})
		var once sync.Once
		gpc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
			if s == webrtc.PeerConnectionStateConnected {
				once.Do(func() { close(connected) })
			}
		})
		ssrc := uint32(sender.GetParameters().Encodings[0].SSRC)
		online, streaming := false, false
		for {
			var m map[string]any
			if c.ReadJSON(&m) != nil {
				return
			}
			body, _ := m["_message"].(map[string]any)
			switch m["_type"] {
			case "data_stream":
				payload, _ := base64.StdEncoding.DecodeString(body["payload"].(string))
				var cmds []map[string]any
				json.Unmarshal(payload, &cmds)
				if len(cmds) > 0 && cmds[0]["action"] == "camera-position::move-position" {
					p := cmds[0]["params"].(map[string]any)
					movesSeen.Add(1)
					// the camera's ack, JSON-escaped inside JSON as the working client saw it
					ack := fmt.Sprintf(`{"type":"result","data":"[{\\"action\\":\\"camera-position::move-position\\",\\"result\\":1,\\"dir\\":\\"%v\\"}]"}`, p["direction"])
					// the real camera answers each move twice; the helper must log one ptz_ack
					write(object{"_type": "on_data_stream", "_message": object{"uid": 1, "payload": base64.StdEncoding.EncodeToString([]byte(ack))}})
					write(object{"_type": "on_data_stream", "_message": object{"uid": 1, "payload": base64.StdEncoding.EncodeToString([]byte(ack))}})
					continue
				}
				if len(cmds) > 0 && cmds[0]["action"] == "sight-safe::check-user" &&
					cmds[0]["params"].(map[string]any)["userId"] == e2eUser && !online && mode != "offline" {
					online = true
					write(object{"_type": "on_user_online", "_message": object{"uid": 1}})
					write(object{"_type": "on_add_video_stream", "_message": object{"uid": 1, "ssrcId": ssrc, "video": true, "cname": "cam"}})
					if atrack != nil {
						write(object{"_type": "on_add_audio_stream", "_message": object{"uid": 1, "ssrcId": uint32(asender.GetParameters().Encodings[0].SSRC), "audio": true}})
					}
				}
			case "subscribe":
				if body["stream_type"] == "audio" {
					if atrack == nil || uint32(body["ssrcId"].(float64)) != uint32(asender.GetParameters().Encodings[0].SSRC) {
						t.Errorf("audio subscribe %v", body)
						continue
					}
					go func() {
						<-connected
						seq, ts := uint16(100), uint32(0x10000000)
						step, pt := uint32(160), uint8(0)
						if audioCodec == "opus" {
							step, pt = 960, 101
						}
						start := time.Now()
						for k := 0; k < 150; k++ {
							time.Sleep(time.Until(start.Add(time.Duration(k) * 20 * time.Millisecond)))
							pl := bytes.Repeat([]byte{byte(0x80 + k%16)}, 160)
							if audioCodec == "opus" {
								pl = opusPk[k%len(opusPk)]
							}
							if atrack.WriteRTP(&rtp.Packet{Header: rtp.Header{Version: 2, PayloadType: pt, SequenceNumber: seq, Timestamp: ts}, Payload: pl}) != nil {
								return
							}
							seq++
							ts += step
						}
					}()
					continue
				}
				if body["codec"] != "h265" || body["stream_type"] != "video" || uint32(body["ssrcId"].(float64)) != ssrc {
					t.Errorf("subscribe %v", body)
				}
				if !streaming {
					streaming = true
					go func() {
						select {
						case <-connected:
						case <-time.After(15 * time.Second):
							t.Error("fake gateway: ICE/DTLS never connected")
							return
						}
						pz := &packetizer{codec: codecH265, mtu: 1150, pt: 100, ssrc: ssrc, seq: 65000}
						for i, au := range synthHEVC(map[bool]int{true: 40, false: 150}[mode == "stall"]) {
							pk := pz.packets(au, uint32(i*3000))
							if i%10 == 5 && len(pk) > 2 { // swap two packets now and then
								pk[0], pk[1] = pk[1], pk[0]
							}
							for _, p := range pk {
								if track.WriteRTP(p) != nil {
									return
								}
							}
							sent.Add(1)
							if i == 45 {
								write(object{"_type": "on_token_privilege_will_expire", "_message": object{}})
							}
							time.Sleep(33 * time.Millisecond)
						}
					}()
				}
			case "renew_token":
				renewedWith.Store(body["token"])
				write(object{"_id": m["_id"], "_result": "success", "_message": object{}})
			}
		}
	}))
	defer gwSrv.Close()
	gwPort := gwSrv.Listener.Addr().(*net.TCPAddr).Port

	// ---- fake access point (TLS, like the real one)
	ap := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseMultipartForm(1 << 20); err != nil || !strings.Contains(r.FormValue("request"), e2eChannel) {
			w.WriteHeader(400)
			return
		}
		fmt.Fprintf(w, `{"code":0,"enter_ts":1,"opid":2,"response_body":[{"buffer":{"code":0,"flag":4096,"uid":5,"cid":6,"cname":%q,"cert":"cert-ticket-123456","edges_services":[{"ip":"127.0.0.1","port":%d}]}}]}`, e2eChannel, gwPort)
	}))
	defer ap.Close()

	// ---- wire the seams
	oldW, oldAPC, oldAP, oldDial, oldSink := wyzeBase, apClient, apURL, dialURL, openSinkHook
	defer func() { wyzeBase, apClient, apURL, dialURL, openSinkHook = oldW, oldAPC, oldAP, oldDial, oldSink }()
	wyzeBase = wyze.URL + "/app"
	apClient = ap.Client()
	apURL = func(string) string { return ap.URL + "/api/v2/transpond/webrtc?v=2" }
	dialURL = func(u string) string {
		if u != fmt.Sprintf("wss://127-0-0-1.edge.agora.io:%d", gwPort) {
			t.Errorf("edge url %s", u)
		}
		return strings.Replace(gwSrv.URL, "http://", "ws://", 1)
	}
	capture := &captureSink{done: make(chan struct{})}
	var sinkAudio atomic.Value
	openSinkHook = func(vc videoCodec, af *audioFormat) (sink, error) {
		if vc != codecH265 {
			t.Errorf("sink opened for %s", vc)
		}
		if af != nil {
			sinkAudio.Store(af.Codec)
		}
		return capture, nil
	}

	cfg := &config{accessToken: e2eToken, userID: e2eUser, mac: e2eMAC, model: "HL_PAN4", output: "rtsp://127.0.0.1:1/x",
		resolution: "2k", quality: "hd", codec: codecH265, ffmpeg: "ffmpeg", ffmpegLevel: "warning",
		startTimeout: 30 * time.Second, stallTimeout: 10 * time.Second, rcvbuf: 4 << 20}
	if mode == "offline" {
		cfg.startTimeout = 3 * time.Second
	}
	if mode == "stall" {
		cfg.stallTimeout = 2 * time.Second
	}
	secrets.add(cfg.accessToken)
	sig := make(chan os.Signal, 1)
	ptzQ := newPTZQueue()
	result := make(chan sessionEnd, 1)
	go func() { result <- session(t.Context(), cfg, sig, ptzQ) }()

	if mode == "offline" || mode == "stall" {
		want := map[string]int{"offline": exitCameraGone, "stall": exitStall}[mode]
		select {
		case e := <-result:
			if e.code != want || (mode == "offline" && e.event != "session_end") {
				t.Fatalf("%s: ended %+v, want code %d", mode, e, want)
			}
			t.Logf("%s: %+v after %d pictures", mode, e, capture.count())
		case <-time.After(40 * time.Second):
			t.Fatalf("%s: session did not end", mode)
		}
		return
	}
	deadline := time.After(40 * time.Second)
	for capture.count() < map[bool]int{true: 100, false: 200}[audioCodec == ""] || renewedWith.Load() == nil {
		select {
		case e := <-result:
			t.Fatalf("session ended early: %+v\n%s", e, logs.String())
		case <-deadline:
			t.Fatalf("timed out: %d pictures, renew %v\n%s", capture.count(), renewedWith.Load(), logs.String())
		case <-time.After(100 * time.Millisecond):
		}
	}
	// pan/tilt through the control server
	addr, err := startControl(t.Context(), "127.0.0.1:0", "test-control-token-0123", ptzQ)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"left", "up"} {
		req, _ := http.NewRequest("POST", "http://"+addr.String()+"/move", strings.NewReader(`{"direction":"`+d+`","step":20}`))
		req.Header.Set("Authorization", "Bearer test-control-token-0123")
		resp, err := http.DefaultClient.Do(req)
		if err != nil || resp.StatusCode != 202 {
			t.Fatalf("move %s: %v %v", d, err, resp)
		}
		resp.Body.Close()
	}
	for i := 0; i < 50 && strings.Count(logs.String(), "event=ptz_ack result=1") < 2; i++ {
		time.Sleep(100 * time.Millisecond)
	}
	time.Sleep(300 * time.Millisecond)
	if movesSeen.Load() != 2 || strings.Count(logs.String(), "event=ptz_ack ") != 2 {
		t.Errorf("moves seen %d; log:\n%s", movesSeen.Load(), logs.String())
	}
	sig <- syscall.SIGTERM
	e := <-result
	if e.code != exitOK {
		t.Fatalf("end %+v", e)
	}
	if p := joinChecks.Load(); p != "" {
		t.Errorf("join_v3 fields: %v", p)
	}
	if renewedWith.Load() != e2eRTC2 || renewCalls.Load() != 1 {
		t.Errorf("renew: %v (%d calls)", renewedWith.Load(), renewCalls.Load())
	}
	if gotUID.Load() < 10000 || gotUID.Load() > 99999 {
		t.Errorf("uid %d", gotUID.Load())
	}
	capture.mu.Lock()
	all := bytes.Join(capture.aus, nil)
	capture.mu.Unlock()
	streams, types, _ := demuxTS(t, all)
	video, audio := streams[tsVideoPID], streams[tsAudioPID]
	if len(video) < 60 || !bytes.HasPrefix(video[0].payload, []byte{0, 0, 0, 1, 0x46, 1, 0x50, 0, 0, 0, 1, 32 << 1, 1}) {
		t.Errorf("%d pictures; the first does not start with AUD + VPS: %x", len(video), video[0].payload[:14])
	}
	switch audioCodec {
	case "":
		if len(audio) != 0 || sinkAudio.Load() != nil {
			t.Errorf("audio without an audio stream")
		}
	default:
		if sinkAudio.Load() != audioCodec || len(audio) < 50 {
			t.Fatalf("audio %v: %d frames, stream types %v", sinkAudio.Load(), len(audio), types)
		}
		// Audio and video are on one clock: each audio frame's time is close to the picture written just before it
		// (both were sent at the same moment by the fake gateway; the video is not delayed by reordering here).
		worst := int64(0)
		for _, a := range audio {
			var v *pes
			for i := range video {
				if video[i].off < a.off {
					v = &video[i]
				}
			}
			if v == nil {
				continue
			}
			d := a.pts - v.pts
			if d < 0 {
				d = -d
			}
			if d > worst {
				worst = d
			}
		}
		if worst > 27000 { // 300 ms
			t.Errorf("audio is %d ms away from the video", worst/90)
		}
		t.Logf("%s: %d audio frames, worst A/V distance %d ms", audioCodec, len(audio), worst/90)
		if !strings.Contains(logs.String(), "event=audio_track codec="+audioCodec) || !strings.Contains(logs.String(), "event=audio_sync method=") {
			t.Error("no audio_track / audio_sync status line")
		}
	}
	out := logs.String()
	for _, s := range []string{e2eToken, e2eChannel, e2eKey, e2eRTC, e2eRTC2, e2eAppID, salt, "cert-ticket-123456"} {
		if strings.Contains(out, s) {
			t.Errorf("a secret reached the log: %q", s[:6])
		}
	}
	for _, s := range []string{"event=provisioned", "event=joined", "event=camera_online", "event=video_stream", "event=track codec=hevc",
		"event=first_video", "event=token_renew_sent", "event=token_renewed"} {
		if !strings.Contains(out, s) {
			t.Errorf("log lacks %s", s)
		}
	}
	t.Logf("pictures written: %d of %d sent", capture.count(), sent.Load())
}
