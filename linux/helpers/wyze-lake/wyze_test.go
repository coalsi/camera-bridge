// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testToken = "TESTTOKEN_0123456789abcdef_not_real"

// Vectors computed independently in Python (hashlib/hmac, and a straight transcription of xxtea-js encrypt):
// signature2 = hmac_md5(key=md5hex(token+secret), body).
func TestSignature2Vector(t *testing.T) {
	got := signature2(testToken, []byte(`{"nonce":1700000000000}`))
	if got != "63682056cf06471984c9f5f2174bbb67" {
		t.Fatalf("signature2 = %s", got)
	}
}

func TestXXTEAVectors(t *testing.T) {
	key, err := unwrapSecret("WatOPD7tdN9fQ7LyLQG7yuBqtDU=", testToken)
	if err != nil || key != "Sample-Key!2026" {
		t.Fatalf("key = %q, %v", key, err)
	}
	salt, err := unwrapSecret("9djlZZSVQcAYgHdlkMlDI2yjRlxfLruId/tMEeJezcnv6L425XpNLbnSiU+0ODRb", testToken)
	if err != nil || salt != "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=" {
		t.Fatalf("salt = %q, %v", salt, err)
	}
	raw, _ := base64.StdEncoding.DecodeString(salt)
	if len(raw) != 32 {
		t.Fatalf("salt is %d bytes", len(raw))
	}
	if _, err := unwrapSecret("WatOPD7tdN9fQ7LyLQG7yuBqtDU=", "another-token-entirely"); err == nil {
		t.Fatal("wrong key accepted")
	}
	if _, err := unwrapSecret("not base64!!", testToken); err == nil {
		t.Fatal("bad base64 accepted")
	}
}

// xxteaEncrypt is xxtea-js encrypt (with the length word), for the round-trip test.
func xxteaEncrypt(data, key []byte) []byte {
	n := (len(data)+3)/4 + 1
	v := make([]uint32, n)
	padded := make([]byte, (n-1)*4)
	copy(padded, data)
	for i := 0; i < n-1; i++ {
		v[i] = binary.LittleEndian.Uint32(padded[i*4:])
	}
	v[n-1] = uint32(len(data))
	k := xxteaKey(key)
	z := v[n-1]
	var sum uint32
	for q := 6 + 52/n; q > 0; q-- {
		sum += xxteaDelta
		e := (sum >> 2) & 3
		for p := 0; p < n; p++ {
			y := v[(p+1)%n]
			v[p] += xxteaMX(sum, y, z, p, e, &k)
			z = v[p]
		}
	}
	out := make([]byte, n*4)
	for i := range v {
		binary.LittleEndian.PutUint32(out[i*4:], v[i])
	}
	return out
}

func TestXXTEARoundTrip(t *testing.T) {
	for _, s := range []string{"a", "abcd", "0123456789abcdef0123456789abcdef", strings.Repeat("x", 97)} {
		got, err := xxteaDecrypt(xxteaEncrypt([]byte(s), []byte(testToken)), []byte(testToken))
		if err != nil || string(got) != s {
			t.Fatalf("%q -> %q %v", s, got, err)
		}
	}
}

func TestBuildRequestHeadersAndSignature(t *testing.T) {
	c := newWyzeClient(testToken)
	c.reqID = func() string { return "123456789" }
	req, body, err := c.buildRequest(context.Background(), "/v4/wcsa/create-connection", map[string]any{"nonce": 1}, appInfoConnections)
	if err != nil {
		t.Fatal(err)
	}
	if req.URL.String() != "https://app.wyzecam.com/app/v4/wcsa/create-connection" || req.Method != http.MethodPost {
		t.Fatal(req.Method, req.URL)
	}
	sent, _ := io.ReadAll(req.Body)
	if !bytes.Equal(sent, body) || string(body) != `{"nonce":1}` {
		t.Fatalf("body %s", sent)
	}
	want := map[string]string{
		"appid": wyzeWebAppID, "appinfo": "wyze_web_3.3.5", "requestid": "123456789", "access_token": testToken,
		"Authorization": testToken, "Content-Type": "application/json", "signature2": signature2(testToken, body),
	}
	for k, v := range want {
		if got := req.Header.Get(k); got != v {
			t.Errorf("header %s = %q, want %q", k, got, v)
		}
	}
}

func TestParseWyzeResponse(t *testing.T) {
	data, err := parseWyzeResponse("/x", 200, []byte(`{"code":"1","msg":"","data":{"a":1}}`))
	if err != nil || string(data) != `{"a":1}` {
		t.Fatal(string(data), err)
	}
	if _, err := parseWyzeResponse("/x", 200, []byte(`{"code":1,"data":[]}`)); err != nil {
		t.Fatal("numeric code 1 refused", err)
	}
	for _, tc := range []struct {
		status int
		body   string
		auth   bool
		code   string
	}{
		{200, `{"code":"2001","msg":"AccessTokenError"}`, true, "2001"},
		{200, `{"code":2002}`, true, "2002"},
		{401, `{"code":"1"}`, true, "1"},
		{200, `{"code":"3044","msg":"device offline"}`, false, "3044"},
		{502, `<html>`, false, "unreadable"},
	} {
		_, err := parseWyzeResponse("/x", tc.status, []byte(tc.body))
		var we *wyzeError
		if !errors.As(err, &we) || we.authRejected() != tc.auth || we.Code != tc.code {
			t.Errorf("%v: %v", tc, err)
		}
		if strings.Contains(err.Error(), "offline") {
			t.Errorf("error repeats the body: %v", err)
		}
	}
}

func TestParseGetStreams(t *testing.T) {
	data := json.RawMessage(`[{"device_id":"AABBCCDDEEFF","provider":"lake","params":{"channel":"chan-1","protocol":3,"encryption_mode":7,
		"encryption_key":"K","encryption_salt":"S"}}]`)
	s, err := parseGetStreams(data, "AABBCCDDEEFF")
	if err != nil || s.Channel != "chan-1" || s.EncryptionMode != 7 || s.Protocol != 3 || s.WrappedKey != "K" || s.WrappedSalt != "S" {
		t.Fatal(s, err)
	}
	if _, err := parseGetStreams(json.RawMessage(`[{"device_id":"AABBCCDDEEFF","provider":"webrtc","params":{"channel":"x"}}]`), "AABBCCDDEEFF"); !errors.Is(err, errCameraNotLake) {
		t.Fatal(err)
	}
	if _, err := parseGetStreams(json.RawMessage(`[]`), "AABBCCDDEEFF"); !errors.Is(err, errCameraNotLake) {
		t.Fatal(err)
	}
	if _, err := parseGetStreams(data, "112233445566"); !errors.Is(err, errCameraNotLake) {
		t.Fatal("another camera's stream accepted", err)
	}
}

func TestParseCreateConnection(t *testing.T) {
	c, err := parseCreateConnection(json.RawMessage(`{"app_id":"app","uid":"54321","device_uid":1,"rtc_token":"tok","p2p_mode":true}`), 11111)
	if err != nil || c.AppID != "app" || c.UID != 54321 || c.DeviceUID != 1 || c.RTCToken != "tok" || !c.P2PMode {
		t.Fatal(c, err)
	}
	c, err = parseCreateConnection(json.RawMessage(`{"app_id":"app","rtc_token":"tok"}`), 11111)
	if err != nil || c.UID != 11111 {
		t.Fatal(c, err)
	}
	if _, err := parseCreateConnection(json.RawMessage(`{"app_id":"app"}`), 1); err == nil {
		t.Fatal("missing token accepted")
	}
}

// The three calls against a fake Wyze: bodies, appinfo, and the auth classification.
func TestWyzeCallsAgainstFakeServer(t *testing.T) {
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Header.Get("signature2") != signature2(testToken, body) {
			w.Write([]byte(`{"code":"1001","msg":"signature"}`))
			return
		}
		seen = append(seen, r.URL.Path+" "+r.Header.Get("appinfo"))
		var m map[string]any
		json.Unmarshal(body, &m)
		switch r.URL.Path {
		case "/app/v4/camera/get-streams":
			dl := m["device_list"].([]any)[0].(map[string]any)
			if dl["provider"] != "lake" || dl["device_id"] != "D03F27A1B2C3" || dl["device_model"] != "HL_PAN4" {
				t.Errorf("get-streams body %s", body)
			}
			w.Write([]byte(`{"code":"1","data":[{"device_id":"D03F27A1B2C3","provider":"lake","params":{"channel":"c","encryption_mode":7}}]}`))
		case "/app/v4/wcsa/create-connection":
			if m["mode"].(float64) != 3 || m["expire_time"].(float64) != 3600 || m["resolution"].(float64) != 2 || m["uid"].(float64) != 12345 {
				t.Errorf("create-connection body %s", body)
			}
			w.Write([]byte(`{"code":"1","data":{"app_id":"a","uid":12345,"device_uid":1,"rtc_token":"r"}}`))
		case "/app/v4/wcsa/renew-token":
			w.Write([]byte(`{"code":"2001","msg":"expired"}`))
		}
	}))
	defer srv.Close()
	c := newWyzeClient(testToken)
	c.base = srv.URL + "/app"
	ctx := context.Background()
	if _, err := c.getStreams(ctx, "D03F27A1B2C3", "HL_PAN4"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.createConnection(ctx, "D03F27A1B2C3", "HL_PAN4", 12345); err != nil {
		t.Fatal(err)
	}
	_, err := c.renewToken(ctx, "D03F27A1B2C3", "HL_PAN4", 12345)
	if e := classifyWyze("renew-token", err); e.code != exitAuth {
		t.Fatalf("renew 2001 -> %+v", e)
	}
	want := []string{"/app/v4/camera/get-streams wyze_web_2.3.1", "/app/v4/wcsa/create-connection wyze_web_3.3.5", "/app/v4/wcsa/renew-token wyze_web_3.3.5"}
	if strings.Join(seen, "|") != strings.Join(want, "|") {
		t.Fatal(seen)
	}
}

func TestClassifyWyze(t *testing.T) {
	cases := []struct {
		err  error
		code int
	}{
		{&wyzeError{Code: "2001"}, exitAuth},
		{&wyzeError{HTTP: 401, Code: "1"}, exitAuth},
		{errCameraNotLake, exitCameraGone},
		{&wyzeError{HTTP: 200, Code: "3044"}, exitSession},
		{errors.New("dial tcp: timeout"), exitSession},
	}
	for _, c := range cases {
		if got := classifyWyze("x", c.err).code; got != c.code {
			t.Errorf("%v -> %d, want %d", c.err, got, c.code)
		}
	}
}
