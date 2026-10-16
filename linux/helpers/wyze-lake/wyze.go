// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

// The Wyze side of a "lake" session: the three signed calls Wyze's own web viewer (my.wyze.com) makes for a camera whose
// device list entry says p2p.providers = ["lake"], and the unwrapping of the media key and salt.
//
// Protocol source: alphabin/ClaudeWyze4Sln WRITEUP.md sections 2-3 and lake/provision.py (MIT, commit 8e63ae0), captured
// from the web viewer on 2026-09-02. This file is our own implementation of that description.
//
//   POST https://app.wyzecam.com/app/v4/camera/get-streams     (appinfo wyze_web_2.3.1)
//     {"device_list":[{"device_id":MAC,"device_model":MODEL,"provider":"lake","parameters":{"use_trickle":true}}],"nonce":ms}
//     -> data[0].params = {channel, protocol:3, encryption_mode:7, encryption_key:b64(xxtea), encryption_salt:b64(xxtea)}
//   POST https://app.wyzecam.com/app/v4/wcsa/create-connection (appinfo wyze_web_3.3.5)
//     {"nonce":ms,"device_id":MAC,"device_model":MODEL,"mode":3,"uid":U,"expire_time":3600,"resolution":2}
//     -> data = {app_id, uid, device_uid, rtc_token, p2p_mode}
//   POST https://app.wyzecam.com/app/v4/wcsa/renew-token       (appinfo wyze_web_3.3.5)
//     {"nonce":ms,"device_id":MAC,"device_model":MODEL,"uid":U,"expire_time":3600} -> data.rtc_token
//
// Headers on all three: content-type: application/json, appid: strv_e7f78e9e7738dc50, appinfo, requestid: <random>,
// access_token and Authorization: <Wyze access token>, signature2: hex(HMAC-MD5(key = hex(MD5(token + secret)), body)).
// The body that is signed is exactly the body that is sent.

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	wyzeWebAPI         = "https://app.wyzecam.com/app"
	wyzeWebAppID       = "strv_e7f78e9e7738dc50"            // the web app's id (public, in Wyze's web bundle)
	wyzeWebSigningKey  = "gbJojEBViLklgwyyDikx5ztSvKBXI5oU" // the web bundle's signature2 secret for app.wyzecam.com (public)
	appInfoGetStreams  = "wyze_web_2.3.1"
	appInfoConnections = "wyze_web_3.3.5"
	rtcTokenLifetime   = 3600 // seconds, what the web viewer asks for
)

// signature2 is the web app's request signature: HMAC-MD5 over the exact body, keyed with the hex MD5 of token+secret.
func signature2(accessToken string, body []byte) string {
	k := md5.Sum([]byte(accessToken + wyzeWebSigningKey))
	m := hmac.New(md5.New, []byte(hex.EncodeToString(k[:])))
	m.Write(body)
	return hex.EncodeToString(m.Sum(nil))
}

// wyzeError is a refusal from the Wyze API. It never carries the response body (it may echo request data).
type wyzeError struct {
	Path string
	HTTP int
	Code string // Wyze's "code" ("1" is success)
}

func (e *wyzeError) Error() string {
	return fmt.Sprintf("wyze %s: http %d code %s", e.Path, e.HTTP, e.Code)
}

// authRejected tells whether Wyze refused the access token itself (expired or revoked): the daemon must mint a new one.
// 2001 is "access token expired" and 2002 "access token error" in every Wyze client we know of.
func (e *wyzeError) authRejected() bool {
	return e.HTTP == http.StatusUnauthorized || e.Code == "2001" || e.Code == "2002"
}

// errCameraNotLake: get-streams answered, but not with a lake stream for this camera (not on the account, or not a lake camera).
var errCameraNotLake = errors.New("wyze get-streams: the camera has no lake stream on this account")

type wyzeClient struct {
	base   string
	token  string
	http   *http.Client
	nowMS  func() int64
	reqID  func() string
	logURL bool
}

func newWyzeClient(token string) *wyzeClient {
	return &wyzeClient{
		base:  wyzeWebAPI,
		token: token,
		http: &http.Client{
			Timeout:       25 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		nowMS: func() int64 { return time.Now().UnixMilli() },
		reqID: func() string { return strconv.FormatInt(randInt(100000000, 999999999), 10) },
	}
}

// wyzeEnvelope is every Wyze answer: {"code":"1"|1, "msg":"...", "data":...}.
type wyzeEnvelope struct {
	Code json.RawMessage `json:"code"`
	Msg  string          `json:"msg"`
	Data json.RawMessage `json:"data"`
}

// codeString normalises "1" / 1 / 1.0 to "1".
func codeString(raw json.RawMessage) string {
	s := strings.TrimSpace(string(raw))
	s = strings.Trim(s, `"`)
	if f, err := strconv.ParseFloat(s, 64); err == nil && f == float64(int64(f)) {
		return strconv.FormatInt(int64(f), 10)
	}
	return s
}

// buildRequest makes the signed request (separate from post so tests can check headers and signature without a network).
func (c *wyzeClient) buildRequest(ctx context.Context, path string, payload any, appInfo string) (*http.Request, []byte, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+path, bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	h := req.Header
	h.Set("Content-Type", "application/json")
	h.Set("appid", wyzeWebAppID)
	h.Set("appinfo", appInfo)
	h.Set("requestid", c.reqID())
	h.Set("access_token", c.token)
	h.Set("Authorization", c.token)
	h.Set("signature2", signature2(c.token, body))
	// What the browser sends; harmless and closest to the captured traffic.
	h.Set("Origin", "https://my.wyze.com")
	h.Set("Referer", "https://my.wyze.com/")
	h.Set("User-Agent", browserUA)
	return req, body, nil
}

func (c *wyzeClient) post(ctx context.Context, path string, payload any, appInfo string) (json.RawMessage, error) {
	req, _, err := c.buildRequest(ctx, path, payload, appInfo)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		// net/http errors quote the URL; ours has no secrets in it, but keep only the class of failure.
		return nil, fmt.Errorf("wyze %s: request failed: %w", path, stripURLError(err))
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("wyze %s: read failed", path)
	}
	return parseWyzeResponse(path, resp.StatusCode, raw)
}

// parseWyzeResponse turns a Wyze answer into its data, or a *wyzeError.
func parseWyzeResponse(path string, httpStatus int, raw []byte) (json.RawMessage, error) {
	var env wyzeEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, &wyzeError{Path: path, HTTP: httpStatus, Code: "unreadable"}
	}
	code := codeString(env.Code)
	if httpStatus != http.StatusOK || code != "1" {
		if code == "" {
			code = "none"
		}
		return nil, &wyzeError{Path: path, HTTP: httpStatus, Code: code}
	}
	return env.Data, nil
}

// lakeStream is get-streams' answer for a lake camera, key and salt still wrapped.
type lakeStream struct {
	Channel        string
	Protocol       int
	EncryptionMode int
	WrappedKey     string
	WrappedSalt    string
}

func (c *wyzeClient) getStreams(ctx context.Context, mac, model string) (*lakeStream, error) {
	payload := map[string]any{
		"device_list": []any{map[string]any{
			"device_id": mac, "device_model": model, "provider": "lake",
			"parameters": map[string]any{"use_trickle": true},
		}},
		"nonce": c.nowMS(),
	}
	data, err := c.post(ctx, "/v4/camera/get-streams", payload, appInfoGetStreams)
	if err != nil {
		return nil, err
	}
	return parseGetStreams(data, mac)
}

func parseGetStreams(data json.RawMessage, mac string) (*lakeStream, error) {
	var list []struct {
		DeviceID string `json:"device_id"`
		Provider string `json:"provider"`
		Params   struct {
			Channel        string          `json:"channel"`
			Protocol       json.RawMessage `json:"protocol"`
			EncryptionMode json.RawMessage `json:"encryption_mode"`
			EncryptionKey  string          `json:"encryption_key"`
			EncryptionSalt string          `json:"encryption_salt"`
		} `json:"params"`
	}
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, errors.New("wyze get-streams: unreadable data")
	}
	for _, s := range list {
		if s.DeviceID != "" && !strings.EqualFold(s.DeviceID, mac) {
			continue
		}
		if s.Provider != "" && s.Provider != "lake" {
			continue
		}
		if s.Params.Channel == "" {
			continue
		}
		mode, _ := strconv.Atoi(codeString(s.Params.EncryptionMode))
		proto, _ := strconv.Atoi(codeString(s.Params.Protocol))
		return &lakeStream{Channel: s.Params.Channel, Protocol: proto, EncryptionMode: mode,
			WrappedKey: s.Params.EncryptionKey, WrappedSalt: s.Params.EncryptionSalt}, nil
	}
	return nil, errCameraNotLake
}

// lakeConnection is create-connection's answer: the Agora app id, our uid, the camera's uid and the RTC token.
type lakeConnection struct {
	AppID     string
	UID       int64
	DeviceUID int64
	RTCToken  string
	P2PMode   bool
}

func (c *wyzeClient) createConnection(ctx context.Context, mac, model string, uid int64) (*lakeConnection, error) {
	payload := map[string]any{
		"nonce": c.nowMS(), "device_id": mac, "device_model": model,
		"mode": 3, "uid": uid, "expire_time": rtcTokenLifetime, "resolution": 2,
	}
	data, err := c.post(ctx, "/v4/wcsa/create-connection", payload, appInfoConnections)
	if err != nil {
		return nil, err
	}
	return parseCreateConnection(data, uid)
}

func parseCreateConnection(data json.RawMessage, uid int64) (*lakeConnection, error) {
	var d struct {
		AppID     string          `json:"app_id"`
		UID       json.RawMessage `json:"uid"`
		DeviceUID json.RawMessage `json:"device_uid"`
		RTCToken  string          `json:"rtc_token"`
		P2PMode   bool            `json:"p2p_mode"`
	}
	if err := json.Unmarshal(data, &d); err != nil {
		return nil, errors.New("wyze create-connection: unreadable data")
	}
	conn := &lakeConnection{AppID: d.AppID, RTCToken: d.RTCToken, P2PMode: d.P2PMode, UID: uid, DeviceUID: 1}
	if v, err := strconv.ParseInt(codeString(d.UID), 10, 64); err == nil && v > 0 {
		conn.UID = v
	}
	if v, err := strconv.ParseInt(codeString(d.DeviceUID), 10, 64); err == nil && v > 0 {
		conn.DeviceUID = v
	}
	if conn.AppID == "" || conn.RTCToken == "" {
		return nil, errors.New("wyze create-connection: app_id or rtc_token missing")
	}
	return conn, nil
}

func (c *wyzeClient) renewToken(ctx context.Context, mac, model string, uid int64) (string, error) {
	payload := map[string]any{
		"nonce": c.nowMS(), "device_id": mac, "device_model": model, "uid": uid, "expire_time": rtcTokenLifetime,
	}
	data, err := c.post(ctx, "/v4/wcsa/renew-token", payload, appInfoConnections)
	if err != nil {
		return "", err
	}
	var d struct {
		RTCToken string `json:"rtc_token"`
	}
	if json.Unmarshal(data, &d) != nil || d.RTCToken == "" {
		return "", errors.New("wyze renew-token: rtc_token missing")
	}
	return d.RTCToken, nil
}

// ---- XXTEA, as the xxtea-js package the web app bundles does it ----------------------------------------------------------
//
// Key: the first 16 bytes of the access token (zero padded), read as four little-endian words. Data: little-endian words.
// The plaintext's length is stored in the last word (xxtea-js "includeLength"), so a wrong key is caught by that check.

const xxteaDelta uint32 = 0x9e3779b9

func xxteaKey(key []byte) [4]uint32 {
	var kb [16]byte
	copy(kb[:], key)
	var k [4]uint32
	for i := range k {
		k[i] = binary.LittleEndian.Uint32(kb[i*4:])
	}
	return k
}

func xxteaMX(sum, y, z uint32, p int, e uint32, k *[4]uint32) uint32 {
	return ((z>>5 ^ y<<2) + (y>>3 ^ z<<4)) ^ ((sum ^ y) + (k[uint32(p)&3^e] ^ z))
}

// xxteaDecrypt reverses xxtea-js encrypt(data, key) and returns the plaintext (length word removed).
func xxteaDecrypt(data, key []byte) ([]byte, error) {
	if len(data) < 8 || len(data)%4 != 0 {
		return nil, errors.New("xxtea: bad ciphertext length")
	}
	n := len(data) / 4
	v := make([]uint32, n)
	for i := range v {
		v[i] = binary.LittleEndian.Uint32(data[i*4:])
	}
	k := xxteaKey(key)
	rounds := 6 + 52/n
	sum := uint32(rounds) * xxteaDelta
	y := v[0]
	for ; rounds > 0; rounds-- {
		e := (sum >> 2) & 3
		for p := n - 1; p > 0; p-- {
			z := v[p-1]
			v[p] -= xxteaMX(sum, y, z, p, e, &k)
			y = v[p]
		}
		z := v[n-1]
		v[0] -= xxteaMX(sum, y, z, 0, e, &k)
		y = v[0]
		sum -= xxteaDelta
	}
	m := int(v[n-1])
	total := (n - 1) * 4
	if m < total-3 || m > total {
		return nil, errors.New("xxtea: bad length word (wrong key?)")
	}
	out := make([]byte, n*4)
	for i := range v {
		binary.LittleEndian.PutUint32(out[i*4:], v[i])
	}
	return out[:m], nil
}

// unwrapSecret decodes one of get-streams' wrapped values: base64, then XXTEA with the access token.
func unwrapSecret(b64, accessToken string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return "", errors.New("wrapped value is not base64")
	}
	plain, err := xxteaDecrypt(raw, []byte(accessToken))
	if err != nil {
		return "", err
	}
	return string(plain), nil
}

// ---- small helpers ------------------------------------------------------------------------------------------------------

// randInt returns a uniform random integer in [lo, hi].
func randInt(lo, hi int64) int64 {
	n, err := rand.Int(rand.Reader, big.NewInt(hi-lo+1))
	if err != nil {
		panic("crypto/rand unavailable")
	}
	return lo + n.Int64()
}

func randHex(nbytes int) string {
	b := make([]byte, nbytes)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable")
	}
	return hex.EncodeToString(b)
}

// stripURLError keeps the cause of a net/http failure without the URL it quotes.
func stripURLError(err error) error {
	var ue interface{ Unwrap() error }
	if errors.As(err, &ue) {
		if inner := ue.Unwrap(); inner != nil {
			return inner
		}
	}
	return err
}

// The browser user agent sent to Wyze and Agora (the web viewer runs in a browser; Agora's join carries it too).
const browserUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
