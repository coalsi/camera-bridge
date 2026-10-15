#!/bin/sh
# Starts, stops and kills the daemon (and the stand-in for systemd's notify socket) of one soak run, on the machine the daemon runs on: the
# Mac itself, or inside the container through `docker exec`. All paths are the same on both sides (the run folder is mounted at its own path).
#
#   sh daemon.sh build RUN       compile notifylisten (and hangshim.dylib/.so) into RUN/bin with cc or clang
#   sh daemon.sh listen RUN      start the notify listener   (RUN/notify/n.sock -> RUN/out/notify.jsonl)
#   sh daemon.sh start RUN       start the daemon; writes RUN/daemon.pid
#   sh daemon.sh stop RUN        SIGTERM, then wait at most 20 s for it to end (exit 3 if it does not)
#   sh daemon.sh kill9 RUN       SIGKILL
#   sh daemon.sh alive RUN       exit 0 while the daemon runs
#   sh daemon.sh unlisten RUN    stop the notify listener
# RUN/daemon.env holds KEY=VALUE lines: BIN, PORT, HAP, DEV (1 or 0), WEB, DAEMON_ARGS (extra flags, no spaces inside a flag). RUN/extra.env, if it exists,
# holds more KEY=VALUE lines that are exported to the daemon only (the hang shim's LD_PRELOAD and CB_HANG_*).
set -u
action="${1:?action}"; RUN="${2:?run folder}"
[ -f "$RUN/.soak-run" ] || { echo "daemon.sh: $RUN is not a soak run (no .soak-run)" >&2; exit 2; }
pid_alive() { [ -s "$RUN/$1.pid" ] && kill -0 "$(cat "$RUN/$1.pid")" 2>/dev/null; }
compiler() { for c in cc clang gcc; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done; echo "daemon.sh: no C compiler (cc, clang or gcc)" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"

case "$action" in
    build)
        cc="$(compiler)"; mkdir -p "$RUN/bin"
        "$cc" -O2 -Wall -o "$RUN/bin/notifylisten" "$here/notifylisten.c" || exit 1
        case "$(uname -s)" in
            Darwin) "$cc" -O2 -Wall -dynamiclib -o "$RUN/bin/hangshim.dylib" "$here/hangshim.c" || exit 1 ;;
            *) "$cc" -O2 -Wall -D_GNU_SOURCE -shared -fPIC -o "$RUN/bin/hangshim.so" "$here/hangshim.c" -ldl || exit 1 ;;
        esac ;;
    listen)
        pid_alive listener && exit 0
        mkdir -p "$RUN/notify" "$RUN/out"
        cd "$RUN/notify" || exit 1
        trap '' HUP
        "$RUN/bin/notifylisten" n.sock "$RUN/out/notify.jsonl" >/dev/null 2>&1 &
        echo $! > "$RUN/listener.pid"
        i=0; while [ ! -S n.sock ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
        [ -S n.sock ] || { echo "daemon.sh: the notify socket did not appear" >&2; exit 1; } ;;
    unlisten)
        pid_alive listener && kill -TERM "$(cat "$RUN/listener.pid")" 2>/dev/null
        exit 0 ;;
    start)
        pid_alive daemon && { echo "daemon.sh: the daemon already runs" >&2; exit 1; }
        set -a; . "$RUN/daemon.env"; [ -f "$RUN/extra.env" ] && . "$RUN/extra.env"; set +a
        cd "$RUN/notify" || exit 1
        flags="--data-dir $RUN/data --port $PORT --hap-base-port $HAP --sensors-port 0 --setup-token-file $RUN/setup-token --static-dir $WEB --no-demo-camera --log-level info"
        [ "${DEV:-0}" = 1 ] && flags="--dev $flags"
        # No nohup or env in front of the daemon: on macOS every protected program (nohup, env, sh) removes DYLD_* from the environment it passes on, which
        # would silently drop the hang shim. SIGHUP is ignored by trap instead (an ignored signal stays ignored across exec).
        trap '' HUP
        # shellcheck disable=SC2086
        NOTIFY_SOCKET=n.sock WATCHDOG_USEC=30000000 "$BIN" $flags ${DAEMON_ARGS:-} >> "$RUN/out/daemon.log" 2>&1 &
        echo $! > "$RUN/daemon.pid" ;;
    stop)
        pid_alive daemon || exit 0
        pid="$(cat "$RUN/daemon.pid")"; kill -TERM "$pid" 2>/dev/null
        i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.5; i=$((i + 1)); done
        kill -0 "$pid" 2>/dev/null && { echo "daemon.sh: the daemon did not stop within 20 s" >&2; exit 3; }
        exit 0 ;;
    kill9)
        pid_alive daemon && kill -9 "$(cat "$RUN/daemon.pid")" 2>/dev/null
        exit 0 ;;
    alive) pid_alive daemon ;;
    *) echo "daemon.sh: unknown action $action" >&2; exit 2 ;;
esac
