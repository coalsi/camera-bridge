// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

// Pan/tilt for the Pan v4. The camera takes, on the same Agora data stream as the wake-up command, a relative move:
//
//	[{"cmd":"run_action","action":"camera-position::move-position","params":{"direction":"left","speed":5,"step":10}}]
//
// (alphabin/ClaudeWyze4Sln chatbot/cleobot.py cam_move, commit 8e63ae0; MIT). step is 1..60 per command (units unknown, not
// degrees); the camera answers on its own data stream with JSON containing "move-position" and "result":1. The gateway delivers
// that as {"_type":"on_data_stream","_message":{"uid":..,"payload":"<base64>"}}; data-stream encryption is off for HL_PAN4.
//
// Moves come in over an optional loopback HTTP server (the daemon has no stdin for us): POST /move with a bearer token.

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ptzMove is one queued move.
type ptzMove struct {
	Direction string `json:"direction"`
	Step      int    `json:"step"`
	Speed     int    `json:"speed"`
}

const (
	ptzAction     = "camera-position::move-position"
	ptzAckTimeout = 4 * time.Second
	ptzSpacing    = 600 * time.Millisecond // between commands, as the working client chunks large moves
	ptzQueueMax   = 2
)

// moveCommand is the data_stream payload for one move, in the field order the working client sends.
func moveCommand(m ptzMove) []byte {
	type params struct {
		Direction string `json:"direction"`
		Speed     int    `json:"speed"`
		Step      int    `json:"step"`
	}
	type command struct {
		Cmd    string `json:"cmd"`
		Action string `json:"action"`
		Params params `json:"params"`
	}
	b, _ := json.Marshal([]command{{Cmd: "run_action", Action: ptzAction, Params: params{m.Direction, m.Speed, m.Step}}})
	return b
}

func validDirection(d string) bool {
	switch d {
	case "left", "right", "up", "down":
		return true
	}
	return false
}

// parseMoveRequest validates a POST /move body; step defaults to 10 and speed to 5.
func parseMoveRequest(r io.Reader) (ptzMove, error) {
	var in struct {
		Direction *string `json:"direction"`
		Step      *int    `json:"step"`
		Speed     *int    `json:"speed"`
	}
	dec := json.NewDecoder(io.LimitReader(r, 1024))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&in); err != nil {
		return ptzMove{}, errors.New("body must be JSON: {\"direction\":\"left|right|up|down\",\"step\":1..60,\"speed\":1..10}")
	}
	m := ptzMove{Step: 10, Speed: 5}
	if in.Direction == nil || !validDirection(*in.Direction) {
		return ptzMove{}, errors.New("direction must be left, right, up or down")
	}
	m.Direction = *in.Direction
	if in.Step != nil {
		if *in.Step < 1 || *in.Step > 60 {
			return ptzMove{}, errors.New("step must be 1..60")
		}
		m.Step = *in.Step
	}
	if in.Speed != nil {
		if *in.Speed < 1 || *in.Speed > 10 {
			return ptzMove{}, errors.New("speed must be 1..10")
		}
		m.Speed = *in.Speed
	}
	return m, nil
}

// dataStreamReply is what we learn from one incoming data stream message.
type dataStreamReply struct {
	Action string // "camera-position::move-position" when it is a move ack
	Result int    // the "result" value; -999 when absent
	Bytes  int
}

var (
	reResult = regexp.MustCompile(`result(?:\\)*"\s*:\s*(?:\\)*"?(-?\d+)`)
	reAction = regexp.MustCompile(`[a-z0-9_-]+::[a-z0-9_-]+`)
)

// parseDataStream reads an on_data_stream frame's payload (base64 JSON; the camera's answers may be JSON-escaped inside JSON,
// so it is matched as text rather than decoded into a fixed shape).
func parseDataStream(msg object) (dataStreamReply, bool) {
	raw, err := base64.StdEncoding.DecodeString(anyString(msg["payload"]))
	if err != nil || len(raw) == 0 {
		return dataStreamReply{}, false
	}
	s := string(raw)
	r := dataStreamReply{Result: -999, Bytes: len(raw)}
	if strings.Contains(s, "move-position") {
		r.Action = ptzAction
	} else if a := reAction.FindString(s); a != "" {
		r.Action = a
	}
	if m := reResult.FindStringSubmatch(s); m != nil {
		r.Result, _ = strconv.Atoi(m[1])
	}
	return r, true
}

// ptzQueue holds at most ptzQueueMax moves; a new move beyond that drops the oldest. It never blocks.
type ptzQueue struct {
	mu     sync.Mutex
	moves  []ptzMove
	notify chan struct{}
	ready  atomic.Bool // a session is up and the camera has joined
}

func newPTZQueue() *ptzQueue { return &ptzQueue{notify: make(chan struct{}, 1)} }

// push queues a move; it returns how many older moves were dropped.
func (q *ptzQueue) push(m ptzMove) int {
	q.mu.Lock()
	q.moves = append(q.moves, m)
	dropped := 0
	if len(q.moves) > ptzQueueMax {
		dropped = len(q.moves) - ptzQueueMax
		q.moves = append([]ptzMove(nil), q.moves[dropped:]...)
	}
	q.mu.Unlock()
	select {
	case q.notify <- struct{}{}:
	default:
	}
	return dropped
}

func (q *ptzQueue) pop() (ptzMove, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.moves) == 0 {
		return ptzMove{}, false
	}
	m := q.moves[0]
	q.moves = q.moves[1:]
	return m, true
}

func (q *ptzQueue) pending() int { q.mu.Lock(); defer q.mu.Unlock(); return len(q.moves) }

// controlHandler is the HTTP API: POST /move only.
func controlHandler(token string, q *ptzQueue) http.Handler {
	want := []byte("Bearer " + token)
	reply := func(w http.ResponseWriter, code int, v any) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(code)
		json.NewEncoder(w).Encode(v)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/move" {
			reply(w, http.StatusNotFound, object{"error": "not found"})
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			reply(w, http.StatusMethodNotAllowed, object{"error": "POST only"})
			return
		}
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), want) != 1 {
			reply(w, http.StatusUnauthorized, object{"error": "bad token"})
			return
		}
		m, err := parseMoveRequest(r.Body)
		if err != nil {
			reply(w, http.StatusBadRequest, object{"error": err.Error()})
			return
		}
		if !q.ready.Load() {
			reply(w, http.StatusConflict, object{"error": "no camera session yet"})
			return
		}
		dropped := q.push(m)
		reply(w, http.StatusAccepted, object{"queued": true, "dropped": dropped, "direction": m.Direction, "step": m.Step, "speed": m.Speed})
	})
}

// startControl listens on addr (loopback only) and serves the control API until ctx ends.
func startControl(ctx context.Context, addr, token string, q *ptzQueue) (net.Addr, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	srv := &http.Server{Handler: controlHandler(token, q), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 10 * time.Second, MaxHeaderBytes: 8 << 10, ErrorLog: log.New(io.Discard, "", 0)}
	go srv.Serve(ln)
	go func() {
		<-ctx.Done()
		srv.Close()
	}()
	return ln.Addr(), nil
}

// validControlAddr accepts only loopback host:port.
func validControlAddr(a string) error {
	host, port, err := net.SplitHostPort(a)
	if err != nil {
		return fmt.Errorf("CB_LAKE_CONTROL must be 127.0.0.1:<port>: %v", err)
	}
	if p, err := strconv.Atoi(port); err != nil || p < 0 || p > 65535 {
		return errors.New("CB_LAKE_CONTROL: bad port")
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return errors.New("CB_LAKE_CONTROL must be a loopback address (127.0.0.1:<port> or [::1]:<port>)")
	}
	return nil
}

// ptzDriver sends queued moves one at a time: the next waits for the camera's ack (or ptzAckTimeout) and ptzSpacing.
type ptzDriver struct {
	q        *ptzQueue
	inFlight *ptzMove
	sentAt   time.Time
	acks     uint64
	timeouts uint64
}

// next returns the move to send now, if any.
func (d *ptzDriver) next(now time.Time) (ptzMove, bool) {
	if d.inFlight != nil || now.Sub(d.sentAt) < ptzSpacing {
		return ptzMove{}, false
	}
	m, ok := d.q.pop()
	if !ok {
		return ptzMove{}, false
	}
	d.inFlight, d.sentAt = &m, now
	return m, true
}

// ack consumes a move ack; it returns false if no move was waiting.
func (d *ptzDriver) ack() bool {
	if d.inFlight == nil {
		return false
	}
	d.inFlight = nil
	d.acks++
	return true
}

// expired reports a move whose ack did not come within ptzAckTimeout (and forgets it).
func (d *ptzDriver) expired(now time.Time) (ptzMove, bool) {
	if d.inFlight == nil || now.Sub(d.sentAt) < ptzAckTimeout {
		return ptzMove{}, false
	}
	m := *d.inFlight
	d.inFlight = nil
	d.timeouts++
	return m, true
}
