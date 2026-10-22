#!/bin/bash
# shellcheck disable=SC2015,SC2010,SC1112,SC2016
# Self-test of the secure address's root side: cb-tls (certificate: get, install, renew, status) and cb-tls-hook (lego's DNS hook that signs the
# website calls). lego and curl are stand-ins; no root, no systemd, no network. Needs bash, jq, openssl 3 (Ed25519), GNU date. Runs in the
# static checks job.
#
#   bash linux/os/test-tls.sh
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
X=$HERE/mkosi.extra
TLS_CMD=$X/usr/sbin/cb-tls
HOOK=$X/usr/lib/camera-bridge/cb-tls-hook
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
expect() { # expect DESCRIPTION ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; fi
}

# --- stand-ins ------------------------------------------------------------------------------------------------------------
bin=$tmp/bin
mkdir -p "$bin"
cat >"$bin/curl" <<'STUB'
#!/bin/bash
# Records the call (method, URL, headers, body) in $STUB_LOG/N.* and answers $STUB_STATUS with $STUB_BODY.
n=$(($(ls "$STUB_LOG" | grep -c '\.url$') + 1))
out=""; method=GET; body=""; : >"$STUB_LOG/$n.headers"
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift 2 ;;
        -X) method=$2; shift 2 ;;
        -H) printf '%s\n' "$2" >>"$STUB_LOG/$n.headers"; shift 2 ;;
        --data-binary) body=$2; shift 2 ;;
        -w|--max-time) shift 2 ;;
        -sS) shift ;;
        *) printf '%s' "$1" >"$STUB_LOG/$n.url"; shift ;;
    esac
done
printf '%s' "$method" >"$STUB_LOG/$n.method"
printf '%s' "$body" >"$STUB_LOG/$n.body"
printf '%s' "${STUB_BODY:-{\"ok\":true}}" >"$out"
printf '%s' "${STUB_STATUS:-200}"
STUB
cat >"$bin/lego" <<'STUB'
#!/bin/bash
# Acts like lego: records its arguments, calls the exec hook the way lego does (RAW mode), writes a certificate for --domains.
printf '%s\n' "$*" >>"$STUB_LOG/lego.args"
printf 'EXEC_MODE=%s\n' "${EXEC_MODE:-}" >>"$STUB_LOG/lego.env"
domain="" path="" action=""
while [ $# -gt 0 ]; do
    case $1 in
        --domains) domain=$2; shift 2 ;;
        --path) path=$2; shift 2 ;;
        run|renew) action=$1; shift ;;
        *) shift ;;
    esac
done
if [ -n "${FAKE_LEGO_FAIL:-}" ]; then echo "$FAKE_LEGO_FAIL" >&2; exit 1; fi
"$EXEC_PATH" present -- "_acme-challenge.$domain." "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG" || exit 1
mkdir -p "$path/certificates"
[ -n "${FAKE_LEGO_KEEP:-}" ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$path/certificates/$domain.key" \
    -out "$path/certificates/$domain.crt" -days "${FAKE_LEGO_DAYS:-89}" -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" 2>/dev/null
"$EXEC_PATH" cleanup -- "_acme-challenge.$domain." "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG" || exit 1
STUB
chmod +x "$bin/curl" "$bin/lego"
export STUB_LOG=$tmp/stub
mkdir -p "$STUB_LOG"
export PATH=$bin:$PATH
export CB_TLS_TEST_PATH=$PATH
KEY=$tmp/box.pem
openssl genpkey -algorithm ed25519 -out "$KEY" 2>/dev/null
openssl pkey -in "$KEY" -pubout -out "$tmp/box.pub" 2>/dev/null
NAME=k7f2q9
HOST=$NAME.box.camera-bridge.app

[ -x "$TLS_CMD" ] || bad "cb-tls is missing or not executable"
[ -x "$HOOK" ] || bad "cb-tls-hook is missing or not executable"

# --- the hook ---------------------------------------------------------------------------------------------------------------
state=$tmp/hookstate
mkdir -p "$state"
hook() { CB_TLS_KEY=$KEY CB_TLS_NAME=$NAME CB_TLS_STATE=$state CB_TLS_NOW=1792224000123 CB_TLS_BASE=https://www.example.test/api/v1/box bash "$HOOK" "$@"; }
calls() { local f c=0; for f in "$STUB_LOG"/*.url; do [ -e "$f" ] && c=$((c + 1)); done; echo "$c"; }
verify() { # verify N: the signature of recorded call N is valid for the message the website checks
    local n=$1 method path ts digest
    method=$(cat "$STUB_LOG/$n.method")
    path=/$(sed -E 's#^https://[^/]+/##' "$STUB_LOG/$n.url")
    ts=$(sed -n 's/^X-CB-Timestamp: //p' "$STUB_LOG/$n.headers")
    digest=$(openssl dgst -sha256 -hex <"$STUB_LOG/$n.body" | sed 's/^.* //')
    sed -n 's/^X-CB-Signature: //p' "$STUB_LOG/$n.headers" | openssl base64 -d -A >"$tmp/sig"
    printf '%s\n%s\n%s\n%s' "$method" "$path" "$ts" "$digest" >"$tmp/msg"
    openssl pkeyutl -verify -pubin -inkey "$tmp/box.pub" -rawin -in "$tmp/msg" -sigfile "$tmp/sig" >/dev/null 2>&1 && echo valid || echo invalid
}
hook present -- "_acme-challenge.$HOST." abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG
expect "present: POST /api/v1/box/acme with the value" "$(cat "$STUB_LOG/1.method") $(cat "$STUB_LOG/1.url") $(cat "$STUB_LOG/1.body")" \
    'POST https://www.example.test/api/v1/box/acme {"value":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"}'
expect "present: the name header and a millisecond timestamp" "$(grep -E '^X-CB-(Name|Timestamp):' "$STUB_LOG/1.headers" | tr '\n' ' ')" "X-CB-Name: $NAME X-CB-Timestamp: 1792224000123 "
expect "present: the signature verifies over METHOD, PATH, TIMESTAMP and the body hash" "$(verify 1)" valid
hook cleanup -- "_acme-challenge.$HOST." abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG
expect "cleanup: DELETE with an empty body" "$(cat "$STUB_LOG/2.method") [$(cat "$STUB_LOG/2.body")]" "DELETE []"
expect "cleanup: the signature verifies" "$(verify 2)" valid
expect "the timestamps only rise (the clock stood still)" "$(sed -n 's/^X-CB-Timestamp: //p' "$STUB_LOG/1.headers" "$STUB_LOG/2.headers" | tr '\n' ' ')" "1792224000123 1792224000124 "
export STUB_STATUS=503 STUB_BODY='{"error":"dns token"}'
if hook present -- x. abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG 2>/dev/null; then bad "a 503 fails the hook"; else pass "a 503 fails the hook"; fi
expect "a 503 says the service isn't ready" "$(cat "$state/last-error")" "The secure address service isn’t ready yet."
export STUB_STATUS=200 STUB_BODY='{"ok":true}'
n=$(calls)
if hook present -- x. 'short' 2>/dev/null; then bad "a value the website would refuse is not sent"; else
    expect "a value the website would refuse is not sent" "$(calls)" "$n"; fi
if grep -q 'BEGIN\|PRIVATE' <(cat "$STUB_LOG"/*.headers "$STUB_LOG"/*.body "$state"/* 2>/dev/null); then bad "no key appears in what was sent or kept"; else pass "no key appears in what was sent or kept"; fi

# --- cb-tls ------------------------------------------------------------------------------------------------------------------
root=$tmp/root
mkdir -p "$root/run/camera-bridge/status" "$root/srv/system" "$root/etc"
tls() { CB_TLS_ROOT=$root CB_TLS_HOOK=$HOOK CB_TLS_BASE=https://www.example.test/api/v1/box bash "$TLS_CMD" "$@"; }
tstatus() { jq -c "$1" "$root/run/camera-bridge/status/tls.json"; }
rm -f "$STUB_LOG"/*

expect "no certificate yet: state none" "$(tls refresh; tstatus '[.state, .host]')" '["none",null]'
tls issue --name "$NAME" --host "$HOST" --key "$KEY" >/dev/null 2>&1 && pass "issue succeeds" || bad "issue succeeds"
expect "status: ready, for the host, with an end date" "$(tstatus '[.state, .host, (.notAfter | test("^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))]')" "[\"ready\",\"$HOST\",true]"
expect "the files for the TLS front are installed" "$(ls "$root/srv/system/tls" | grep -E '^(fullchain.pem|privkey.pem|host)$' | tr '\n' ' ')" "fullchain.pem host privkey.pem "
expect "key and certificate are root-only (0600), the folder 0700" "$(stat -c %a "$root/srv/system/tls/privkey.pem" "$root/srv/system/tls/fullchain.pem" "$root/srv/system/tls" | tr '\n' ' ')" "600 600 700 "
expect "lego asked for the DNS challenge through exec, in RAW mode, for this host only" \
    "$(grep -c -- "--dns exec" "$STUB_LOG/lego.args") $(grep -c -- "--domains $HOST " "$STUB_LOG/lego.args") $(head -1 "$STUB_LOG/lego.env") $(grep -c -- ' run' "$STUB_LOG/lego.args")" "1 1 EXEC_MODE=RAW 1"
expect "lego used the Let's Encrypt directory" "$(grep -c 'acme-v02.api.letsencrypt.org/directory' "$STUB_LOG/lego.args")" 1
expect "the website was told to set and clear the challenge, both signed" "$(for m in "$STUB_LOG"/*.method; do cat "$m"; printf ' '; done)" "POST DELETE "
expect "lego's log is not left behind" "$(ls -A "$root/srv/system/tls" | grep -c '^\.lego' || true)" 0
tls issue --name "$NAME" --host "$HOST" --key "$KEY" >/dev/null 2>&1 || true
expect "a second time lego renews with 30 days" "$(tail -1 "$STUB_LOG/lego.args" | grep -c 'renew --days 30')" 1

before=$(sha256sum "$root/srv/system/tls/fullchain.pem" | cut -c1-16)
export FAKE_LEGO_FAIL='acme: error: dial tcp: lookup acme-v02.api.letsencrypt.org: no such host'
if tls issue --name "$NAME" --host "$HOST" --key "$KEY" >/dev/null 2>&1; then bad "a failed lego fails the job"; else pass "a failed lego fails the job"; fi
unset FAKE_LEGO_FAIL
expect "a failure is said in plain words, and the old certificate stays" "$(tstatus '[.state, .message]') $([ "$before" = "$(sha256sum "$root/srv/system/tls/fullchain.pem" | cut -c1-16)" ] && echo same)" \
    '["failed","The box could not reach the internet or Let’s Encrypt."] same'
expect "refresh keeps the failure but still shows the certificate's date" "$(tls refresh; tstatus '[.state, .host]')" "[\"failed\",\"$HOST\"]"
export STUB_STATUS=503 STUB_BODY='{"error":"x"}'
tls issue --name "$NAME" --host "$HOST" --key "$KEY" >/dev/null 2>&1 || true
expect "the website's own trouble is the message" "$(tstatus .message)" '"The secure address service isn’t ready yet."'
export STUB_STATUS=200 STUB_BODY='{"ok":true}'

for args in "--name K7;rm --host k7;rm.box.camera-bridge.app" "--name $NAME --host evil.example.com" "--name abc --host abc.box.camera-bridge.app"; do
    # shellcheck disable=SC2086
    if tls issue $args --key "$KEY" >/dev/null 2>&1; then bad "refused: $args"; else pass "refused: $args"; fi
done
echo "not a key" >"$tmp/bad.pem"
if tls issue --name "$NAME" --host "$HOST" --key "$tmp/bad.pem" >/dev/null 2>&1; then bad "refused: a file that is no key"; else pass "refused: a file that is no key"; fi
expect "a certificate for another name is not installed" "$(
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$tmp/o.key" -out "$tmp/o.crt" -days 5 -subj /CN=o -addext subjectAltName=DNS:other.example.com 2>/dev/null
    mkdir -p "$root/srv/system/tls/lego/certificates"; cp "$tmp/o.crt" "$root/srv/system/tls/lego/certificates/zzzz9.box.camera-bridge.app.crt"; cp "$tmp/o.key" "$root/srv/system/tls/lego/certificates/zzzz9.box.camera-bridge.app.key"
    FAKE_LEGO_KEEP=1 tls issue --name zzzz9 --host zzzz9.box.camera-bridge.app --key "$KEY" >/dev/null 2>&1 && echo installed || echo refused)" refused

# --- the wiring --------------------------------------------------------------------------------------------------------------
check() { # check DESCRIPTION COMMAND...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else bad "$desc"; fi
}
check "cb-system allows and handles the tls-obtain request" bash -c "grep -q '^ALLOWED_JOBS=\".*\\btls-obtain\\b' '$X/usr/sbin/cb-system' && grep -q 'cb-tls issue' '$X/usr/sbin/cb-system'"
check "a factory reset removes the certificate and the key" grep -q 'rm -rf "\$CB_SYSTEM/tls"' "$X/usr/sbin/cb-system"
check "the TLS front listens on 443, passes to the daemon on 127.0.0.1:80 and buffers nothing" bash -c "c='$X/etc/nginx/nginx.conf'; grep -q 'listen 443 ssl' \$c && grep -q 'proxy_pass http://127.0.0.1:80;' \$c && grep -q 'proxy_buffering off;' \$c && grep -q 'proxy_request_buffering off;' \$c && grep -q 'client_max_body_size 0;' \$c"
check "the TLS front sets the forwarded headers itself" bash -c "c='$X/etc/nginx/nginx.conf'; grep -q 'proxy_set_header X-Forwarded-For \$remote_addr;' \$c && grep -q 'proxy_set_header X-Forwarded-Proto https;' \$c"
check "nginx is inactive until a certificate exists" grep -q '^ConditionPathExists=/srv/system/tls/fullchain.pem' "$X/usr/lib/systemd/system/nginx.service.d/10-camera-bridge.conf"
check "the image has lego and nginx" bash -c "grep -Eq '^ +lego$' '$HERE/mkosi.conf' && grep -Eq '^ +nginx$' '$HERE/mkosi.conf'"

exit "$fail"
