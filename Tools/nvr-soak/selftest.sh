#!/bin/bash
# Proves that the soak's native helpers work on THIS machine before anything relies on them: the notify listener hears datagrams, and the hang shim
# really stops what Camera Bridge calls (Foundation's FileManager and FileHandle) and nothing outside its folder. Needs cc (or clang), swiftc and python3.
#   SCRATCH=<scratchpad> bash Tools/nvr-soak/selftest.sh        (prints PASS lines and exits 0, or says what failed)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -n "${SCRATCH:-}" ] && [ -d "$SCRATCH" ] || { echo "set SCRATCH to the session's scratchpad folder" >&2; exit 2; }
T="$SCRATCH/soak-selftest-$$"; mkdir -p "$T/bin" "$T/notify" "$T/shim/root"
cleanup() { case "$T" in "$SCRATCH"/soak-selftest-*) rm -rf "$T" ;; esac; }
trap cleanup EXIT
cc="$(command -v cc || command -v clang || command -v gcc)" || { echo "FAIL: no C compiler" >&2; exit 1; }
ext=so; var=LD_PRELOAD; shared="-shared -fPIC -D_GNU_SOURCE"
if [ "$(uname -s)" = Darwin ]; then ext=dylib; var=DYLD_INSERT_LIBRARIES; shared="-dynamiclib"; fi
"$cc" -O2 -Wall -o "$T/bin/notifylisten" "$HERE/notifylisten.c" || { echo "FAIL: notifylisten.c does not compile" >&2; exit 1; }
# shellcheck disable=SC2086
"$cc" -O2 -Wall $shared -o "$T/bin/hangshim.$ext" "$HERE/hangshim.c" -ldl 2>/dev/null || "$cc" -O2 -Wall $shared -o "$T/bin/hangshim.$ext" "$HERE/hangshim.c" || { echo "FAIL: hangshim.c does not compile" >&2; exit 1; }
echo "PASS: both helpers compile"

failures=0
if command -v python3 >/dev/null 2>&1; then
    ( cd "$T/notify" || exit 1; "$T/bin/notifylisten" n.sock out.jsonl & echo $! > "$T/listener.pid" )
    sleep 0.5
    ( cd "$T/notify" && python3 -I -c 'import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM); s.connect("n.sock"); s.send(b"READY=1\nSTATUS=up \"quoted\""); s.send(b"WATCHDOG=1")' )
    sleep 0.5; kill -TERM "$(cat "$T/listener.pid")"; sleep 1.2
    if grep -q '"msg": "READY=1 | STATUS=up \\"quoted\\""' "$T/notify/out.jsonl" && grep -q '"msg": "WATCHDOG=1"' "$T/notify/out.jsonl" && [ ! -e "$T/notify/n.sock" ]; then echo "PASS: the notify listener records datagrams and removes its socket"
    else echo "FAIL: the notify listener: $(cat "$T/notify/out.jsonl")"; failures=$((failures + 1)); fi
else echo "SKIP: python3 is not installed (the listener test needs it)"; fi

if command -v swiftc >/dev/null 2>&1; then
    swiftc -O -o "$T/shim/selftest" "$HERE/hangshim-selftest.swift" 2>/dev/null || { echo "FAIL: hangshim-selftest.swift does not compile" >&2; exit 1; }
    root="$(cd "$T/shim/root" && pwd -P)"
    if env CB_HANG_ROOT="$root" CB_HANG_FLAG="$T/shim/flag" CB_HANG_LOG="$T/shim/shim.log" CB_HANG_MAX_SECONDS=60 "$var=$T/bin/hangshim.$ext" "$T/shim/selftest" "$root" "$T/shim/flag" > "$T/shim/out.txt" 2>&1 \
        && grep -q blocked "$T/shim/shim.log"; then echo "PASS: the hang shim stops file calls under its folder and only there ($(grep -o 'blocked [a-z]*' "$T/shim/shim.log" | tr '\n' ' '))"
    else echo "FAIL: the hang shim self-test:"; cat "$T/shim/out.txt"; failures=$((failures + 1)); fi
else echo "SKIP: swiftc is not installed (the shim test needs it)"; fi

# The wait limit counts per call: eight threads stopped at the same time must each wait the whole limit (2 s here), not share it.
cat > "$T/capcheck.c" <<'EOC'
#include <pthread.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
static const char *path;
static double seconds[8];
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + (double)t.tv_nsec / 1e9; }
static void *work(void *arg) { long i = (long)arg; struct stat st; double t0 = now(); stat(path, &st); seconds[i] = now() - t0; return NULL; }
int main(int argc, char **argv) {
    pthread_t th[8];
    if (argc < 2) return 2;
    path = argv[1];
    for (long i = 0; i < 8; i++) pthread_create(&th[i], NULL, work, (void *)i);
    for (int i = 0; i < 8; i++) pthread_join(th[i], NULL);
    double least = seconds[0];
    for (int i = 1; i < 8; i++) if (seconds[i] < least) least = seconds[i];
    printf("%.2f\n", least);
    return 0;
}
EOC
if "$cc" -O2 -o "$T/capcheck" "$T/capcheck.c" -lpthread 2>/dev/null || "$cc" -O2 -o "$T/capcheck" "$T/capcheck.c"; then
    mkdir -p "$T/cap/root"; root="$(cd "$T/cap/root" && pwd -P)"; : > "$T/cap/flag"
    least="$(env CB_HANG_ROOT="$root" CB_HANG_FLAG="$T/cap/flag" CB_HANG_LOG="$T/cap/shim.log" CB_HANG_MAX_SECONDS=2 "$var=$T/bin/hangshim.$ext" "$T/capcheck" "$root/x" 2>/dev/null | tail -n 1)"
    if [ -n "$least" ] && awk -v v="$least" 'BEGIN { exit !(v >= 1.8 && v <= 4) }'; then echo "PASS: eight threads stopped together each wait the whole limit (shortest wait ${least} s of 2 s)"
    else echo "FAIL: the wait limit is shared between threads or not applied (shortest wait of eight threads: '${least}' s, expected about 2 s)"; failures=$((failures + 1)); fi
else echo "FAIL: capcheck.c does not compile"; failures=$((failures + 1)); fi
[ "$failures" -eq 0 ]
