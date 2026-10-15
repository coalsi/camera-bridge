#!/bin/sh
# Looks like `camerabridged` to Tools/nvr-soak/daemon.sh (same flags) but is the stand-in server, for rehearsals. Reads --data-dir and --port, ignores the rest.
data=""; port=""
while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir) data="$2"; shift 2 ;;
        --port) port="$2"; shift 2 ;;
        --hap-base-port|--sensors-port|--setup-token-file|--static-dir|--log-level|--recordings-dir) shift 2 ;;
        *) shift ;;
    esac
done
exec node "$(dirname "$0")/soak-fixture-main.mjs" --data "$data" --port "$port"
