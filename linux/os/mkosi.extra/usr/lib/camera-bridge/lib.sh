# shellcheck shell=bash disable=SC2034
# Shared helpers for the Camera Bridge OS root-side scripts. Sourced, never executed.

CB_RUN=/run/camera-bridge
CB_STATUS=$CB_RUN/status
CB_DATA=/var/lib/camera-bridge          # the daemon's data (bind mount of /srv/camera-bridge)
CB_SYSTEM=/srv/system                   # root-owned system state: flags, SSH keys

# cb_esp: where the boot partition (ESP) is mounted. systemd-gpt-auto-generator picks /boot or /efi, so ask bootctl.
cb_esp() { bootctl --print-esp-path 2>/dev/null; }

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
