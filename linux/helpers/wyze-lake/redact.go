// Copyright (c) 2026 Corey Silvia. MIT License (see LICENSE).

package main

import (
	"fmt"
	"log"
	"regexp"
	"sort"
	"strings"
	"sync"
)

// The redactor knows every secret this process holds (the Wyze access token, the Agora RTC token, the media key and salt and
// its RSA-wrapped form, the channel name) and blanks them out of every line it writes. Status lines are built from fixed words
// and numbers, so this is the second line of defence, not the first.
type redactor struct {
	mu      sync.RWMutex
	secrets []string
}

var secrets = &redactor{}

// add registers values that must never be printed. Values shorter than 6 characters are ignored (they would blank ordinary words).
func (r *redactor) add(values ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, v := range values {
		v = strings.TrimSpace(v)
		if len(v) < 6 {
			continue
		}
		dup := false
		for _, s := range r.secrets {
			if s == v {
				dup = true
				break
			}
		}
		if !dup {
			r.secrets = append(r.secrets, v)
		}
	}
	// Longest first, so a secret that contains another is blanked whole.
	sort.Slice(r.secrets, func(i, j int) bool { return len(r.secrets[i]) > len(r.secrets[j]) })
}

var (
	// userinfo in a URL: scheme://user:pass@host
	reUserinfo = regexp.MustCompile(`([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s"]+@`)
	// query strings and fragments: anything after ? up to whitespace or a quote
	reQuery = regexp.MustCompile(`(://[^\s"?]*)\?[^\s"]*`)
	// key=value / "key":"value" pairs whose key names a secret
	reSecretField = regexp.MustCompile(`(?i)("?\b(?:access_token|refresh_token|rtc_token|channel_key|channel_name|channel|token|key|secret|salt|aes_secret|aes_salt|encryption_key|encryption_salt|signature2|authorization|cert|ticket|password)"?\s*[:=]\s*)("[^"]*"|[^\s,}]+)`)
)

// apply returns s with every known secret, URL userinfo, URL query string and secret-named field value replaced.
func (r *redactor) apply(s string) string {
	r.mu.RLock()
	for _, v := range r.secrets {
		if strings.Contains(s, v) {
			s = strings.ReplaceAll(s, v, "***")
		}
	}
	r.mu.RUnlock()
	s = reUserinfo.ReplaceAllString(s, "${1}***@")
	s = reQuery.ReplaceAllString(s, "${1}?***")
	s = reSecretField.ReplaceAllString(s, "${1}***")
	return s
}

// redactURL drops userinfo and the query from a URL before it is logged.
func redactURL(u string) string {
	return secrets.apply(u)
}

// status writes one machine-readable line: "cb-lake event=<name> key=value ...". Values that are free text are quoted by the
// caller with q(); the daemon's parser does not understand escaped quotes, so q() removes them.
func status(format string, args ...any) {
	log.Print(secrets.apply(fmt.Sprintf("cb-lake "+format, args...)))
}

// q makes a free-text value safe for a status line: one line, no double quotes, at most 200 characters, secrets blanked.
func q(s string) string {
	s = secrets.apply(s)
	s = strings.Map(func(r rune) rune {
		switch r {
		case '"':
			return '\''
		case '\n', '\r', '\t':
			return ' '
		}
		return r
	}, s)
	if len(s) > 200 {
		s = s[:200]
	}
	return `"` + s + `"`
}
