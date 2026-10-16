// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"strings"
	"testing"
	"time"
)

func TestAPRequestShape(t *testing.T) {
	body, ctype, err := buildAPRequest("APPID", "CHAN", "RTCTOK", 12345, "SID", time.UnixMilli(1700000000000))
	if err != nil {
		t.Fatal(err)
	}
	_, params, _ := mime.ParseMediaType(ctype)
	r := multipart.NewReader(bytes.NewReader(body), params["boundary"])
	part, err := r.NextPart()
	if err != nil || part.FormName() != "request" || part.Header.Get("Content-Type") != "application/json" {
		t.Fatal(err, part.Header)
	}
	raw, _ := io.ReadAll(part)
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if m["appid"] != "APPID" || m["sid"] != "SID" || m["client_ts"].(float64) != 1700000000000 {
		t.Fatal(m)
	}
	b := m["request_bodies"].([]any)[0].(map[string]any)
	buf := b["buffer"].(map[string]any)
	if b["uri"].(float64) != 22 || buf["cname"] != "CHAN" || buf["key"] != "RTCTOK" || buf["uid"].(float64) != 12345 {
		t.Fatal(b)
	}
	if ids := buf["service_ids"].([]any); len(ids) != 2 || ids[0].(float64) != 11 || ids[1].(float64) != 26 {
		t.Fatal(ids)
	}
	d := buf["detail"].(map[string]any)
	if d["11"] != "CN,GLOBAL" || d["17"] != "1" || d["22"] != "CN,GLOBAL" {
		t.Fatal(d)
	}
}

const apSample = `{"code":0,"enter_ts":1700000000123,"opid":42,"detail":{"502":"x"},"response_body":[
 {"buffer":{"code":0,"flag":4194310,"edges_services":[{"ip":"9.9.9.9","port":3478}]}},
 {"buffer":{"code":0,"flag":4096,"uid":12345,"cid":777,"cname":"CHAN","cert":"TICKET","detail":{"19":"AB:CD;EF:01"},
  "edges_services":[{"ip":"128.1.2.3","port":4701},{"ip":"bad","port":1},{"ip":"128.1.2.4","port":4702}]}}]}`

func TestParseAPResponse(t *testing.T) {
	r, err := parseAPResponse([]byte(apSample))
	if err != nil {
		t.Fatal(err)
	}
	if len(r.Edges) != 2 || r.Edges[0].URL != "wss://128-1-2-3.edge.agora.io:4701" || r.Edges[0].Fingerprint != "sha-256 AB:CD" {
		t.Fatalf("%+v", r.Edges)
	}
	// The fingerprint list is indexed like edges_services; the invalid entry still takes a slot.
	if r.Edges[1].URL != "wss://128-1-2-4.edge.agora.io:4702" || r.Edges[1].Fingerprint != "" {
		t.Fatalf("%+v", r.Edges[1])
	}
	ap := r.APResponse
	raw, _ := json.Marshal(ap)
	for _, want := range []string{`"cert":"TICKET"`, `"ticket":"TICKET"`, `"flag":4096`, `"server_ts":1700000000123`, `"opid":42`, `"cid":777`, `"502":"x"`, `"19":"AB:CD;EF:01"`} {
		if !strings.Contains(string(raw), want) {
			t.Errorf("ap_response lacks %s: %s", want, raw)
		}
	}
	if _, err := parseAPResponse([]byte(`{"response_body":[{"buffer":{"code":5,"flag":4096}}]}`)); err == nil {
		t.Fatal("failed buffer accepted")
	}
}

func TestWrapMediaSecret(t *testing.T) {
	a, err := wrapMediaSecret("Sample-Key!2026")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(a)
	if err != nil || len(raw) != 128 { // RSA-1024
		t.Fatal(len(raw), err)
	}
	b, _ := wrapMediaSecret("Sample-Key!2026")
	if a == b {
		t.Fatal("OAEP must be randomised")
	}
}

func TestJoinMessage(t *testing.T) {
	m := buildJoinMessage(joinParams{AppID: "A", Channel: "C", RTCToken: "T", UID: 12345, SessionID: "S", Codec: "h265",
		APResponse: object{"flag": 4096}, ORTC: object{"version": "2"}, AESMode: "aes-128-gcm2", AESSecret: "W", AESSalt: "SALT",
		Now: time.UnixMilli(5)})
	raw, _ := json.Marshal(m)
	for _, want := range []string{`"app_id":"A"`, `"channel_name":"C"`, `"channel_key":"T"`, `"uid":12345`, `"mode":"rtc"`,
		`"codec":"h265"`, `"role":"host"`, `"sdk_version":"4.24.0"`, `"aes_mode":"aes-128-gcm2"`, `"aes_secret":"W"`,
		`"aes_salt":"SALT"`, `"aes_encrypt":true`, `"p2p_id":1`, `"join_ts":5`, `"session_id":"S"`, `"default_video_stream":0`} {
		if !strings.Contains(string(raw), want) {
			t.Errorf("join lacks %s", want)
		}
	}
	plain := buildJoinMessage(joinParams{Codec: "h265"})
	if _, ok := plain["aes_mode"]; ok {
		t.Fatal("aes fields without encryption")
	}
	if mode, _ := aesModeName(7); mode != "aes-128-gcm2" {
		t.Fatal(mode)
	}
	if mode, _ := aesModeName(8); mode != "aes-256-gcm2" {
		t.Fatal(mode)
	}
	if _, err := aesModeName(3); err == nil {
		t.Fatal("mode 3 accepted")
	}
}

func TestCameraCommands(t *testing.T) {
	if got := string(cameraCommands("u1", "")); got != `[{"action":"sight-safe::check-user","cmd":"run_action","params":{"userId":"u1"}}]` {
		t.Fatal(got)
	}
	got := string(cameraCommands("u1", "2k"))
	if !strings.HasSuffix(got, `,{"cmd":"set_property","props":{"camera::resolution":"2k"}}]`) {
		t.Fatal(got)
	}
	s := subscribeMessage(json.Number("1"), json.Number("4242"), "h265", "video")
	raw, _ := json.Marshal(s)
	if string(raw) != `{"codec":"h265","extend":"","mode":"rtc","p2p_id":1,"rtx":true,"ssrcId":4242,"stream_id":1,"stream_type":"video","twcc":false}` {
		t.Fatal(string(raw))
	}
}

func TestParseGatewayMessage(t *testing.T) {
	m, err := parseGatewayMessage([]byte(`{"_id":"a1b2c3","_result":"success","_message":{"ortc":{"version":"2"}}}`))
	if err != nil || m.ID != "a1b2c3" || m.Result != "success" || anyMap(m.Message["ortc"])["version"] != "2" {
		t.Fatal(m, err)
	}
	m, _ = parseGatewayMessage([]byte(`{"_type":"on_add_video_stream","_message":{"uid":1,"ssrcId":3000000001,"video":true}}`))
	if m.Type != "on_add_video_stream" || anyInt(m.Message["ssrcId"]) != 3000000001 || m.Message["video"] != true {
		t.Fatal(m)
	}
	m, _ = parseGatewayMessage([]byte(`{"_id":7,"_result":"error","error_code":4096,"_message":null}`))
	if m.ID != "7" || m.Code != 4096 || m.Message == nil {
		t.Fatal(m)
	}
	m, _ = parseGatewayMessage([]byte(`{"_type":"on_p2p_lost","_message":{"error_code":21}}`))
	if m.Code != 21 {
		t.Fatal(m)
	}
}
