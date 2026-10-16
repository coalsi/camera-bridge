// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

// Agora's gateway does not take SDP. join_v3 carries our side as an ORTC-style object (ICE parameters, DTLS fingerprints, RTP
// capabilities per direction), and the join reply carries the gateway's side the same way, with its ICE candidates. This file
// turns our local SDP offer into that object and the gateway's reply into the SDP answer pion needs. The shapes follow the
// petkit integration (agora_sdp.py, agora_websocket.py; MIT) and the Web SDK; the code is ours.

import (
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

type sdpCodec struct {
	PT        int
	Name      string
	Clock     int
	Params    string // encoding parameters (audio channels)
	Feedbacks [][2]string
	Fmtp      [][2]string // ordered key=value pairs
}

type sdpExt struct {
	ID  int
	URI string
}

type sdpMedia struct {
	Kind      string // audio | video
	Mid       string
	Direction string
	Codecs    []*sdpCodec
	Exts      []sdpExt
}

type sdpOffer struct {
	Ufrag, Pwd  string
	FPHash, FP  string
	Bundle      string
	Medias      []*sdpMedia
	ExtmapMixed bool
}

// parseOffer reads what we need from pion's offer.
func parseOffer(sdp string) (*sdpOffer, error) {
	o := &sdpOffer{}
	var cur *sdpMedia
	byPT := map[int]*sdpCodec{}
	for _, line := range strings.Split(strings.ReplaceAll(sdp, "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "m=") {
			f := strings.Fields(line[2:])
			if len(f) < 4 {
				return nil, errors.New("sdp: bad m= line")
			}
			cur = &sdpMedia{Kind: f[0], Direction: "sendrecv"}
			o.Medias = append(o.Medias, cur)
			byPT = map[int]*sdpCodec{}
			continue
		}
		if !strings.HasPrefix(line, "a=") {
			continue
		}
		key, val, _ := strings.Cut(line[2:], ":")
		switch key {
		case "ice-ufrag":
			if o.Ufrag == "" {
				o.Ufrag = val
			}
			continue
		case "ice-pwd":
			if o.Pwd == "" {
				o.Pwd = val
			}
			continue
		case "fingerprint":
			if f := strings.Fields(val); len(f) == 2 && o.FP == "" {
				o.FPHash, o.FP = f[0], f[1]
			}
			continue
		case "group":
			if strings.HasPrefix(val, "BUNDLE ") {
				o.Bundle = strings.TrimPrefix(val, "BUNDLE ")
			}
			continue
		case "extmap-allow-mixed":
			o.ExtmapMixed = true
			continue
		}
		if cur == nil {
			continue
		}
		switch key {
		case "mid":
			cur.Mid = val
		case "sendrecv", "sendonly", "recvonly", "inactive":
			cur.Direction = key
		case "rtpmap":
			f := strings.Fields(val)
			if len(f) != 2 {
				return nil, errors.New("sdp: bad rtpmap")
			}
			pt, err := strconv.Atoi(f[0])
			if err != nil {
				return nil, errors.New("sdp: bad payload type")
			}
			enc := strings.Split(f[1], "/")
			c := &sdpCodec{PT: pt, Name: enc[0], Clock: 90000}
			if len(enc) > 1 {
				c.Clock, _ = strconv.Atoi(enc[1])
			}
			if len(enc) > 2 {
				c.Params = enc[2]
			}
			cur.Codecs = append(cur.Codecs, c)
			byPT[pt] = c
		case "fmtp":
			ptS, params, ok := strings.Cut(val, " ")
			if !ok {
				continue
			}
			pt, _ := strconv.Atoi(ptS)
			if c := byPT[pt]; c != nil {
				for _, kv := range strings.Split(params, ";") {
					k, v, ok := strings.Cut(strings.TrimSpace(kv), "=")
					if ok {
						c.Fmtp = append(c.Fmtp, [2]string{strings.TrimSpace(k), strings.TrimSpace(v)})
					}
				}
			}
		case "rtcp-fb":
			f := strings.Fields(val)
			if len(f) < 2 {
				continue
			}
			pt, _ := strconv.Atoi(f[0])
			if c := byPT[pt]; c != nil {
				p := ""
				if len(f) > 2 {
					p = f[2]
				}
				c.Feedbacks = append(c.Feedbacks, [2]string{f[1], p})
			}
		case "extmap":
			f := strings.Fields(val)
			if len(f) < 2 {
				continue
			}
			idS, _, _ := strings.Cut(f[0], "/")
			if id, err := strconv.Atoi(idS); err == nil {
				cur.Exts = append(cur.Exts, sdpExt{ID: id, URI: f[1]})
			}
		}
	}
	if len(o.Medias) == 0 || o.Ufrag == "" || o.Pwd == "" || o.FP == "" {
		return nil, errors.New("sdp: offer lacks media, ICE credentials or fingerprint")
	}
	for i, m := range o.Medias {
		if m.Mid == "" {
			m.Mid = strconv.Itoa(i)
		}
	}
	if o.Bundle == "" {
		mids := []string{}
		for _, m := range o.Medias {
			mids = append(mids, m.Mid)
		}
		o.Bundle = strings.Join(mids, " ")
	}
	return o, nil
}

func (c *sdpCodec) ortc() object {
	fbs := []any{}
	for _, f := range c.Feedbacks {
		fbs = append(fbs, object{"type": f[0], "parameter": f[1]})
	}
	params := object{}
	for _, kv := range c.Fmtp {
		params[kv[0]] = kv[1]
	}
	var enc any
	if c.Params != "" {
		enc = c.Params
	}
	return object{
		"payloadType":   c.PT,
		"rtpMap":        object{"encodingName": c.Name, "clockRate": c.Clock, "encodingParameters": enc},
		"rtcpFeedbacks": fbs,
		"fmtp":          object{"parameters": params},
	}
}

// ortc builds join_v3's "ortc" from our offer: recvonly sections fill only the recv capabilities.
func (o *sdpOffer) ortc() object {
	caps := func() object {
		return object{"audioCodecs": []any{}, "videoCodecs": []any{}, "audioExtensions": []any{}, "videoExtensions": []any{}}
	}
	send, recv := caps(), caps()
	for _, m := range o.Medias {
		if m.Kind != "audio" && m.Kind != "video" {
			continue
		}
		targets := []object{send, recv}
		switch m.Direction {
		case "sendonly":
			targets = []object{send}
		case "recvonly":
			targets = []object{recv}
		}
		for _, t := range targets {
			for _, c := range m.Codecs {
				t[m.Kind+"Codecs"] = append(t[m.Kind+"Codecs"].([]any), c.ortc())
			}
			for _, e := range m.Exts {
				t[m.Kind+"Extensions"] = append(t[m.Kind+"Extensions"].([]any), object{"entry": e.ID, "extensionName": e.URI})
			}
		}
	}
	return object{
		"iceParameters":   object{"iceUfrag": o.Ufrag, "icePwd": o.Pwd},
		"dtlsParameters":  object{"fingerprints": []any{object{"hashFunction": o.FPHash, "fingerprint": o.FP}}, "role": "client"},
		"rtpCapabilities": object{"send": send, "recv": recv},
		"version":         "2",
	}
}

// remoteVideo is the camera's announced stream (on_add_video_stream).
type remoteVideo struct {
	UID     any
	SSRC    int64
	RTXSSRC int64
	CName   string
}

// buildAnswer writes the SDP answer for pion from the gateway's ortc. fallbackFP is the access point's fingerprint for this edge
// ("sha-256 AB:..."), used when the ortc carries none. Only UDP candidates are used.
func buildAnswer(o *sdpOffer, gw object, video remoteVideo, audioSSRC int64, fallbackFP string) (string, error) {
	ice := anyMap(gw["iceParameters"])
	ufrag, pwd := anyString(ice["iceUfrag"]), anyString(ice["icePwd"])
	fp := fallbackFP
	if fps := anySlice(anyMap(gw["dtlsParameters"])["fingerprints"]); len(fps) > 0 {
		f := anyMap(fps[0])
		alg := anyString(f["hashFunction"])
		if alg == "" {
			alg = anyString(f["algorithm"])
		}
		if alg == "" {
			alg = "sha-256"
		}
		if v := anyString(f["fingerprint"]); v != "" {
			fp = alg + " " + v
		}
	}
	if ufrag == "" || pwd == "" || fp == "" {
		return "", errors.New("gateway ortc lacks ICE credentials or fingerprint")
	}
	var cands []string
	for i, v := range anySlice(ice["candidates"]) {
		c := anyMap(v)
		proto := strings.ToLower(anyString(c["protocol"]))
		if proto == "" {
			proto = "udp"
		}
		if proto != "udp" {
			continue
		}
		ip := anyString(c["ip"])
		if ip == "" {
			ip = anyString(c["address"])
		}
		port := anyInt(c["port"])
		if ip == "" || port <= 0 || port > 65535 {
			continue
		}
		typ := anyString(c["type"])
		if typ == "" {
			typ = "host"
		}
		foundation := anyString(c["foundation"])
		if foundation == "" {
			foundation = "gw" + strconv.Itoa(i)
		}
		prio := anyInt(c["priority"])
		if prio <= 0 {
			prio = 2103266323
		}
		cands = append(cands, fmt.Sprintf("a=candidate:%s 1 udp %d %s %d typ %s", foundation, prio, ip, port, typ))
	}
	if len(cands) == 0 {
		return "", errors.New("gateway ortc has no UDP candidate")
	}
	// The gateway's capabilities may be split by direction; take the first block that lists video codecs.
	all := anyMap(gw["rtpCapabilities"])
	caps := all
	for _, k := range []string{"sendrecv", "recv", "send"} {
		if c := anyMap(all[k]); len(anySlice(c["videoCodecs"])) > 0 {
			caps = c
			break
		}
	}

	lines := []string{"v=0", "o=- 0 0 IN IP4 127.0.0.1", "s=AgoraGateway", "t=0 0", "a=group:BUNDLE " + o.Bundle, "a=ice-lite"}
	if o.ExtmapMixed {
		lines = append(lines, "a=extmap-allow-mixed")
	}
	lines = append(lines, "a=msid-semantic: WMS")

	for _, m := range o.Medias {
		if m.Kind != "audio" && m.Kind != "video" {
			return "", fmt.Errorf("unexpected media %q in offer", m.Kind)
		}
		offered := map[int]bool{}
		for _, c := range m.Codecs {
			offered[c.PT] = true
		}
		var codecs []object
		for _, v := range anySlice(caps[m.Kind+"Codecs"]) {
			c := anyMap(v)
			if offered[int(anyInt(c["payloadType"]))] {
				codecs = append(codecs, c)
			}
		}
		// The gateway sends what it accepted. Audio has no SSRC lines: it may be announced after this answer, and pion
		// then takes the undeclared SSRC by its payload type (or MID).
		direction := "inactive"
		if len(codecs) > 0 {
			direction = "sendonly"
		}
		if m.Kind == "video" && len(codecs) == 0 {
			return "", errors.New("the gateway accepted none of the offered video codecs")
		}
		pts := []string{}
		for _, c := range codecs {
			pts = append(pts, strconv.FormatInt(anyInt(c["payloadType"]), 10))
		}
		if len(pts) == 0 { // inactive audio: echo the offer's first codec so the section stays well formed
			if len(m.Codecs) == 0 {
				return "", errors.New("offer media without codecs")
			}
			codecs = []object{m.Codecs[0].ortc()}
			pts = []string{strconv.Itoa(m.Codecs[0].PT)}
		}
		lines = append(lines,
			"m="+m.Kind+" 9 UDP/TLS/RTP/SAVPF "+strings.Join(pts, " "),
			"c=IN IP4 127.0.0.1",
			"a=rtcp:9 IN IP4 0.0.0.0",
			"a=ice-ufrag:"+ufrag,
			"a=ice-pwd:"+pwd,
			"a=ice-options:trickle",
			"a=fingerprint:"+fp,
			"a=setup:active",
			"a=mid:"+m.Mid,
		)
		lines = append(lines, cands...)
		offeredExt := map[string]int{}
		for _, e := range m.Exts {
			offeredExt[e.URI] = e.ID
		}
		for _, v := range anySlice(caps[m.Kind+"Extensions"]) {
			name := anyString(anyMap(v)["extensionName"])
			// No MID/RID: the gateway learns no mids from ORTC, so it cannot stamp ours; with them negotiated pion would
			// wait for MIDs instead of routing an undeclared audio SSRC by its payload type.
			if strings.Contains(name, "sdes:mid") || strings.Contains(name, "rtp-stream-id") {
				continue
			}
			if id, ok := offeredExt[name]; ok {
				lines = append(lines, fmt.Sprintf("a=extmap:%d %s", id, name))
			}
		}
		lines = append(lines, "a="+direction, "a=rtcp-mux", "a=rtcp-rsize")
		for _, c := range codecs {
			pt := anyInt(c["payloadType"])
			rm := anyMap(c["rtpMap"])
			clock := anyInt(rm["clockRate"])
			if clock == 0 {
				clock = 90000
			}
			l := fmt.Sprintf("a=rtpmap:%d %s/%d", pt, anyString(rm["encodingName"]), clock)
			if e := anyString(rm["encodingParameters"]); e != "" {
				l += "/" + e
			}
			lines = append(lines, l)
			for _, fv := range anySlice(c["rtcpFeedbacks"]) {
				f := anyMap(fv)
				l := fmt.Sprintf("a=rtcp-fb:%d %s", pt, anyString(f["type"]))
				if p := anyString(f["parameter"]); p != "" {
					l += " " + p
				}
				lines = append(lines, l)
			}
			params := anyMap(anyMap(c["fmtp"])["parameters"])
			keys := make([]string, 0, len(params))
			for k := range params {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			kv := []string{}
			for _, k := range keys {
				kv = append(kv, k+"="+anyString(params[k]))
			}
			if len(kv) > 0 {
				lines = append(lines, fmt.Sprintf("a=fmtp:%d %s", pt, strings.Join(kv, ";")))
			}
		}
		hasRTX := false
		for _, c := range codecs {
			if strings.EqualFold(anyString(anyMap(c["rtpMap"])["encodingName"]), "rtx") {
				hasRTX = true
			}
		}
		if m.Kind == "audio" && audioSSRC != 0 && direction == "sendonly" {
			lines = append(lines, "a=msid:lake lake-audio", fmt.Sprintf("a=ssrc:%d cname:lake", audioSSRC),
				fmt.Sprintf("a=ssrc:%d msid:lake lake-audio", audioSSRC))
		}
		if m.Kind == "video" && video.SSRC != 0 {
			if !hasRTX {
				video.RTXSSRC = 0
			}
			cname := video.CName
			if cname == "" {
				cname = "lake"
			}
			lines = append(lines, "a=msid:lake lake-video")
			if video.RTXSSRC != 0 {
				lines = append(lines, fmt.Sprintf("a=ssrc-group:FID %d %d", video.SSRC, video.RTXSSRC))
			}
			lines = append(lines,
				fmt.Sprintf("a=ssrc:%d cname:%s", video.SSRC, cname),
				fmt.Sprintf("a=ssrc:%d msid:lake lake-video", video.SSRC))
			if video.RTXSSRC != 0 {
				lines = append(lines,
					fmt.Sprintf("a=ssrc:%d cname:%s", video.RTXSSRC, cname),
					fmt.Sprintf("a=ssrc:%d msid:lake lake-video", video.RTXSSRC))
			}
		}
	}
	return strings.Join(lines, "\r\n") + "\r\n", nil
}
