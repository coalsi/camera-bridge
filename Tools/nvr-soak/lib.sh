#!/bin/bash
# Helpers shared by run-soak.sh. Sourced, never run. Bash 3.2 compatible (macOS).

say() { local line; line="$(date +%H:%M:%S) $*"; echo "$line"; if [ -n "${OUT:-}" ] && [ -d "${OUT:-/nonexistent}" ]; then echo "$line" >> "$OUT/run.log"; fi; }
die() { say "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required ($2)"; }
ms_now() { node -p 'Date.now()'; }
rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# wait_for SECONDS "what" command...   polls once a second; 0 as soon as the command succeeds, 1 after SECONDS (every wait has a deadline)
wait_for() {
    local limit="$1" what="$2" i=0; shift 2
    while [ "$i" -lt "$limit" ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i + 1))
    done
    say "timed out after ${limit}s waiting for $what"
    return 1
}

# Only a folder this script made may be removed by it: it must hold the .soak-run marker and sit under the scratchpad.
safe_rm_rf() {
    local path="$1" marker="${2:-$RUN}"
    [ -n "$path" ] && [ -n "${SCRATCH:-}" ] || die "safe_rm_rf: no path or no scratchpad"
    [ -f "$marker/.soak-run" ] || die "safe_rm_rf: $marker is not a soak run"
    case "$path" in "$SCRATCH"/soak/*) ;; *) die "safe_rm_rf: $path is outside $SCRATCH/soak" ;; esac
    case "$path" in *..*) die "safe_rm_rf: $path contains .." ;; esac
    rm -rf "$path"
}

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# ---- where the daemon runs: the Mac itself, or inside the container ----
on_target() { if [ "$TARGET" = container ]; then docker exec "$CONTAINER" "$@"; else "$@"; fi; }
daemon_ctl() { on_target sh "$HERE/daemon.sh" "$1" "$RUN"; }
daemon_pid() { cat "$RUN/daemon.pid" 2>/dev/null; }
daemon_alive() { daemon_ctl alive; }
api_ready() { curl -sf -m 5 "$BASE/api/v1/health" >/dev/null; }
archive_ready() { node "$SOAK/probe-once.mjs" --base "$BASE" --session "$RUN/session.json" --path /api/v1/nvr/cameras | grep -q '"status":200'; }

# The worktree is mounted read-only at its own path with --mount: OrbStack does not expose a same-path `-v SRC:SRC:ro` mount reliably (measured, section J).
container_up() {
    docker volume create "$VOLUME" >/dev/null || die "cannot create the docker volume"
    mkdir -p "$RUN/data"
    docker run -d --init --name "$CONTAINER" -p "127.0.0.1:$PORT:$PORT" -v "$RUN:$RUN" -v "$VOLUME:$RUN/data" --mount "type=bind,source=$WT,target=$WT,readonly" -v cb-linux-build:/cache:ro cb-linux-swift sleep 86400 >/dev/null \
        || die "cannot start the container (is OrbStack running? the cb-linux-swift image and cb-linux-build volume exist after 'sh Tools/linux-test.sh build')"
}
container_down() { docker rm -f "$CONTAINER" >/dev/null 2>&1; docker volume rm "$VOLUME" >/dev/null 2>&1; return 0; }

# The recordings on disk, relative paths of the mp4 files that have no sidecar (the files that were open).
list_unclosed() { on_target sh -c 'for m in "$1"/*/*/*.mp4; do [ -e "$m" ] || continue; [ -f "${m%.mp4}.cbidx" ] || echo "${m#$1/}"; done' sh "$REC"; }

# verify_tree OUTFILE [options of verify-files]: the Node tool on the Mac (full comparison), the shell tool inside the container.
verify_tree() {
    local out="$1"; shift
    if [ "$TARGET" = container ]; then on_target sh "$HERE/verify-files.sh" "$REC" "$@" > "$out"; else node "$SOAK/verify-files.mjs" --root "$REC" --json "$@" > "$out"; fi
}

# ---- the hung-volume fault injector (hangshim.c) ----
hangshim_selftest() {
    local lib dir="$RUN/shimtest" ext=so var=LD_PRELOAD
    [ "$(on_target uname -s)" = Darwin ] && { ext=dylib; var=DYLD_INSERT_LIBRARIES; }
    lib="$RUN/bin/hangshim.$ext"
    on_target mkdir -p "$dir/root"
    on_target sh -c "cd '$dir' && swiftc -O -o selftest '$HERE/hangshim-selftest.swift' 2>/dev/null" || { say "swiftc is required for the shim self-test"; return 1; }
    on_target env CB_HANG_ROOT="$dir/root" CB_HANG_FLAG="$dir/flag" CB_HANG_LOG="$dir/shim.log" CB_HANG_MAX_SECONDS=60 "$var=$lib" "$dir/selftest" "$dir/root" "$dir/flag" | tail -n 3
    on_target grep -q blocked "$dir/shim.log"
}

write_shim_env() {
    local ext=so var=LD_PRELOAD
    [ "$(on_target uname -s)" = Darwin ] && { ext=dylib; var=DYLD_INSERT_LIBRARIES; }
    { echo "$var=$RUN/bin/hangshim.$ext"; echo "CB_HANG_ROOT=$REC"; echo "CB_HANG_FLAG=$RUN/hang.flag"; echo "CB_HANG_LOG=$OUT/shim.log"; echo "CB_HANG_MAX_SECONDS=600"; } > "$RUN/extra.env"
}
