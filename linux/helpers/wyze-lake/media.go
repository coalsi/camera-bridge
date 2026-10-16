// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"fmt"
	"net"
	"strings"
	"sync/atomic"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/logging"
	"github.com/pion/transport/v4"
	"github.com/pion/transport/v4/stdnet"
	"github.com/pion/webrtc/v4"
)

// The receive side is a stock pion PeerConnection offering what go2rtc 1.9.14 offers (the configuration docker-wyze-bridge
// PR #161 streamed a Pan v4 with for over an hour): recvonly video, H.265 at payload type 100 (or H.264), feedback goog-remb,
// ccm fir, nack, nack pli, pion's default interceptors (NACK generator, RTCP reports, TWCC feedback), and a recvonly audio
// section the gateway answers inactive. Two changes from the stock settings, both from the PR's measurements:
//   - the SRTP replay window is 4096 packets (default 64), because the gateway resends NACKed packets with their original
//     sequence numbers, often far behind the newest one, and a small window throws those repairs away as replays;
//   - every UDP socket asks for a large kernel receive buffer (4K HEVC bursts overran the 208 KiB default).

// testLoopback lets the end-to-end test run both peers on this machine.
var testLoopback = false

const (
	srtpReplayWindow = 4096
	payloadH265      = 100
	payloadH264      = 97
)

func videoFeedback() []webrtc.RTCPFeedback {
	return []webrtc.RTCPFeedback{{Type: "goog-remb"}, {Type: "ccm", Parameter: "fir"}, {Type: "nack"}, {Type: "nack", Parameter: "pli"}}
}

func newMediaEngine(codec videoCodec) (*webrtc.MediaEngine, *interceptor.Registry, error) {
	m := &webrtc.MediaEngine{}
	for _, c := range []webrtc.RTPCodecParameters{
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;useinbandfec=1"}, PayloadType: 101},
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMU, ClockRate: 8000}, PayloadType: 0},
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMA, ClockRate: 8000}, PayloadType: 8},
	} {
		if err := m.RegisterCodec(c, webrtc.RTPCodecTypeAudio); err != nil {
			return nil, nil, err
		}
	}
	var v webrtc.RTPCodecParameters
	if codec == codecH264 {
		v = webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264, ClockRate: 90000,
			SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f", RTCPFeedback: videoFeedback()}, PayloadType: payloadH264}
	} else {
		v = webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH265, ClockRate: 90000,
			RTCPFeedback: videoFeedback()}, PayloadType: payloadH265}
	}
	if err := m.RegisterCodec(v, webrtc.RTPCodecTypeVideo); err != nil {
		return nil, nil, err
	}
	reg := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(m, reg); err != nil {
		return nil, nil, err
	}
	return m, reg, nil
}

// newPeerConnection makes the receiving PeerConnection with a recvonly video and audio transceiver.
func newPeerConnection(codec videoCodec, rcvbuf int, rcvbufGot *atomic.Int64) (*webrtc.PeerConnection, error) {
	m, reg, err := newMediaEngine(codec)
	if err != nil {
		return nil, err
	}
	se := webrtc.SettingEngine{}
	se.SetSRTPReplayProtectionWindow(srtpReplayWindow)
	se.SetSRTCPReplayProtectionWindow(srtpReplayWindow)
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	se.SetICEMulticastDNSMode(0) // ice.MulticastDNSModeDisabled
	se.SetICETimeouts(10*time.Second, 30*time.Second, 2*time.Second)
	se.SetReceiveMTU(1600)
	// The camera's audio may be announced after our answer: pion then takes its undeclared SSRC by payload type.
	se.SetHandleUndeclaredSSRCWithoutAnswer(true)
	se.SetIncludeLoopbackCandidate(testLoopback)
	se.SetInterfaceFilter(func(name string) bool {
		if testLoopback {
			return true
		}
		// Container and VPN bridges only slow gathering down; the gateway is on the internet.
		for _, p := range []string{"docker", "veth", "br-", "virbr", "lo"} {
			if strings.HasPrefix(name, p) {
				return false
			}
		}
		return true
	})
	if n, err := newBufferedNet(rcvbuf, rcvbufGot); err == nil {
		se.SetNet(n)
	} else {
		status("event=warning reason=%s", q("udp receive buffers left at the default: "+err.Error()))
	}
	se.LoggerFactory = pionLogs{}
	api := webrtc.NewAPI(webrtc.WithMediaEngine(m), webrtc.WithInterceptorRegistry(reg), webrtc.WithSettingEngine(se))
	pc, err := api.NewPeerConnection(webrtc.Configuration{BundlePolicy: webrtc.BundlePolicyMaxBundle, RTCPMuxPolicy: webrtc.RTCPMuxPolicyRequire})
	if err != nil {
		return nil, err
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		pc.Close()
		return nil, err
	}
	if _, err := pc.AddTransceiverFromKind(webrtc.RTPCodecTypeAudio, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		pc.Close()
		return nil, err
	}
	return pc, nil
}

// bufferedNet is pion's standard network with a bigger receive buffer on every UDP socket ICE opens.
type bufferedNet struct {
	*stdnet.Net
	size int
	got  *atomic.Int64
}

func newBufferedNet(size int, got *atomic.Int64) (*bufferedNet, error) {
	n, err := stdnet.NewNet()
	if err != nil {
		return nil, err
	}
	return &bufferedNet{Net: n, size: size, got: got}, nil
}

func (b *bufferedNet) ListenUDP(network string, laddr *net.UDPAddr) (transport.UDPConn, error) {
	c, err := b.Net.ListenUDP(network, laddr)
	if err == nil {
		if uc, ok := c.(*net.UDPConn); ok {
			b.got.Store(int64(setReceiveBuffer(uc, b.size)))
		}
	}
	return c, err
}

func (b *bufferedNet) ListenPacket(network, address string) (net.PacketConn, error) {
	c, err := b.Net.ListenPacket(network, address)
	if err == nil {
		if uc, ok := c.(*net.UDPConn); ok {
			b.got.Store(int64(setReceiveBuffer(uc, b.size)))
		}
	}
	return c, err
}

// pionLogs sends pion's warnings and errors through the redactor, as non-status lines (the daemon ignores them).
type pionLogs struct{}

func (pionLogs) NewLogger(scope string) logging.LeveledLogger { return pionLogger{scope: scope} }

type pionLogger struct{ scope string }

func (l pionLogger) out(level, msg string) {
	logLine(fmt.Sprintf("pion %s %s: %s", level, l.scope, msg))
}
func (pionLogger) Trace(string)                {}
func (pionLogger) Tracef(string, ...any)       {}
func (pionLogger) Debug(string)                {}
func (pionLogger) Debugf(string, ...any)       {}
func (pionLogger) Info(string)                 {}
func (pionLogger) Infof(string, ...any)        {}
func (l pionLogger) Warn(m string)             { l.out("warn", m) }
func (l pionLogger) Warnf(f string, a ...any)  { l.out("warn", fmt.Sprintf(f, a...)) }
func (l pionLogger) Error(m string)            { l.out("error", m) }
func (l pionLogger) Errorf(f string, a ...any) { l.out("error", fmt.Sprintf(f, a...)) }
