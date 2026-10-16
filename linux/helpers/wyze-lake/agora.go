// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

// The Agora side: the access point ("choose server") request, and the gateway WebSocket that carries join_v3, subscribe,
// data_stream (the camera's wake-up and resolution commands), ping and renew_token.
//
// Protocol sources: Jezza34000/homeassistant_petkit agora_api.py / agora_websocket.py / agora_sdp.py (MIT, commit 4a474a5),
// which drive Agora's web gateway without the SDK, and the Agora Web SDK NG 4.24.0 itself (the version Wyze's viewer bundles),
// read for field names, the RSA key that wraps the media secret, the data_stream envelope and the ping cadence. The Wyze-specific
// parts (mode "rtc", codec "h265", aes_* fields, the check-user command) follow alphabin/ClaudeWyze4Sln WRITEUP.md section 4.
// Our own implementation.
//
//   POST https://webrtc2-ap-web-{1..4}.agora.io/api/v2/transpond/webrtc?v=2   (backups -5, -6)
//     multipart/form-data, one part "request" (application/json):
//     {"appid","client_ts","opid","sid","request_bodies":[{"uri":22,"buffer":{"cname","detail":{"11":"CN,GLOBAL","17":"1",
//      "22":"CN,GLOBAL"},"key":<rtc token>,"service_ids":[11,26],"uid"}}]}
//     -> {"enter_ts","opid","detail":{},"response_body":[{"buffer":{"code":0,"flag":4096,"uid","cid","cname","cert",
//         "edges_services":[{"ip","port"}],"detail":{"19":"<fingerprint>;<fingerprint>"}}}]}
//   wss://<ip with dashes>.edge.agora.io:<port>  (one per edges_services entry, tried in order)
//     -> {"_id","_type":"join_v3","_message":{...,"ortc":<our ICE/DTLS/RTP capabilities>}}
//     <- {"_id","_result":"success","_message":{"ortc":<gateway ICE/DTLS/RTP capabilities and candidates>}}
//     <- {"_type":"on_user_online","_message":{"uid"}}, {"_type":"on_add_video_stream","_message":{"uid","ssrcId","video":true}}
//     -> subscribe, data_stream, ping (every 3 s), renew_token

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// The access point hosts the Web SDK uses, in its order (WEBCS_DOMAIN, then WEBCS_DOMAIN_BACKUP).
var agoraAPHosts = []string{
	"webrtc2-ap-web-1.agora.io", "webrtc2-ap-web-2.agora.io", "webrtc2-ap-web-3.agora.io", "webrtc2-ap-web-4.agora.io",
	"webrtc2-ap-web-5.agora.io", "webrtc2-ap-web-6.agora.io",
}

const (
	agoraSDKVersion = "4.24.0"
	apFlagGateway   = 4096 // response_body buffer flag of the gateway list (service 11, CHOOSE_SERVER)
	// The SPKI public key the Web SDK uses to wrap the media secret (RSA-OAEP, SHA-256) before it is sent in join_v3. Agora's,
	// not an account secret: it is a literal in AgoraRTC_N-production.js 4.24.0.
	agoraGatewayRSAKey = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDCMnXAHkKIGAM+x4N22gCI+Wyu" +
		"STM9ztkT3uYslTT2PuKmZfPzhH6kVdO7PTjGCOZnAsyb3oTtWat0KcxQ4jxvqQV+" +
		"HvYl3iI1Yd4vl2c3qRMJPLtRDfNxa2Mcxgq7e9aEUibzdd0st+OJAy3tOj/Y0aVy" +
		"xQiYDz3vqa6bP29adwIDAQAB"
)

type object = map[string]any

// Test seams: where the access point and the gateway really are.
var (
	apURL   = func(host string) string { return "https://" + host + "/api/v2/transpond/webrtc?v=2" }
	dialURL = func(edgeURL string) string { return edgeURL }
)

// ---- access point ---------------------------------------------------------------------------------------------------------

type agoraEdge struct {
	URL         string // wss://a-b-c-d.edge.agora.io:port
	Fingerprint string // "sha-256 AB:CD:..." or ""
}

type apResult struct {
	Edges      []agoraEdge
	APResponse object // what join_v3 carries back as ap_response
}

func buildAPRequest(appID, channel, rtcToken string, uid int64, sid string, now time.Time) ([]byte, string, error) {
	payload := object{
		"appid":     appID,
		"client_ts": now.UnixMilli(),
		"opid":      randInt(1, 999999999999),
		"sid":       sid,
		"request_bodies": []any{object{
			"uri": 22,
			"buffer": object{
				"cname":       channel,
				"detail":      object{"11": "CN,GLOBAL", "17": "1", "22": "CN,GLOBAL"},
				"key":         rtcToken,
				"service_ids": []int{11, 26},
				"uid":         uid,
			},
		}},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, "", err
	}
	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	h := textproto.MIMEHeader{}
	h.Set("Content-Disposition", `form-data; name="request"`)
	h.Set("Content-Type", "application/json")
	part, err := form.CreatePart(h)
	if err != nil {
		return nil, "", err
	}
	part.Write(raw)
	if err := form.Close(); err != nil {
		return nil, "", err
	}
	return body.Bytes(), form.FormDataContentType(), nil
}

func parseAPResponse(raw []byte) (*apResult, error) {
	var d struct {
		EnterTS      json.RawMessage `json:"enter_ts"`
		OpID         json.RawMessage `json:"opid"`
		Detail       object          `json:"detail"`
		ResponseBody []struct {
			Buffer struct {
				Code   json.RawMessage `json:"code"`
				Flag   json.RawMessage `json:"flag"`
				UID    json.RawMessage `json:"uid"`
				CID    json.RawMessage `json:"cid"`
				CName  string          `json:"cname"`
				Cert   string          `json:"cert"`
				Detail object          `json:"detail"`
				Edges  []struct {
					IP   string          `json:"ip"`
					Port json.RawMessage `json:"port"`
				} `json:"edges_services"`
			} `json:"buffer"`
		} `json:"response_body"`
	}
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, errors.New("agora ap: unreadable answer")
	}
	for _, rb := range d.ResponseBody {
		b := rb.Buffer
		if codeString(b.Code) != "0" || codeString(b.Flag) != strconv.Itoa(apFlagGateway) {
			continue
		}
		detail := object{}
		for k, v := range d.Detail {
			detail[k] = v
		}
		for k, v := range b.Detail {
			detail[k] = v
		}
		fps := []string{}
		if s, ok := detail["19"].(string); ok && s != "" {
			for _, f := range strings.Split(s, ";") {
				fps = append(fps, strings.TrimSpace(f))
			}
		}
		res := &apResult{APResponse: object{
			"code": 0, "server_ts": rawNumber(d.EnterTS), "uid": rawNumber(b.UID), "cid": rawNumber(b.CID),
			"cname": b.CName, "detail": detail, "flag": apFlagGateway, "opid": rawNumber(d.OpID),
			"cert": b.Cert, "ticket": b.Cert,
		}}
		for i, e := range b.Edges {
			ip := net.ParseIP(e.IP)
			port, _ := strconv.Atoi(codeString(e.Port))
			if ip == nil || ip.To4() == nil || port < 1 || port > 65535 {
				continue
			}
			fp := ""
			if i < len(fps) && fps[i] != "" {
				fp = fps[i]
				if !strings.Contains(fp, " ") {
					fp = "sha-256 " + fp
				}
			}
			res.Edges = append(res.Edges, agoraEdge{
				URL:         fmt.Sprintf("wss://%s.edge.agora.io:%d", strings.ReplaceAll(ip.To4().String(), ".", "-"), port),
				Fingerprint: fp,
			})
		}
		if len(res.Edges) > 0 {
			return res, nil
		}
	}
	return nil, errors.New("agora ap: no gateway in the answer")
}

// rawNumber keeps a JSON number as a number (json.Number) so it is re-sent exactly as received.
func rawNumber(raw json.RawMessage) any {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return 0
	}
	if strings.HasPrefix(s, `"`) {
		var str string
		_ = json.Unmarshal(raw, &str)
		return str
	}
	return json.Number(s)
}

// chooseServer asks the access points, in order, for this channel's gateways.
func chooseServer(ctx context.Context, client *http.Client, hosts []string, appID, channel, rtcToken string, uid int64, sid string) (*apResult, error) {
	var last error = errors.New("agora ap: no host answered")
	for _, host := range hosts {
		body, ctype, err := buildAPRequest(appID, channel, rtcToken, uid, sid, time.Now())
		if err != nil {
			return nil, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, apURL(host), bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", ctype)
		resp, err := client.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			last = fmt.Errorf("agora ap %s: %v", host, stripURLError(err))
			continue
		}
		raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if err != nil || resp.StatusCode != http.StatusOK {
			last = fmt.Errorf("agora ap %s: http %d", host, resp.StatusCode)
			continue
		}
		res, err := parseAPResponse(raw)
		if err != nil {
			last = fmt.Errorf("agora ap %s: %v", host, err)
			continue
		}
		return res, nil
	}
	return nil, last
}

// wrapMediaSecret wraps the media key the way the Web SDK does for join_v3's aes_secret: RSA-OAEP(SHA-256) under Agora's
// gateway key, base64.
func wrapMediaSecret(secret string) (string, error) {
	der, err := base64.StdEncoding.DecodeString(agoraGatewayRSAKey)
	if err != nil {
		return "", err
	}
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return "", err
	}
	rsaPub, ok := pub.(*rsa.PublicKey)
	if !ok {
		return "", errors.New("agora gateway key is not RSA")
	}
	ct, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, rsaPub, []byte(secret), nil)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(ct), nil
}

// aesModeName maps get-streams' encryption_mode to the Web SDK's mode string (WRITEUP section 3).
func aesModeName(mode int) (string, error) {
	switch mode {
	case 7:
		return "aes-128-gcm2", nil
	case 8:
		return "aes-256-gcm2", nil
	case 0:
		return "", nil
	}
	return "", fmt.Errorf("unsupported encryption_mode %d", mode)
}

// ---- gateway messages ------------------------------------------------------------------------------------------------------

// gwMessage is one gateway frame. Notifications carry _type; replies carry _id and _result.
type gwMessage struct {
	ID      string
	Type    string
	Result  string
	Message object
	Code    int // error_code, from the frame or its _message
}

func parseGatewayMessage(raw []byte) (*gwMessage, error) {
	var d map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&d); err != nil {
		return nil, err
	}
	m := &gwMessage{ID: anyString(d["_id"]), Type: anyString(d["_type"]), Result: anyString(d["_result"])}
	if body, ok := d["_message"].(map[string]any); ok {
		m.Message = body
	} else {
		m.Message = object{}
	}
	m.Code = int(anyInt(d["error_code"]))
	if m.Code == 0 {
		m.Code = int(anyInt(m.Message["error_code"]))
	}
	if m.Code == 0 {
		m.Code = int(anyInt(m.Message["code"]))
	}
	return m, nil
}

func anyString(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case json.Number:
		return t.String()
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case nil:
		return ""
	}
	return fmt.Sprint(v)
}

func anyInt(v any) int64 {
	switch t := v.(type) {
	case json.Number:
		if i, err := t.Int64(); err == nil {
			return i
		}
		if f, err := t.Float64(); err == nil {
			return int64(f)
		}
	case float64:
		return int64(t)
	case int:
		return int64(t)
	case int64:
		return t
	case string:
		i, _ := strconv.ParseInt(t, 10, 64)
		return i
	}
	return 0
}

func anyMap(v any) object {
	if m, ok := v.(map[string]any); ok {
		return m
	}
	return object{}
}

func anySlice(v any) []any {
	if a, ok := v.([]any); ok {
		return a
	}
	return nil
}

// joinParams is what join_v3 needs.
type joinParams struct {
	AppID      string
	Channel    string
	RTCToken   string
	UID        int64
	SessionID  string
	Codec      string // "h265" | "h264"
	LowStream  bool   // ask for the publisher's low (dual) stream by default
	APResponse object
	ORTC       object
	AESMode    string // "" when the stream is not encrypted
	AESSecret  string // RSA-wrapped media key
	AESSalt    string // base64 of the 32-byte salt
	Now        time.Time
}

func buildJoinMessage(p joinParams) object {
	m := object{
		"uid":                 p.UID,
		"p2p_id":              1,
		"session_id":          p.SessionID,
		"app_id":              p.AppID,
		"channel_key":         p.RTCToken,
		"channel_name":        p.Channel,
		"sdk_version":         agoraSDKVersion,
		"browser":             browserUA,
		"process_id":          "process-" + uuidLike(),
		"mode":                "rtc",
		"codec":               p.Codec,
		"role":                "host",
		"has_changed_gateway": false,
		"ap_response":         p.APResponse,
		"extend":              "",
		"details":             object{},
		"features":            object{"rejoin": true},
		"attributes": object{"userAttributes": object{
			"enablePublishedUserList": true, "maxSubscription": 50, "enableUserLicenseCheck": true, "enableRTX": true,
			"enableInstantVideo": false, "enableDataStream2": false, "enableAutFeedback": true,
			"enableUserAutoRebalanceCheck": true, "enableXR": true, "enableLossbasedBwe": true, "enableAutCC": true,
			"enablePreallocPC": false, "enablePubTWCC": false, "enableSubTWCC": true, "enablePubRTX": true, "enableSubRTX": true,
		}},
		"join_ts":              p.Now.UnixMilli(),
		"ortc":                 p.ORTC,
		"default_video_stream": map[bool]int{false: 0, true: 1}[p.LowStream], // 0 high (main), 1 low
	}
	if p.AESMode != "" {
		m["aes_mode"] = p.AESMode
		m["aes_secret"] = p.AESSecret
		m["aes_encrypt"] = true // the SDK's ENCRYPT_AES default: aes_secret is RSA-wrapped
		if p.AESSalt != "" {
			m["aes_salt"] = p.AESSalt
		}
	}
	return m
}

// cameraCommands is the data_stream payload the camera listens to: a JSON array of commands, UTF-8 (WRITEUP section 4).
func cameraCommands(userID, resolution string) []byte {
	cmds := []any{object{"cmd": "run_action", "action": "sight-safe::check-user", "params": object{"userId": userID}}}
	if resolution != "" {
		cmds = append(cmds, object{"cmd": "set_property", "props": object{"camera::resolution": resolution}})
	}
	b, _ := json.Marshal(cmds)
	return b
}

// subscribeMessage asks for one stream; streamType is "video" or "audio" (codec is the session's video codec, as the SDK sends).
func subscribeMessage(streamUID, ssrc any, codec, streamType string) object {
	return object{"stream_id": streamUID, "stream_type": streamType, "mode": "rtc", "codec": codec, "p2p_id": 1,
		"twcc": false, "rtx": true, "extend": "", "ssrcId": ssrc}
}

func uuidLike() string {
	h := randHex(16)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// ---- gateway connection ------------------------------------------------------------------------------------------------------

type gateway struct {
	conn    *websocket.Conn
	wmu     sync.Mutex
	started time.Time
	in      chan *gwMessage
	readErr chan error
	once    sync.Once
}

func dialGateway(ctx context.Context, url string) (*gateway, error) {
	d := websocket.Dialer{HandshakeTimeout: 8 * time.Second, Proxy: http.ProxyFromEnvironment}
	conn, resp, err := d.DialContext(ctx, dialURL(url), http.Header{"User-Agent": {browserUA}})
	if resp != nil && resp.Body != nil {
		resp.Body.Close()
	}
	if err != nil {
		return nil, err
	}
	conn.SetReadLimit(4 << 20)
	g := &gateway{conn: conn, started: time.Now(), in: make(chan *gwMessage, 64), readErr: make(chan error, 1)}
	go g.readLoop()
	return g, nil
}

const gatewayReadTimeout = 45 * time.Second

func (g *gateway) readLoop() {
	for {
		g.conn.SetReadDeadline(time.Now().Add(gatewayReadTimeout))
		_, raw, err := g.conn.ReadMessage()
		if err != nil {
			g.readErr <- err
			close(g.in)
			return
		}
		m, err := parseGatewayMessage(raw)
		if err != nil {
			continue
		}
		g.in <- m
	}
}

// send writes {"_id","_type","_message"} and returns the _id (replies carry it back).
func (g *gateway) send(typ string, body any) (string, error) {
	id := randHex(3)
	frame := object{"_id": id, "_type": typ}
	if body != nil {
		frame["_message"] = body
	}
	raw, err := json.Marshal(frame)
	if err != nil {
		return "", err
	}
	g.wmu.Lock()
	defer g.wmu.Unlock()
	g.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return id, g.conn.WriteMessage(websocket.TextMessage, raw)
}

func (g *gateway) sendCommands(payload []byte) error {
	_, err := g.send("data_stream", object{
		"payload": base64.StdEncoding.EncodeToString(payload), "syncWithAudio": false,
		"sendTs": time.Since(g.started).Milliseconds(),
	})
	return err
}

func (g *gateway) close() {
	g.once.Do(func() {
		g.wmu.Lock()
		g.conn.SetWriteDeadline(time.Now().Add(time.Second))
		g.conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
		g.wmu.Unlock()
		g.conn.Close()
	})
}
