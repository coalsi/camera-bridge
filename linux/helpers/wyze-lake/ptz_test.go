// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestMoveCommandEncoding(t *testing.T) {
	got := string(moveCommand(ptzMove{Direction: "left", Step: 10, Speed: 5}))
	want := `[{"cmd":"run_action","action":"camera-position::move-position","params":{"direction":"left","speed":5,"step":10}}]`
	if got != want {
		t.Fatalf("%s\nwant %s", got, want)
	}
}

func TestParseMoveRequest(t *testing.T) {
	m, err := parseMoveRequest(strings.NewReader(`{"direction":"down"}`))
	if err != nil || m != (ptzMove{Direction: "down", Step: 10, Speed: 5}) {
		t.Fatal(m, err)
	}
	m, err = parseMoveRequest(strings.NewReader(`{"direction":"right","step":60,"speed":1}`))
	if err != nil || m != (ptzMove{Direction: "right", Step: 60, Speed: 1}) {
		t.Fatal(m, err)
	}
	for _, bad := range []string{``, `{}`, `{"direction":"north"}`, `{"direction":"up","step":0}`, `{"direction":"up","step":61}`,
		`{"direction":"up","speed":11}`, `{"direction":"up","speed":0}`, `{"direction":"up","extra":1}`, `{"direction":"up","step":"5"}`, `[1]`} {
		if _, err := parseMoveRequest(strings.NewReader(bad)); err == nil {
			t.Errorf("accepted %s", bad)
		}
	}
}

func TestParseDataStream(t *testing.T) {
	enc := func(s string) object {
		return object{"uid": 1, "payload": base64.StdEncoding.EncodeToString([]byte(s))}
	}
	cases := []struct {
		in     string
		action string
		result int
	}{
		{`[{"cmd":"run_action","action":"camera-position::move-position","result":1}]`, ptzAction, 1},
		{`{"data":"[{\"action\":\"camera-position::move-position\",\"result\":1}]"}`, ptzAction, 1}, // escaped inside JSON
		{`{"action":"camera-position::move-position","result":"0"}`, ptzAction, 0},
		{`[{"action":"sight-safe::check-user","result":1}]`, "sight-safe::check-user", 1},
		{`{"hello":true}`, "", -999},
	}
	for _, c := range cases {
		r, ok := parseDataStream(enc(c.in))
		if !ok || r.Action != c.action || r.Result != c.result {
			t.Errorf("%s -> %+v", c.in, r)
		}
	}
	if _, ok := parseDataStream(object{"payload": "!!"}); ok {
		t.Fatal("bad base64 accepted")
	}
}

func TestPTZQueueDropsOldest(t *testing.T) {
	q := newPTZQueue()
	for i, d := range []string{"left", "right", "up"} {
		if dropped := q.push(ptzMove{Direction: d, Step: 1, Speed: 5}); dropped != map[int]int{0: 0, 1: 0, 2: 1}[i] {
			t.Fatal(i, dropped)
		}
	}
	a, _ := q.pop()
	b, _ := q.pop()
	if _, more := q.pop(); a.Direction != "right" || b.Direction != "up" || more {
		t.Fatal(a, b)
	}
	select {
	case <-q.notify:
	default:
		t.Fatal("no notification")
	}
}

func TestPTZDriver(t *testing.T) {
	q := newPTZQueue()
	d := &ptzDriver{q: q}
	q.push(ptzMove{Direction: "left", Step: 10, Speed: 5})
	q.push(ptzMove{Direction: "up", Step: 10, Speed: 5})
	t0 := time.Now()
	if m, ok := d.next(t0); !ok || m.Direction != "left" {
		t.Fatal(m, ok)
	}
	if _, ok := d.next(t0.Add(time.Second)); ok {
		t.Fatal("sent while one was waiting for its ack")
	}
	if !d.ack() || d.ack() {
		t.Fatal("ack")
	}
	if _, ok := d.next(t0.Add(100 * time.Millisecond)); ok {
		t.Fatal("ignored the spacing")
	}
	if m, ok := d.next(t0.Add(700 * time.Millisecond)); !ok || m.Direction != "up" {
		t.Fatal(m, ok)
	}
	if _, ok := d.expired(t0.Add(3 * time.Second)); ok {
		t.Fatal("expired early")
	}
	if m, ok := d.expired(t0.Add(5 * time.Second)); !ok || m.Direction != "up" || d.timeouts != 1 {
		t.Fatal(m, ok)
	}
}

func TestControlHandler(t *testing.T) {
	q := newPTZQueue()
	srv := httptest.NewServer(controlHandler("tok-0123456789abcdef", q))
	defer srv.Close()
	do := func(method, path, auth, body string) (int, map[string]any) {
		req, _ := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
		if auth != "" {
			req.Header.Set("Authorization", auth)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var m map[string]any
		raw, _ := io.ReadAll(resp.Body)
		json.Unmarshal(raw, &m)
		return resp.StatusCode, m
	}
	good := "Bearer tok-0123456789abcdef"
	if c, _ := do("POST", "/move", "", `{"direction":"left"}`); c != 401 {
		t.Fatal("no token", c)
	}
	if c, _ := do("POST", "/move", "Bearer wrong", `{"direction":"left"}`); c != 401 {
		t.Fatal("bad token", c)
	}
	if c, _ := do("POST", "/move", good, `{"direction":"sideways"}`); c != 400 {
		t.Fatal("bad body", c)
	}
	if c, _ := do("POST", "/move", good, `{"direction":"left"}`); c != 409 {
		t.Fatal("no session", c)
	}
	if c, _ := do("GET", "/move", good, ``); c != 405 {
		t.Fatal("GET", c)
	}
	if c, _ := do("POST", "/other", good, `{}`); c != 404 {
		t.Fatal("path", c)
	}
	q.ready.Store(true)
	c, m := do("POST", "/move", good, `{"direction":"left","step":30,"speed":7}`)
	if c != 202 || m["queued"] != true || m["dropped"].(float64) != 0 || m["step"].(float64) != 30 {
		t.Fatal(c, m)
	}
	do("POST", "/move", good, `{"direction":"up"}`)
	if c, m = do("POST", "/move", good, `{"direction":"down"}`); c != 202 || m["dropped"].(float64) != 1 || q.pending() != 2 {
		t.Fatal(c, m, q.pending())
	}
}

func TestControlAddrAndConfig(t *testing.T) {
	for _, ok := range []string{"127.0.0.1:9000", "[::1]:9000", "127.0.0.1:0"} {
		if err := validControlAddr(ok); err != nil {
			t.Error(ok, err)
		}
	}
	for _, bad := range []string{"0.0.0.0:9000", "192.0.2.5:9000", "localhost:9000", "9000", "127.0.0.1:x"} {
		if err := validControlAddr(bad); err == nil {
			t.Error("accepted", bad)
		}
	}
	e := goodEnv()
	e["CB_LAKE_CONTROL"] = "127.0.0.1:18555"
	e["CB_LAKE_CONTROL_TOKEN"] = "short"
	setEnv(t, e)
	if _, err := loadConfig(false); err == nil {
		t.Fatal("short token accepted")
	}
	e["CB_LAKE_CONTROL_TOKEN"] = "tok-0123456789abcdef"
	setEnv(t, e)
	c, err := loadConfig(false)
	if err != nil || c.control != "127.0.0.1:18555" || c.controlToken != "tok-0123456789abcdef" {
		t.Fatal(c, err)
	}
	if v, ok := lookupEnv("CB_LAKE_CONTROL_TOKEN"); ok && v != "" {
		t.Fatal("token left in the environment")
	}
}

func TestStartControlBindFailure(t *testing.T) {
	q := newPTZQueue()
	a, err := startControl(t.Context(), "127.0.0.1:0", "tok-0123456789abcdef", q)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := startControl(t.Context(), a.String(), "tok-0123456789abcdef", q); err == nil {
		t.Fatal("bound the same port twice")
	}
}

func lookupEnv(k string) (string, bool) { return os.LookupEnv(k) }
