# shellcheck shell=bash disable=SC2034
# Shared helpers for the Camera Bridge OS root-side scripts. Sourced, never executed.

CB_RUN=/run/camera-bridge
CB_STATUS=$CB_RUN/status
CB_DATA=/var/lib/camera-bridge          # the daemon's data (bind mount of /srv/camera-bridge)
CB_SYSTEM=/srv/system                   # root-owned system state: flags, SSH keys
CB_HOTSPOT_FLAG=$CB_RUN/hotspot-open    # while the setup hotspot is open (cb-wifi); the internet guard's DNS waits (cb-guard)
CB_HOTSPOT_ADDRESS=10.42.0.1            # the box's address on its setup hotspot

# cb_esp: where the boot partition (ESP) is mounted. systemd-gpt-auto-generator picks /boot or /efi, so ask bootctl.
cb_esp() { bootctl --print-esp-path 2>/dev/null; }

# cb_online: the box is on a network: a default route (IPv4 or IPv6) or a global address (networkd's "routable": a camera network without a
# router counts too), Ethernet or Wi-Fi. The setup hotspot's own address is not a network.
cb_online() {
    [ -n "$(ip -4 route show default 2>/dev/null)$(ip -6 route show default 2>/dev/null)" ] && return 0
    ip -o addr show scope global -tentative 2>/dev/null | grep ' inet' | grep -vqF " $CB_HOTSPOT_ADDRESS/"
}

# cb_log MESSAGE...: to the journal (tag = $CB_TAG) and to stderr.
cb_log() {
    logger -t "${CB_TAG:-camera-bridge}" -- "$*" 2>/dev/null || true
    printf '%s\n' "$*" >&2
}

cb_die() {
    cb_log "error: $*"
    exit 1
}

# cb_status NAME STATE MESSAGE [EXTRA_JSON_OBJECT]
# Atomically writes /run/camera-bridge/status/NAME.json = {state, message, updatedAt, ...extra}.
# The web UI reads these files (world-readable); never put secrets in them.
cb_status() {
    local name=$1 state=$2 message=$3 extra=${4:-'{}'} tmp
    mkdir -p "$CB_STATUS"
    tmp=$(mktemp "$CB_STATUS/.$name.XXXXXX") || return 0
    if jq -n --arg state "$state" --arg message "$message" --argjson extra "$extra" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{state: $state, message: $message, updatedAt: $at} + $extra' >"$tmp" 2>/dev/null; then
        chmod 0644 "$tmp"
        mv -f "$tmp" "$CB_STATUS/$name.json"
    else
        rm -f "$tmp"
    fi
}

# cb_os_version: the running image version ("0.1"), from /etc/os-release IMAGE_VERSION.
cb_os_version() {
    # shellcheck disable=SC1091
    (. /etc/os-release && printf '%s' "${IMAGE_VERSION:-unknown}")
}

# cb_wipe_dir_contents DIR: removes everything inside DIR (not DIR itself), never following symlinks, staying on one file system.
cb_wipe_dir_contents() {
    local dir=$1
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
    find "$dir" -xdev -mindepth 1 -delete
}

# cb_write_file PATH MODE [GROUP [TEST_ROOT]]: stdin to PATH, atomically (a temporary file in the same folder, then mv). The group is set
# only when one is given, and left alone when TEST_ROOT is not empty (a test stands in for / and is not root).
cb_write_file() {
    local path=$1 mode=$2 group=${3:-} test_root=${4:-} tmp
    tmp=$(mktemp "$(dirname "$path")/.$(basename "$path").XXXXXX")
    if cat >"$tmp" && chmod "$mode" "$tmp" && { [ -z "$group" ] || [ -n "$test_root" ] || chgrp "$group" "$tmp"; }; then mv -f "$tmp" "$path"
    else rm -f "$tmp"; return 1; fi
}
