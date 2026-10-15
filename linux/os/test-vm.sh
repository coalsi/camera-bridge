#!/usr/bin/env bash
# Boots a Camera Bridge OS image in QEMU (UEFI) and checks it. Runs on a Linux host (KVM) and on macOS (Homebrew QEMU;
# arm64 images are hardware accelerated with HVF on Apple Silicon, amd64 images run under slow emulation).
# Everything happens in files under --work; no real disk is ever touched.
#
#   linux/os/test-vm.sh --image camera-bridge-os-0.1-arm64.img.xz [--arch arm64|amd64] [--tests LIST] [--keep]
#
#   --image FILE       the .img or .img.xz from build.sh
#   --arch A           arm64 or amd64 (default: guessed from the file name)
#   --disk-size SIZE   size the virtual disk is grown to before the first boot (default 32G; tests the first-boot growth). The nvr tests
#                      need it: recording keeps 8 GiB free and the size cap is the partition minus 2 x 8 GiB, so a 16G disk holds nothing.
#   --cpus N           virtual CPUs (default 2). The nvr tests encode the demo camera's 1080p picture in software: give it 4 if the host has them.
#   --seed-files N     nvr-archive: recordings in the seeded archive (default 2000; the check of start-up time is the same with 50)
#   --burst-from W     nvr: where the 40 simultaneous requests come from: host, guest or auto (default). QEMU's user-mode port forwarding, the
#                      only way this script reaches the box, resets connections that arrive together on a macOS host (40 at once lose 12 to 16,
#                      two at once lose one). guest runs the burst inside the box over ssh, on its own loopback, with the box's python3, and
#                      leaves the burst out of conformance.mjs; host sends it from this computer. auto: guest on macOS, host elsewhere.
#   --tests LIST       comma separated subset of: boot,ssh-off,system,persist,daemon,nvr,nvr-archive,nvr-faults,requests,factory-reset,wifi,recording-drive,
#                      installer,install-boot,update (default: all but update). update needs --update-dir. daemon and the three nvr tests need an image
#                      with the real camerabridged (they are skipped for --stub-daemon). nvr, nvr-archive and nvr-faults are documented in
#                      docs/linux/BUILDING.md; their web client is linux/os/test-nvr.py.
#   --update-dir DIR   release files (SHA256SUMS, SHA256SUMS.sig, cb-os_*) of a NEWER version, built with the same --pubkey as the
#                      image; served from a fake "GitHub API" on the host. See docs/linux/BUILDING.md ("Testing updates").
#   --broken-dir DIR   (optional, with the update test) release files of a still newer version whose daemon never starts:
#                      the box must fall back to the previous version by itself after three failed boots
#   --boot-timeout S   seconds to wait for the web UI after power-on (default 300 accelerated, 1800 emulated)
#   --work DIR         scratch folder (default: a new temporary folder; deleted unless --keep)
#   --keep             keep the scratch folder (disks, logs)
#   --leave-running    for debugging: after the selected tests leave the VM running and print the ssh command (stop it with kill)
#
# The VM gets an SSH key through a systemd credential (SMBIOS / fw_cfg), which the image turns into "SSH enabled".
# Exit status 0 only if every selected test passed.
# shellcheck disable=SC2001,SC2012,SC2015,SC2016,SC2029,SC2054
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

image="" arch="" disk_size=32G cpus=2 seed_files=2000 burst_from=auto tests="" update_dir="" broken_dir="" boot_timeout="" work="" keep=0 leave=0
http_port=18080 ssh_port=12222 api_port=18090
box_web_port=80   # the port the daemon listens on inside the box (http_port on the host is forwarded to it)

while [ $# -gt 0 ]; do
    case $1 in
        --image) image=$2; shift ;;
        --arch) arch=$2; shift ;;
        --disk-size) disk_size=$2; shift ;;
        --cpus) cpus=$2; shift ;;
        --seed-files) seed_files=$2; shift ;;
        --burst-from) burst_from=$2; shift ;;
        --tests) tests=$2; shift ;;
        --update-dir) update_dir=$2; shift ;;
        --broken-dir) broken_dir=$2; shift ;;
        --boot-timeout) boot_timeout=$2; shift ;;
        --work) work=$2; shift ;;
        --keep) keep=1 ;;
        --leave-running) leave=1; keep=1 ;;
        -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "error: $*" >&2; exit 1; }
[ -n "$image" ] && [ -f "$image" ] || die "--image FILE is required"
if [ -z "$arch" ]; then
    case $image in *arm64*) arch=arm64 ;; *amd64*) arch=amd64 ;; *) die "cannot tell the architecture from the file name; use --arch" ;; esac
fi
[ -n "$tests" ] || tests="boot,ssh-off,system,persist,daemon,nvr,nvr-archive,nvr-faults,requests,factory-reset,wifi,recording-drive,installer,install-boot"
case $seed_files in ''|*[!0-9]*) die "--seed-files must be a number" ;; esac
case $cpus in ''|*[!0-9]*) die "--cpus must be a number" ;; esac
for tool in qemu-img curl ssh ssh-keygen; do command -v "$tool" >/dev/null || die "$tool is required"; done

host_os=$(uname -s)
host_arch=$(uname -m)
case $burst_from in
    auto) if [ "$host_os" = Darwin ]; then burst_from=guest; else burst_from=host; fi ;;
    host|guest) ;;
    *) die "--burst-from must be host, guest or auto" ;;
esac
case $arch in
    amd64) qemu="qemu-system-x86_64" ;;
    arm64) qemu="qemu-system-aarch64" ;;
    *) die "unknown architecture $arch" ;;
esac
command -v "$qemu" >/dev/null || die "$qemu is required"

# --- accelerator ----------------------------------------------------------------------------------------------------------
accel=tcg
if [ "$host_os" = Linux ] && [ -w /dev/kvm ]; then
    case "$arch:$host_arch" in amd64:x86_64|arm64:aarch64|arm64:arm64) accel=kvm ;; esac
elif [ "$host_os" = Darwin ] && [ "$arch" = arm64 ] && [ "$host_arch" = arm64 ]; then
    accel=hvf
fi
if [ -z "$boot_timeout" ]; then
    if [ "$accel" = tcg ]; then boot_timeout=1800; else boot_timeout=300; fi
fi
echo "QEMU: $qemu, accelerator: $accel, web UI wait limit: ${boot_timeout}s"

# --- firmware (UEFI) ------------------------------------------------------------------------------------------------------
fw_code="" fw_vars_template=""
find_first() { local f; for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
if [ "$arch" = amd64 ]; then
    fw_code=$(find_first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-x86_64-code.fd) || die "no x86-64 UEFI firmware (apt install ovmf)"
    fw_vars_template=$(find_first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /opt/homebrew/share/qemu/edk2-i386-vars.fd /usr/local/share/qemu/edk2-i386-vars.fd) || die "no UEFI variable store template"
else
    fw_code=$(find_first /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
        /opt/homebrew/share/qemu/edk2-aarch64-code.fd /usr/local/share/qemu/edk2-aarch64-code.fd) || die "no arm64 UEFI firmware (apt install qemu-efi-aarch64)"
    fw_vars_template=$(find_first /usr/share/AAVMF/AAVMF_VARS.fd /opt/homebrew/share/qemu/edk2-arm-vars.fd /usr/local/share/qemu/edk2-arm-vars.fd) \
        || fw_vars_template=""
fi

# --- scratch space --------------------------------------------------------------------------------------------------------
if [ -z "$work" ]; then work=$(mktemp -d "${TMPDIR:-/tmp}/cb-os-vm.XXXXXX"); fi
mkdir -p "$work"
work=$(cd "$work" && pwd)
# Only ever remove files this script itself creates (the folder may have been given by the user).
rm -f "$work"/disk.raw "$work"/target.raw "$work"/vars.fd "$work"/id_ed25519 "$work"/id_ed25519.pub "$work"/cred.txt \
    "$work"/serial.log "$work"/qemu.log "$work"/status.json
rm -rf "$work"/nvr
qemu_pid=""
api_pid=""
ctl_path="/tmp/cbvm-$$.ctl"   # kept short: unix socket paths are limited to ~100 characters
kill_qemu_pidfile() {
    # the pid file is the authority: qemu_pid can be stale after a failed restart
    local p
    p=$(cat "$work/qemu.pid" 2>/dev/null || true)
    [ -z "$p" ] || kill "$p" 2>/dev/null || true
}
cleanup() {
    if [ "$leave" -eq 1 ] && [ -n "$qemu_pid" ]; then
        echo "VM left running (pid $qemu_pid). Log in with:"
        echo "  ssh -i $work/id_ed25519 -p $ssh_port -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1"
        echo "Stop it with: kill $qemu_pid"
        return
    fi
    ssh -O exit -o "ControlPath=$ctl_path" root@127.0.0.1 2>/dev/null || true
    rm -f "$ctl_path"
    [ -z "$qemu_pid" ] || kill "$qemu_pid" 2>/dev/null || true
    kill_qemu_pidfile
    [ -z "$api_pid" ] || kill "$api_pid" 2>/dev/null || true
    if [ "$keep" -eq 0 ]; then rm -rf "$work"; else echo "kept: $work"; fi
}
trap cleanup EXIT

# A VM left over from an earlier run would answer on our forwarded ports and make every result meaningless.
if curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$http_port/"; then die "something already answers on port $http_port (a leftover VM? stop it first)"; fi
if (exec 3<>"/dev/tcp/127.0.0.1/$ssh_port") 2>/dev/null; then die "something already listens on port $ssh_port (a leftover VM? stop it first)"; fi

echo "==> preparing the disk ($disk_size)"
case $image in
    *.xz) xz -dc "$image" >"$work/disk.raw" ;;
    *) cp "$image" "$work/disk.raw" ;;
esac
qemu-img resize -f raw "$work/disk.raw" "$disk_size" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C cb-os-test -f "$work/id_ed25519"
cp "$work/id_ed25519.pub" "$work/cred.txt"

# --- running the VM -------------------------------------------------------------------------------------------------------
pass=0 failed=0
ok() { echo "  ok    $*"; pass=$((pass + 1)); }
no() { echo "  FAIL  $*"; failed=$((failed + 1)); }

fresh_vars() {
    if [ -n "$fw_vars_template" ]; then cp "$fw_vars_template" "$work/vars.fd"; else dd if=/dev/zero of="$work/vars.fd" bs=1m count=64 2>/dev/null || dd if=/dev/zero of="$work/vars.fd" bs=1M count=64 2>/dev/null; fi
}

# start_vm CREDENTIALS(yes|no) DISK...   (disks are raw files; the first is the boot disk)
start_vm() {
    local creds=$1; shift
    local args=() i=0 d
    case $arch in
        amd64) args+=(-machine "q35,accel=$accel" -cpu max) ;;
        arm64) if [ "$accel" = tcg ]; then args+=(-machine virt -cpu max); else args+=(-machine "virt,accel=$accel" -cpu host); fi ;;
    esac
    args+=(-smp "$cpus" -m 2048 -display none -serial "file:$work/serial.log")
    args+=(-drive "if=pflash,format=raw,unit=0,file=$fw_code,readonly=on")
    args+=(-drive "if=pflash,format=raw,unit=1,file=$work/vars.fd")
    for d in "$@"; do
        args+=(-drive "file=$d,if=none,id=disk$i,format=raw,cache=unsafe" -device "virtio-blk-pci,drive=disk$i,serial=cbtest$i,bootindex=$((i + 1))")
        i=$((i + 1))
    done
    args+=(-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$http_port-:80,hostfwd=tcp:127.0.0.1:$ssh_port-:22" -device virtio-net-pci,netdev=net0)
    args+=(-device virtio-rng-pci)
    if [ "$creds" = yes ]; then
        args+=(-smbios "type=11,value=io.systemd.credential:cb.ssh.authorized_keys=$(cat "$work/id_ed25519.pub")")
        args+=(-fw_cfg "name=opt/io.systemd.credentials/cb.ssh.authorized_keys,file=$work/cred.txt")
    fi
    : >"$work/serial.log"
    rm -f "$work/qemu.pid"
    "$qemu" "${args[@]}" -pidfile "$work/qemu.pid" >"$work/qemu.log" 2>&1 &
    qemu_pid=$!
}

stop_vm() {
    # Ask politely over SSH when possible, otherwise just cut the power (the data partition is journaled).
    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        ssh_run 'systemctl poweroff' >/dev/null 2>&1 || true
        rm -f "$ctl_path"
        local n
        for ((n = 0; n < 30; n++)); do kill -0 "$qemu_pid" 2>/dev/null || break; sleep 1; done
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    kill_qemu_pidfile
    qemu_pid=""
}

ssh_opts() {
    # One multiplexed connection: the firewall rate-limits new SSH connections (and a test makes hundreds of calls).
    printf '%s\n' -o ControlMaster=auto -o "ControlPath=$ctl_path" -o ControlPersist=120 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=5 \
        -o LogLevel=ERROR -o BatchMode=yes -i "$work/id_ed25519" -p "$ssh_port"
}
ssh_run() {
    local opts=()
    while IFS= read -r o; do opts+=("$o"); done < <(ssh_opts)
    ssh "${opts[@]}" root@127.0.0.1 "$@"
}

# ssh_has COMMAND PATTERN: runs COMMAND on the VM, succeeds if its output matches PATTERN (grep -E). Captures the output
# first: "ssh | grep -q" would kill ssh with SIGPIPE and fail under pipefail.
ssh_has() {
    local out
    out=$(ssh_run "$1" 2>&1) || true
    grep -Eq -- "$2" <<<"$out"
}

wait_http() {
    # wait_http SECONDS: polls the status endpoint every 3 s; returns 0 when it answers.
    local n max=$(($1 / 3))
    for ((n = 0; n < max; n++)); do
        if curl -fsS --max-time 4 "http://127.0.0.1:$http_port/api/v1/status" >"$work/status.json" 2>/dev/null; then return 0; fi
        kill -0 "$qemu_pid" 2>/dev/null || { echo "  (QEMU exited)"; return 1; }
        sleep 3
    done
    return 1
}

wait_ssh() {
    local n
    for ((n = 0; n < 40; n++)); do
        if [ "$(ssh_run 'echo up' 2>/dev/null)" = "up" ]; then return 0; fi
        sleep 3
    done
    return 1
}

dump_serial() { echo "  --- last serial output ---"; tail -40 "$work/serial.log" | sed 's/^/  | /'; }

selected() { case ",$tests," in *",$1,"*) return 0 ;; esac; return 1; }

# --- helpers of the nvr tests (their web client is test-nvr.py; docs/linux/BUILDING.md describes the tests) ---------------------
nvr_dir="$work/nvr" nvr_ready=0 admin_pw=""
rec=/var/lib/camera-bridge/recordings

ensure_admin_pw() { [ -n "$admin_pw" ] || admin_pw=$(openssl rand -hex 16); }

is_stub_daemon() { ssh_has 'test -e /usr/bin/camerabridged && grep -q "^#!/usr/bin/python3" /usr/bin/camerabridged && echo stub' '^stub$'; }

# nvr_phase PHASE [ARGS...]: runs one phase of test-nvr.py against the forwarded web port; its "ok  " and "FAIL " lines become results here.
nvr_phase() {
    local line before=$failed
    ensure_admin_pw
    mkdir -p "$nvr_dir"
    rm -f "$nvr_dir/rc"
    while IFS= read -r line; do
        case $line in
            "ok  "*) ok "${line#ok  }" ;;
            "FAIL "*) no "${line#FAIL }" ;;
            *) echo "        $line" ;;
        esac
    done < <(CB_TEST_PASSWORD="$admin_pw" python3 -I "$HERE/test-nvr.py" "$@" --base "http://127.0.0.1:$http_port" --dir "$nvr_dir" 2>&1; echo "$?" >"$nvr_dir/rc")
    [ "$(cat "$nvr_dir/rc" 2>/dev/null || echo 1)" -eq 0 ] || [ "$failed" -gt "$before" ] || no "test-nvr.py $1 failed without saying why (see the lines above)"
}

# nvr_state KEY: a value test-nvr.py keeps between phases (the camera's id).
nvr_state() { python3 -I "$HERE/test-nvr.py" state --key "$1" --dir "$nvr_dir"; }

# nvr_burst: the 40 simultaneous requests (phase burst). The only way this script reaches the box is QEMU's user-mode port forwarding, and on a
# macOS host that resets connections which arrive together (measured on the arm64 image: 40 health requests at once lose 12 to 16, two at once
# lose one, 300 one after the other lose none). With --burst-from guest (the default on macOS) the same test-nvr.py therefore runs inside the box,
# on the box's own loopback, with the box's python3 (/usr/bin/python3 is there: Debian's systemd-ukify depends on it), and what it prints is
# read as for any phase. With --burst-from host (the default elsewhere) the phase runs here, as it always did. The session (cookie and CSRF token
# of this run's throw-away box) is copied into the box's /tmp for the length of the phase and removed again.
nvr_burst() {
    if [ "${burst_from:-host}" = host ]; then nvr_phase burst; return; fi
    local line rc=1 before=$failed
    echo "        (the burst runs inside the box: QEMU's user-mode port forwarding resets connections that arrive together on this host)"
    if ! ssh_has 'command -v python3 >/dev/null && echo yes' '^yes$'; then
        no "the burst cannot run inside the box: it has no python3 (--burst-from host sends it from this computer instead)"
        return
    fi
    rm -rf "$nvr_dir/inside"
    mkdir -p "$nvr_dir/inside"
    cp "$HERE/test-nvr.py" "$nvr_dir/inside/test-nvr.py"
    cp "$nvr_dir/state.json" "$nvr_dir/inside/state.json"
    if ! tar --format=ustar -C "$nvr_dir/inside" -cf - test-nvr.py state.json | ssh_run 'rm -rf /tmp/nvr-inside; mkdir -m 700 /tmp/nvr-inside && tar -C /tmp/nvr-inside -xf -'; then
        rm -rf "$nvr_dir/inside"
        no "the burst cannot run inside the box: test-nvr.py could not be copied there"
        return
    fi
    rm -rf "$nvr_dir/inside"
    while IFS= read -r line; do
        case $line in
            "ok  "*) ok "${line#ok  }" ;;
            "FAIL "*) no "${line#FAIL }" ;;
            "rc="[0-9]*) rc=${line#rc=} ;;
            *) echo "        $line" ;;
        esac
    done < <(ssh_run "cd /tmp/nvr-inside && python3 -I test-nvr.py burst --base http://127.0.0.1:${box_web_port:-80} --dir /tmp/nvr-inside --inside-box 2>&1; echo rc=\$?")
    ssh_run 'rm -rf /tmp/nvr-inside' || true
    [ "$rc" -eq 0 ] || [ "$failed" -gt "$before" ] || no "test-nvr.py burst (inside the box) failed without saying why (see the lines above)"
}

# nvr_setup: sign in, add the demo camera, choose the folder, switch Record on and wait for 20 s of video. Once per run.
nvr_setup() {
    [ "$nvr_ready" -eq 0 ] || return 0
    nvr_ready=1
    nvr_phase session
    nvr_phase add-camera
    nvr_phase folder-required
    nvr_phase choose-folder
    nvr_phase record-on --seconds 20
}

# nvr_decode FILE LABEL: the box's own ffmpeg decodes what the API served (init segment + fragments, as the browser would append them).
nvr_decode() {
    local out streams frames before=$failed
    ssh_run 'cat >/tmp/nvr-served.mp4' <"$1"
    out=$(ssh_run 'ffmpeg -v error -i /tmp/nvr-served.mp4 -f null - 2>&1; echo "status=$?"' || true)
    if [ "$out" = "status=0" ]; then ok "ffmpeg on the box decodes $2 without a message"; else no "ffmpeg on the box reported on $2: $(echo "$out" | head -3 | tr '\n' '|')"; fi
    streams=$(ssh_run "ffprobe -v error -show_entries stream=codec_name,codec_type -of csv=p=0 /tmp/nvr-served.mp4 2>/dev/null | tr ',' '\\n' | sort | tr '\\n' ' '" || true)
    if [ "$streams" = "h264 video " ]; then ok "$2 holds one stream: h264 video"; else no "$2 holds these streams: ${streams:-none}"; fi
    frames=$(ssh_run 'ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 /tmp/nvr-served.mp4 2>/dev/null' || true)
    case $frames in ''|*[!0-9]*) no "$2: ffprobe counted \"$frames\" frames" ;; *) if [ "$frames" -ge 10 ]; then ok "$2 has $frames frames"; else no "$2 has only $frames frames"; fi ;; esac
    ssh_run 'rm -f /tmp/nvr-served.mp4' || true
    if [ "$failed" -gt "$before" ]; then mkdir -p "$nvr_dir/diag"; cp "$1" "$nvr_dir/diag/failed-$(basename "$1")"; fi   # test pattern video, no secret: kept for the owner of the muxer
}

# nvr_seconds ACTION: runs `systemctl ACTION camerabridged` on the box (Type=notify: it returns when the daemon said READY=1) and prints
# how many seconds that took.
nvr_seconds() {
    local started=$SECONDS
    ssh_run "systemctl $1 camerabridged" >/dev/null 2>&1 || true
    echo $((SECONDS - started))
}

# nvr_diag LABEL: what a person needs to understand a failed run without the VM (CI uploads the folder).
nvr_diag() {
    mkdir -p "$nvr_dir/diag"
    ssh_run 'journalctl -u camerabridged --no-pager -o short-iso | tail -n 500' >"$nvr_dir/diag/$1-journal.txt" 2>&1 || true
    ssh_run 'uptime; df -h /srv; free -m; systemctl status camerabridged --no-pager | head -n 20; ls -lR /var/lib/camera-bridge/recordings | head -n 150' >"$nvr_dir/diag/$1-box.txt" 2>&1 || true
}

# nvr_journal_lines: lines the daemon has logged in this boot.
nvr_journal_lines() { ssh_run 'journalctl -u camerabridged -b --no-pager -o cat | wc -l' | tr -d ' '; }


# --- the update test ------------------------------------------------------------------------------------------------------

# Release folder -> version (from cb-os_<version>_<arch>.efi).
dir_version() {
    local f
    f=$(ls "$1"/cb-os_*_"$arch".efi 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    basename "$f" | sed -e 's/^cb-os_//' -e "s/_$arch\\.efi\$//"
}

write_api_config() {
    # write_api_config CORRUPT DIR...   (CORRUPT: none|sig|efi)
    local corrupt=$1; shift
    python3 - "$work/api.json" "$corrupt" "$arch" "$@" <<'PY'
import json, os, sys
out, corrupt, arch, *dirs = sys.argv[1:]
releases = []
for d in dirs:
    efi = [f for f in os.listdir(d) if f.endswith("_%s.efi" % arch)][0]
    version = efi[len("cb-os_"):-len("_%s.efi" % arch)]
    releases.append({"tag": "os-v" + version, "dir": os.path.abspath(d)})
json.dump({"corrupt": corrupt, "releases": releases}, open(out, "w"))
PY
}

start_api() {
    cat >"$work/api.py" <<'PY'
import http.server, json, os, sys
CONFIG, PORT = sys.argv[1], int(sys.argv[2])

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/octet-stream"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        cfg = json.load(open(CONFIG))
        path = self.path.split("?")[0]
        host = self.headers.get("Host", "10.0.2.2:%d" % PORT)
        if path.endswith("/releases"):
            out = []
            for r in cfg["releases"]:
                assets = []
                for name in sorted(os.listdir(r["dir"])):
                    if os.path.isfile(os.path.join(r["dir"], name)):
                        assets.append({"name": name, "size": os.path.getsize(os.path.join(r["dir"], name)),
                                       "browser_download_url": "http://%s/dl/%s/%s" % (host, r["tag"], name)})
                out.append({"tag_name": r["tag"], "draft": False, "prerelease": False,
                            "html_url": "http://%s/release/%s" % (host, r["tag"]), "body": "test release", "assets": assets})
            return self.send(200, json.dumps(out).encode(), "application/json")
        if path.startswith("/dl/"):
            _, _, tag, name = path.split("/", 3)
            for r in cfg["releases"]:
                if r["tag"] == tag:
                    p = os.path.join(r["dir"], os.path.basename(name))
                    if os.path.isfile(p):
                        data = open(p, "rb").read()
                        c = cfg.get("corrupt", "none")
                        if c == "sig" and name == "SHA256SUMS.sig":
                            # flip a byte of the base64 signature on line 2 (line 1 is an unsigned comment)
                            i = data.index(b"\n") + 20
                            data = data[:i] + (b"A" if data[i:i + 1] != b"A" else b"B") + data[i + 1:]
                        if c == "efi" and name.endswith(".efi"):
                            data = bytes([data[0] ^ 0xFF]) + data[1:]
                        return self.send(200, data)
        self.send(404, b"not found")

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PY
    python3 "$work/api.py" "$work/api.json" "$api_port" >/dev/null 2>&1 &
    api_pid=$!
}

reboot_vm() {
    ssh_run 'systemctl reboot' >/dev/null 2>&1 || true
    rm -f "$ctl_path"
    sleep 12
}

run_update_test() {
    local v1 v2 v3="" status n versions="" ver esp before_esp c
    v2=$(dir_version "$update_dir") || { no "no cb-os_*_$arch.efi in $update_dir"; return; }
    if [ -n "$broken_dir" ]; then v3=$(dir_version "$broken_dir") || { no "no cb-os_*_$arch.efi in $broken_dir"; return; }; fi
    command -v python3 >/dev/null || { no "python3 is needed for the fake update server"; return; }

    write_api_config none "$update_dir"
    start_api
    fresh_vars
    start_vm yes "$work/disk.raw"
    wait_http "$boot_timeout" && wait_ssh || { no "VM did not come up for the update test"; dump_serial; return; }
    v1=$(ssh_run '. /etc/os-release; echo $IMAGE_VERSION')
    echo "  running version $v1; update candidate $v2${v3:+; broken candidate $v3}"

    ssh_run "printf 'CB_UPDATE_API=http://10.0.2.2:$api_port\\nCB_UPDATE_ALLOW_HTTP=1\\n' > /srv/system/update.conf"
    ssh_run 'cb-update check' >/dev/null 2>&1 || true
    status=$(ssh_run 'cat /run/camera-bridge/status/update.json')
    if grep -q '"updateAvailable": *true' <<<"$status"; then ok "update check finds version $v2"; else no "update check did not find $v2: $status"; return; fi

    esp=$(ssh_run 'bootctl --print-esp-path')
    before_esp=$(ssh_run "ls $esp/EFI/Linux")
    for c in sig efi; do
        write_api_config "$c" "$update_dir"
        if ssh_run 'cb-update apply' >/dev/null 2>&1; then no "tampered update ($c) was accepted!"; else ok "tampered update ($c) is refused"; fi
        [ "$(ssh_run "ls $esp/EFI/Linux")" = "$before_esp" ] && ok "tampered update ($c) wrote nothing to the boot partition" || no "boot partition changed after a refused update ($c)"
        ssh_has 'lsblk -nro PARTLABEL /dev/vda' '^_empty$' && ok "idle root slot untouched after refused update ($c)" || no "idle root slot was modified by a refused update ($c)"
    done

    write_api_config none "$update_dir"
    echo "  (applying $v2: download, verify, write; a few minutes)"
    ssh_run 'cb-update apply' 2>&1 | tail -3 | sed 's/^/        /' || true
    status=$(ssh_run 'cat /run/camera-bridge/status/update.json')
    if grep -q '"state": *"installed"' <<<"$status"; then ok "update $v2 installed into the idle slot"; else no "update not installed: $status"; return; fi
    ssh_run "ls $esp/EFI/Linux" | sed 's/^/        /'
    ssh_has "ls $esp/EFI/Linux" "^cb-os_$v2\\+3(-0)?\\.efi\$" && ok "new boot entry has three tries (+3)" || no "new boot entry missing or without counter"
    ssh_has 'lsblk -nro PARTLABEL /dev/vda' "^cb-root_$v2\$" && ok "idle slot is now labelled cb-root_$v2" || no "slot label wrong"
    ssh_has 'lsblk -nro PARTLABEL /dev/vda' "^cb-root_$v1\$" && ok "running slot (cb-root_$v1) was not touched" || no "running slot label lost"

    reboot_vm
    wait_http "$boot_timeout" && wait_ssh || { no "no web UI after rebooting into $v2"; dump_serial; return; }
    ver=$(ssh_run '. /etc/os-release; echo $IMAGE_VERSION')
    [ "$ver" = "$v2" ] && ok "booted the new version $ver" || no "still running $ver after the update"
    ssh_has 'lsblk -nro PARTLABEL,MOUNTPOINTS /dev/vda' "cb-root_$v2 +/\$" && ok "running from the other root slot (cb-root_$v2)" || no "root slot did not switch"
    n=0
    while [ $n -lt 30 ]; do ssh_has "ls $esp/EFI/Linux" "^cb-os_$v2\\.efi\$" && break; n=$((n + 1)); sleep 2; done
    ssh_has "ls $esp/EFI/Linux" "^cb-os_$v2\\.efi\$" && ok "new version was blessed after a healthy boot (counter removed)" || no "new version was not blessed"

    if [ -n "$v3" ]; then
        echo "  (broken update $v3: the daemon never starts; expecting automatic fallback after three tries)"
        write_api_config none "$update_dir" "$broken_dir"
        ssh_run 'cb-update apply' >/dev/null 2>&1 || true
        if ssh_has 'cat /run/camera-bridge/status/update.json' '"state": *"installed"'; then ok "broken update $v3 installed"; else no "could not install $v3"; return; fi
        versions=""
        for n in 1 2 3 4 5; do
            reboot_vm
            if wait_ssh; then
                ver=$(ssh_run '. /etc/os-release; echo $IMAGE_VERSION')
                versions="$versions $ver"
                echo "        boot $n: version $ver"
            else
                versions="$versions ?"
                echo "        boot $n: no ssh"
            fi
        done
        case $versions in
            *"$v3 $v3 $v3 $v2"*) ok "rolled back to $v2 after three failed boots of $v3 (sequence:$versions)" ;;
            *) no "unexpected boot sequence:$versions" ;;
        esac
        ssh_run "ls $esp/EFI/Linux" | sed 's/^/        /'
        ssh_has "ls $esp/EFI/Linux" "^cb-os_$v3\\+0-" && ok "the bad entry is kept but marked as used up (+0-n)" || no "bad entry not marked"
    fi
    stop_vm
}

# ============================================================================================================================
echo "==> boot 1: first boot, no SSH credential"
fresh_vars
start_vm no "$work/disk.raw"
if wait_http "$boot_timeout"; then
    ok "web UI answers on port 80 (first boot, disk grown to $disk_size)"
else
    no "web UI did not answer within ${boot_timeout}s"; dump_serial; exit 1
fi
if selected ssh-off; then
    out=$(ssh_run true 2>&1 || true)
    case $out in
        *"Permission denied"*) no "SSH answered although it was never enabled" ;;
        *) ok "SSH is off by default (no answer from port 22: ${out:-no output})" ;;
    esac
fi
stop_vm

echo "==> boot 2: with an SSH credential (the image enables SSH for it)"
start_vm yes "$work/disk.raw"
wait_http "$boot_timeout" || { no "web UI did not answer on boot 2"; dump_serial; exit 1; }
wait_ssh || { no "SSH did not come up after the credential"; dump_serial; exit 1; }
ok "SSH came up through the provisioning credential"

if selected system; then
    echo "==> system checks"
    state=$(ssh_run 'systemctl is-system-running --wait' 2>&1 || true)
    [ "$state" = running ] && ok "systemd reports: running" || no "systemd reports: $state"
    failed_units=$(ssh_run 'systemctl --failed --no-legend --plain' || true)
    if [ -z "$failed_units" ]; then
        ok "no failed units"
    else
        no "failed units:"; echo "$failed_units" | sed 's/^/        /'
        for u in $(echo "$failed_units" | awk '{print $1}'); do ssh_run "journalctl -u $u -n 12 --no-pager" | sed 's/^/          | /'; done
    fi
    ssh_has 'findmnt -no OPTIONS /' '(^|,)ro(,|$)' && ok "root file system is read-only" || no "root file system is not read-only"
    ssh_has 'findmnt -no FSTYPE /var' '^tmpfs$' && ok "/var is volatile (tmpfs)" || no "/var is not a tmpfs"
    ssh_run 'findmnt /srv && findmnt /var/lib/camera-bridge && findmnt /var/log/journal' >/dev/null && ok "data partition mounted at /srv and bound to /var/lib/camera-bridge and the journal" || no "data mounts missing"
    layout=$(ssh_run 'lsblk -bnro NAME,SIZE,PARTLABEL /dev/vda')
    echo "$layout" | sed 's/^/        /'
    [ "$(echo "$layout" | grep -c .)" -eq 5 ] && ok "disk has 4 partitions" || no "unexpected number of partitions"
    echo "$layout" | grep -q '_empty$' && ok "root slot B exists and is empty" || no "root slot B missing"
    data_bytes=$(ssh_run 'lsblk -bnro SIZE,PARTLABEL /dev/vda' | awk '$2 == "cb-data" {print $1}')
    [ "${data_bytes:-0}" -gt $((4 * 1024 * 1024 * 1024)) ] && ok "data partition grew on first boot ($((data_bytes / 1048576)) MiB)" || no "data partition did not grow (${data_bytes:-?} bytes)"
    fs_bytes=$(ssh_run "df -B1 --output=size /srv | tail -1" | tr -d ' ')
    [ "${fs_bytes:-0}" -gt $((3 * 1024 * 1024 * 1024)) ] && ok "data file system grew too ($((fs_bytes / 1048576)) MiB)" || no "data file system did not grow (${fs_bytes:-?})"
    [ "$(ssh_run hostname)" = camera-bridge ] && ok "hostname is camera-bridge" || no "hostname is $(ssh_run hostname)"
    ssh_run 'grep -q "^IMAGE_VERSION=" /etc/os-release' && ok "os-release carries IMAGE_VERSION=$(ssh_run '. /etc/os-release; echo $IMAGE_VERSION')" || no "no IMAGE_VERSION"
    ssh_has 'nft list chain inet camera_bridge input' 'policy drop' && ok "firewall: inbound default-deny is active" || no "firewall policy is not drop"
    ssh_has 'nft list set inet camera_bridge ssh_port' '22' && ok "firewall: port 22 open only because SSH is enabled" || no "ssh_port set does not contain 22"
    ssh_has 'ss -ltn' ':80 ' && ok "port 80 is listening" || no "nothing listens on port 80"
    ssh_run 'systemctl show camerabridged -p User -p WatchdogUSec -p NRestarts' | tr '\n' ' ' | sed 's/^/        /'; echo
    ssh_has 'stat -c %U /proc/$(systemctl show camerabridged -p MainPID --value)' '^camerabridge$' && ok "daemon runs as camerabridge, not root" || no "daemon user check failed"
    for u in avahi-daemon chrony nftables systemd-networkd systemd-resolved camera-bridge-request.path camera-bridge-update.timer; do
        ssh_run "systemctl is-active $u" >/dev/null 2>&1 && ok "$u is active" || no "$u is not active"
    done
    ssh_has 'journalctl -u avahi-daemon --no-pager' 'camera-bridge.local' && ok "avahi publishes camera-bridge.local" || no "avahi did not announce camera-bridge.local"
    ssh_has 'ip -4 -o addr show scope global' '.' && ok "DHCP gave the box an address" || no "no IPv4 address"
    ssh_has 'swapon --show=NAME --noheadings' 'zram' && ok "swap is zram" || no "no zram swap"
    ssh_has 'swapon --show=NAME --noheadings | grep -v zram | wc -l' '^0$' && ok "no swap file or partition" || no "a non-zram swap exists"
    esp=$(ssh_run 'bootctl --print-esp-path')
    ssh_run "ls $esp/EFI/Linux" | sed 's/^/        /'
    ssh_has "ls $esp/EFI/Linux" '^cb-os_[0-9.]+\.efi$' && ok "boot entry was blessed (no boot counter left in its name)" || no "boot entry still has a boot counter (bless-boot did not run?)"
    ssh_run 'test "$(stat -c %a:%U /var/lib/camera-bridge/secrets/master.key)" = "600:camerabridge" && test "$(stat -c %s /var/lib/camera-bridge/secrets/master.key)" = 32' && ok "secrets key exists (32 bytes, 0600, owned by the daemon user)" || no "secrets key missing or wrong mode"
    ssh_run 'test -e /var/lib/camera-bridge/first-run' && ok "first-run marker exists" || no "first-run marker missing"
    ssh_run 'test "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" != x; ssh-keygen -lf /srv/system/ssh/ssh_host_ed25519_key.pub' >/dev/null 2>&1 && ok "SSH host key was generated on the box, not shipped" || no "no SSH host key"
    echo "        systemd-analyze security camerabridged: $(ssh_run 'systemd-analyze security camerabridged.service --no-pager 2>/dev/null | tail -1')"
fi

if selected persist; then
    echo "==> persistence across a reboot"
    key_before=$(ssh_run 'sha256sum /var/lib/camera-bridge/secrets/master.key | cut -d" " -f1')
    ssh_run 'echo persistent > /var/lib/camera-bridge/testfile; sync'
    ssh_run 'systemctl reboot' >/dev/null 2>&1 || true
    sleep 15
    wait_http "$boot_timeout" || { no "web UI did not come back after reboot"; dump_serial; exit 1; }
    wait_ssh || { no "ssh did not come back after reboot"; exit 1; }
    key_after=$(ssh_run 'sha256sum /var/lib/camera-bridge/secrets/master.key | cut -d" " -f1')
    [ "$key_before" = "$key_after" ] && ok "secrets key survived the reboot" || no "secrets key changed on reboot"
    [ "$(ssh_run 'cat /var/lib/camera-bridge/testfile')" = persistent ] && ok "data survived the reboot" || no "data lost on reboot"
    boots=$(ssh_run 'journalctl --list-boots --no-pager | wc -l')
    [ "$boots" -ge 2 ] && ok "the journal is persistent ($boots boots visible)" || no "journal not persistent ($boots boots)"
    ssh_run 'ls /var/log/journal | wc -l' | sed 's/^/        journal folders: /'
fi

if selected daemon; then
    echo "==> the daemon (needs an image built with the real camerabridged, not --stub-daemon)"
    if is_stub_daemon; then
        echo "  (skipped: this image has the stub daemon)"
    else
        ssh_has 'systemctl show camerabridged -p Type -p ActiveState' 'Type=notify' && ssh_has 'systemctl is-active camerabridged' '^active$' && ok "camerabridged is a Type=notify service and active" || no "camerabridged is not active (or not Type=notify)"
        ssh_has 'systemctl show camerabridged -p WatchdogUSec --value' '^30s$|^30000000$' && ok "the watchdog is armed (WatchdogSec=30)" || no "no watchdog on camerabridged"
        ssh_has 'systemctl show camerabridged -p NRestarts --value' '^0$' && ok "the daemon never restarted since boot" || no "the daemon restarted"
        ssh_has 'journalctl -u camerabridged --no-pager -o cat' 'web interface listening on port 80' && ok "the daemon listens on port 80 (CAMERABRIDGE_HTTP_PORT)" || no "the daemon did not report port 80"
        ssh_has 'journalctl -u camerabridged --no-pager -o cat' 'privileged requests go to /run/camera-bridge/requests' && ok "the daemon found the OS request folder" || no "the daemon did not find the request folder"
        # The health service only runs on a boot with a try counter (an update); run it by hand, it is the same script.
        ssh_run '/usr/lib/camera-bridge/cb-health-check' >/dev/null 2>&1 && ssh_has 'cat /run/camera-bridge/status/health.json' '"state": *"ok"' && ok "the boot health check passes with the real daemon" || no "the boot health check failed with the real daemon"
        ssh_has 'curl -fsS http://127.0.0.1/api/v1/status' '"product" *: *"Camera Bridge OS"' && ok "GET /api/v1/status answers without sign-in" || no "/api/v1/status did not answer as the contract says"
        body=$(curl -fsS --max-time 5 "http://127.0.0.1:$http_port/" 2>/dev/null || true)
        case $body in *"<title>"*Camera*) ok "the web UI is served on port 80 (through the forwarded port)" ;; *) no "the web UI page was not served" ;; esac
        # The watchdog must keep being fed: three intervals later the service is still the same process.
        pid1=$(ssh_run 'systemctl show camerabridged -p MainPID --value')
        sleep 45
        pid2=$(ssh_run 'systemctl show camerabridged -p MainPID --value')
        [ -n "$pid1" ] && [ "$pid1" = "$pid2" ] && ok "the daemon is still the same process after 45 s (the watchdog is fed)" || no "the daemon was restarted (pid $pid1 -> $pid2)"
        ssh_run 'test "$(stat -c %a:%U /var/lib/camera-bridge/secrets/master.key)" = "600:camerabridge"' && ok "the daemon left the OS-made secrets key alone" || no "the secrets key changed owner or mode"
        # Through the web API: set a password, then ask for an update check. It must reach the root helper and come back with an answer.
        cat >"$work/api-client.py" <<'PY'
import http.cookiejar, json, sys, urllib.error, urllib.request
port, password = sys.argv[1], sys.argv[2]
base = "http://127.0.0.1:%s" % port
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
csrf = ""
def call(method, path, body=None):
    headers = {"Origin": base, "Content-Type": "application/json", "X-CSRF-Token": csrf}
    data = json.dumps(body).encode() if body is not None else None
    try:
        with opener.open(urllib.request.Request(base + path, data=data, headers=headers, method=method), timeout=100) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")
code, answer = call("POST", "/api/v1/auth/setup", {"password": password})
csrf = answer.get("csrfToken", "")
print("setup", code)
code, answer = call("GET", "/api/v1/system")
print("system", code, answer.get("mode"), answer.get("canUpdate"), answer.get("canManage"), answer.get("version"), "ssh=%s" % answer.get("sshEnabled"))
code, answer = call("POST", "/api/v1/system/update", {"action": "check"})
print("check", code, answer.get("state") or answer.get("error"), "|", (answer.get("message") or "")[:160])
for wanted in (True, False):
    code, answer = call("POST", "/api/v1/system/auto-update", {"enabled": wanted})
    print("auto", wanted, code, answer.get("automaticUpdates"))
PY
        ensure_admin_pw   # the nvr tests sign in with the same password
        pw=$admin_pw
        out=$(python3 "$work/api-client.py" "$http_port" "$pw" 2>&1 || true)
        echo "$out" | sed 's/^/        /'
        grep -q '^setup 201' <<<"$out" && ok "first-run setup through the API" || no "setup through the API failed"
        grep -q '^system 200 installed True True' <<<"$out" && ok "the system page reports the OS (mode installed, can update, can manage)" || no "the system page does not see the OS"
        grep -q '^auto True 200 True' <<<"$out" && grep -q '^auto False 200 False' <<<"$out" && ok "automatic updates switched on and off through the API (the answer already shows the new state)" || no "automatic updates through the API did not work"
        grep -Eq '^check (200|409) ' <<<"$out" && ok "the update check came back (a status or the helper's own sentence)" || no "the update check did not come back"
        ssh_has 'cat /run/camera-bridge/status/update-check.json' '"state": *"(ok|failed)"' && ok "the request reached the root helper (status/update-check.json ends ok or failed)" || no "no status for the update-check request"
        ssh_has 'ls /run/camera-bridge/requests | wc -l' '^0$' && ok "the request folder is empty again (nothing left behind, no temporary files)" || no "request files were left behind"
        ssh_has 'journalctl -u camerabridged --no-pager -o cat' 'Sandbox|denied|Operation not permitted' && no "the daemon logged a sandbox or permission problem" || ok "no sandbox or permission errors in the daemon's log"
    fi
fi

if selected nvr; then
    echo "==> the NVR: record, read it back over HTTP, sound, the limits of the unit"
    if is_stub_daemon; then
        echo "  (skipped: this image has the stub daemon)"
    else
        nvr_setup
        cam=$(nvr_state camera | tr 'a-f' 'A-F')
        # What the daemon made on the data partition: as the camerabridge user, private, on the data partition itself.
        ssh_has "stat -c %U:%G:%a $rec" '^camerabridge:camerabridge:700$' && ok "the recordings folder was made by the daemon: camerabridge, mode 700" || no "the recordings folder is not camerabridge:camerabridge 700"
        [ "$(ssh_run "findmnt -no SOURCE -T $rec | sed 's/\[.*//'")" = "$(ssh_run "findmnt -no SOURCE /srv | sed 's/\[.*//'")" ] && ok "it is on the data partition" || no "the recordings folder is not on the data partition"
        [ "$(ssh_run "ls -A $rec")" = "$cam" ] && ok "it holds one folder, named after the camera's ID in upper case" || no "the recordings folder holds: $(ssh_run "ls -A $rec" | tr '\n' ' ')"
        ssh_run "jq -e --arg id '$(nvr_state camera)' '(.id | ascii_downcase) == \$id and (.name | length) > 0' $rec/$cam/camera.json" >/dev/null 2>&1 && ok "camera.json names the camera (id and name)" || no "camera.json is missing or wrong"
        [ "$(ssh_run "ls $rec/$cam | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\$' | tail -1")" = "$(ssh_run 'date -u +%F')" ] && ok "the day folder is today's date in UTC" || no "no day folder for today"
        names=$(ssh_run "find $rec/$cam -type f -name '*.mp4'")
        if [ -n "$names" ] && ! echo "$names" | grep -Evq '/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9]{2}-[0-9]{2}-[0-9]{2}(-[0-9]+)?\.mp4$'; then ok "recordings are named <day>/<HH-mm-ss>.mp4"; else no "a recording is not named <day>/<HH-mm-ss>.mp4 (or there is none)"; fi
        [ -z "$(ssh_run "find $rec \\( -type f -o -type d \\) -perm /077")" ] && ok "every file is 0600 and every folder 0700" || no "a file or folder under the recordings is readable by others"
        nvr_phase fetch
        nvr_decode "$nvr_dir/served.mp4" "the served init segment and fragments"
        nvr_phase security
        nvr_phase sound-on
        nvr_decode "$nvr_dir/served-sound.mp4" "a file with sound as served (video only)"
        lines_before=$(nvr_journal_lines)
        nvr_burst
        lines_after=$(nvr_journal_lines)
        [ $((lines_after - lines_before)) -le 10 ] && ok "100 archive requests added $((lines_after - lines_before)) lines to the daemon's log" || no "100 archive requests added $((lines_after - lines_before)) lines to the daemon's log"
        # The unit is exactly what it was: recording needed no new right.
        props=$(ssh_run 'systemctl show camerabridged -p User -p ProtectSystem -p NoNewPrivileges -p UMask -p DevicePolicy' | sort | tr '\n' ' ')
        [ "$props" = "DevicePolicy=closed NoNewPrivileges=yes ProtectSystem=strict UMask=0077 User=camerabridge " ] && ok "the unit still says: camerabridge, ProtectSystem=strict, NoNewPrivileges, UMask=0077, DevicePolicy=closed" || no "the unit's hardening changed: $props"
        [ "$(ssh_run 'systemctl show camerabridged -p ReadWritePaths --value | tr " " "\n" | sort | tr "\n" " "')" = "/run/camera-bridge/requests /var/lib/camera-bridge " ] && ok "it may write /var/lib/camera-bridge and the request folder, nothing else" || no "ReadWritePaths of the unit is: $(ssh_run 'systemctl show camerabridged -p ReadWritePaths --value')"
        exposure=$(ssh_run 'systemd-analyze security camerabridged.service --no-pager 2>/dev/null | tail -1' || true)
        echo "        $exposure"
        case $exposure in *"Overall exposure level"*) ok "systemd-analyze security still reports on camerabridged" ;; *) no "systemd-analyze security printed: $exposure" ;; esac
        # The contract checker of T07 against the real box, all its groups: the same contract read by an independent tool.
        conformance="$HERE/../web-dev/conformance.mjs"
        if [ ! -f "$conformance" ]; then
            echo "  (conformance.mjs skipped: $conformance does not exist)"
        elif ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 22 ]; then
            echo "  (conformance.mjs skipped: it needs Node 22 or newer on the host)"
        elif grep -qi '^x-cb-stand-in:' < <(curl -sS -D - -o /dev/null --max-time 5 "http://127.0.0.1:$http_port/api/v1/health" 2>/dev/null || true); then
            # test-nvr.py's FakeBox (its self-test, and the dry run of this script without a VM) answers what the phases above need, not the
            # whole contract, and says so in this header. The daemon never sends it, so on a box this branch is never taken.
            echo "  (conformance.mjs skipped on purpose: this server is the stand-in of test-nvr.py, not the daemon)"
        else
            conformance_status=0
            # Everything conformance.mjs asks, it asks one thing at a time, which a port forward carries; only its burst of 40 needs more. When the burst
            # ran inside the box (nvr_burst above), conformance.mjs leaves its own out (it reports that as skipped), so that nothing is asked of the
            # forward that it cannot do and no reset is mistaken for a finding.
            conformance_args=(--all)
            [ "${burst_from:-host}" != guest ] || conformance_args+=(--no-burst)
            CB_PASSWORD="$admin_pw" node "$conformance" "http://127.0.0.1:$http_port" "${conformance_args[@]}" >"$nvr_dir/conformance.txt" 2>&1 || conformance_status=$?
            echo "        $(tail -n 1 "$nvr_dir/conformance.txt" | cut -c1-200)"
            grep -A1 '^skip  admission' "$nvr_dir/conformance.txt" | cut -c1-200 | sed 's/^/        /' || true
            if [ "$conformance_status" -eq 0 ]; then
                ok "conformance.mjs (T07) finds the box within the contract"
            else
                no "conformance.mjs (T07) exited with $conformance_status"
                grep FAIL "$nvr_dir/conformance.txt" | head -10 | cut -c1-240 | sed 's/^/          | /'
                mkdir -p "$nvr_dir/diag"; cp "$nvr_dir/conformance.txt" "$nvr_dir/diag/conformance.txt"
            fi
        fi
        ssh_run 'journalctl -u camerabridged -b --no-pager -o short-iso' >"$nvr_dir/journal.txt" 2>&1 || true
        if grep -Eq 'Sandbox|denied|Operation not permitted|EPERM' "$nvr_dir/journal.txt"; then no "the daemon logged a sandbox or permission problem"; grep -E 'Sandbox|denied|Operation not permitted|EPERM' "$nvr_dir/journal.txt" | head -3 | cut -c1-200 | sed 's/^/          | /'; else ok "no sandbox or permission errors in the daemon's log"; fi
        nvr_phase leakscan --journal "$nvr_dir/journal.txt"
        nvr_diag nvr
    fi
fi

if selected nvr-archive; then
    echo "==> the NVR: a large archive, a torn recording, start-up, retention, a reboot"
    if is_stub_daemon; then
        echo "  (skipped: this image has the stub daemon)"
    elif [ "$seed_files" -eq 0 ]; then
        echo "  (skipped: --seed-files 0)"
    else
        nvr_setup
        nvr_phase record-off
        # Every recording is closed (has its sidecar) once Record is off. Then take the sidecars, to choose the template from.
        n=0
        while [ $n -lt 30 ] && [ "$(ssh_run "find $rec -name '*.mp4' | wc -l" | tr -d ' ')" != "$(ssh_run "find $rec -name '*.cbidx' | wc -l" | tr -d ' ')" ]; do n=$((n + 1)); sleep 1; done
        [ "$(ssh_run "find $rec -name '*.mp4' | wc -l" | tr -d ' ')" = "$(ssh_run "find $rec -name '*.cbidx' | wc -l" | tr -d ' ')" ] && ok "every recording has its sidecar once Record is off ($(ssh_run "find $rec -name '*.mp4' | wc -l" | tr -d ' ') files)" || no "a recording has no sidecar 30 s after Record was switched off"
        rm -rf "$nvr_dir/closed" "$nvr_dir/seed"
        mkdir -p "$nvr_dir/closed"
        ssh_run "cd $rec && find . -name '*.cbidx' -print0 | tar --null -T - -cf -" | tar -C "$nvr_dir/closed" -xf -
        # Start-up time with the small archive of this run, then the same with the big one: the archive must not be on the way to READY=1.
        base_seconds=$(nvr_seconds restart)
        status_ok=0; curl -fsS --max-time 4 "http://127.0.0.1:$http_port/api/v1/status" >/dev/null 2>&1 && status_ok=1
        [ "$status_ok" -eq 1 ] && ok "after a restart the daemon said READY and /api/v1/status answered, $base_seconds s" || no "after a restart /api/v1/status did not answer"
        nvr_phase plan-seed --seed-files "$seed_files"
        # shellcheck disable=SC1091
        . "$nvr_dir/seed/plan.env"
        ssh_run 'systemctl stop camerabridged' >/dev/null 2>&1 || true
        ssh_run 'rm -rf /var/lib/camera-bridge/nvr-seed; runuser -u camerabridge -- mkdir -m 700 /var/lib/camera-bridge/nvr-seed'
        tar --format=ustar -C "$nvr_dir/seed" -cf - manifest.txt sidecars | ssh_run 'runuser -u camerabridge -- tar -C /var/lib/camera-bridge/nvr-seed -xf -'
        { cat "$nvr_dir/seed/plan.env"; python3 -I "$HERE/test-nvr.py" vm-script --name tear; } | ssh_run 'runuser -u camerabridge -- bash -s' | sed 's/^/        /'
        ssh_run 'cat /var/lib/camera-bridge/nvr-seed/torn-head.mp4' >"$nvr_dir/torn-head.mp4"
        sha_before=$(ssh_run 'cat /var/lib/camera-bridge/nvr-seed/torn.sha')
        { cat "$nvr_dir/seed/plan.env"; python3 -I "$HERE/test-nvr.py" vm-script --name seed; } | ssh_run 'runuser -u camerabridge -- bash -s' | sed 's/^/        /'
        [ "$(ssh_run "find $rec/$CAM_DIR -type f -name '*.mp4' | wc -l" | tr -d ' ')" -ge $((SEED_N + OLD_N + 1)) ] && ok "$SEED_N recordings, $OLD_N expired ones and a torn one are on the data partition" || no "the seeded archive is not where it should be"
        start_seconds=$(nvr_seconds start)
        ok "the daemon said READY $start_seconds s after systemctl start with the big archive (after $base_seconds s with the small one)"
        [ "$start_seconds" -le $((base_seconds + 15)) ] && ok "the archive did not delay the start (limit: the small archive's time plus 15 s)" || no "start took $start_seconds s with the big archive against $base_seconds s with the small one"
        ssh_has 'systemctl show camerabridged -p ActiveState --value' '^active$' && ok "the unit is active (Type=notify: READY=1 was sent)" || no "the unit is not active"
        worst=0
        for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
            t=$(curl -fsS -o /dev/null -w '%{time_total}' --max-time 3 "http://127.0.0.1:$http_port/api/v1/health" 2>/dev/null) || t=99
            [ "$(awk -v a="$t" -v b="$worst" 'BEGIN { print (a > b) }')" = 1 ] && worst=$t
            sleep 1
        done
        [ "$(awk -v a="$worst" 'BEGIN { print (a < 2) }')" = 1 ] && ok "/api/v1/health answered 12 times in the first 12 s, the slowest in ${worst}s, while the archive loaded" || no "/api/v1/health took ${worst}s while the archive loaded"
        nvr_phase wait-ready
        # The torn recording: cut to its last whole fragment, a new sidecar, nothing else changed.
        torn="$rec/$CAM_DIR/$TEAR_REL"
        [ "$(ssh_run "wc -c <$torn.mp4 | tr -d ' '")" = "$TEAR_KEEP" ] && ok "the torn recording was cut back to its last whole fragment ($TEAR_KEEP bytes)" || no "the torn recording is $(ssh_run "wc -c <$torn.mp4 | tr -d ' '") bytes, expected $TEAR_KEEP"
        [ "$(ssh_run "sha256sum $torn.mp4 | cut -d' ' -f1")" = "$sha_before" ] && ok "the bytes that were kept are the bytes that were recorded" || no "the repair changed the bytes it kept"
        ssh_run "cat $torn.cbidx" >"$nvr_dir/repaired.cbidx" 2>/dev/null || no "the torn recording has no sidecar after the repair"
        nvr_phase wait-oldest
        ssh_has "ls -A $rec/$CAM_DIR/$OLD_FOREIGN_DAY | tr '\n' ' '" '^00-00-01\.mp4 keep-me\.txt $' && ok "retention removed the expired recordings and left a foreign file and a link alone" || no "the expired day holds: $(ssh_run "ls -A $rec/$CAM_DIR/$OLD_FOREIGN_DAY" | tr '\n' ' ')"
        ssh_run "test -L $rec/$CAM_DIR/$OLD_FOREIGN_DAY/00-00-01.mp4 && test -f $rec/$CAM_DIR/$OLD_FOREIGN_DAY/keep-me.txt" && ok "the link and the foreign file are still what they were" || no "the link or the foreign file changed"
        ssh_run "test ! -e $rec/$CAM_DIR/$OLD_EMPTY_DAY" && ok "a day folder that became empty was removed" || no "the empty day folder is still there"
        [ "$(ssh_run "find $rec/$CAM_DIR -type f -name '*.mp4' | wc -l" | tr -d ' ')" -ge $((SEED_N + 1)) ] && ok "no recent recording was deleted (the size cap and the age rule left $SEED_N seeds alone)" || no "recent recordings are missing"
        nvr_phase verify-seed
        # Record again, then a clean reboot: everything closed before is still there, byte for byte, and Record is still on.
        nvr_phase record-on --seconds 6
        ssh_run "cd $rec/$CAM_DIR && find . -name '*.cbidx' -printf '%p %s\n' | sort" >"$nvr_dir/before.txt"
        ssh_run 'systemctl reboot' >/dev/null 2>&1 || true
        rm -f "$ctl_path"
        sleep 15
        wait_http "$boot_timeout" || { no "web UI did not come back after the reboot"; dump_serial; exit 1; }
        wait_ssh || { no "ssh did not come back after the reboot"; exit 1; }
        ssh_run "cd $rec/$CAM_DIR && find . -name '*.cbidx' -printf '%p %s\n' | sort" >"$nvr_dir/after.txt"
        [ -z "$(LC_ALL=C comm -23 <(LC_ALL=C sort "$nvr_dir/before.txt") <(LC_ALL=C sort "$nvr_dir/after.txt"))" ] && ok "after a reboot every recording that was closed before is there with the same size ($(wc -l <"$nvr_dir/before.txt" | tr -d ' ') sidecars)" || no "recordings changed or went missing across the reboot"
        nvr_phase persisted
        nvr_phase wait-recording --seconds 6
        nvr_diag nvr-archive
    fi
fi

if selected nvr-faults; then
    echo "==> the NVR: free space, the banner, and a power cut while recording"
    if is_stub_daemon; then
        echo "  (skipped: this image has the stub daemon)"
    else
        nvr_setup
        nvr_phase wait-recording --seconds 6
        total=$(ssh_run "df -B1 --output=size /srv | tail -1" | tr -d ' ')
        floor=$(( total / 20 > 8589934592 ? total / 20 : 8589934592 ))
        avail=$(ssh_run "df -B1 --output=avail /srv | tail -1" | tr -d ' ')
        files_before=$(ssh_run "find $rec -name '*.mp4' | wc -l" | tr -d ' ')
        # 3 GiB above the floor: the low-space notice. Half a GiB below it: recording pauses, and nothing is deleted to make room.
        ssh_run "fallocate -l $((avail - floor - 3221225472)) /srv/system/nvr-ballast" && ok "free space is now about 3 GiB above the floor" || no "could not fill the data partition for the low-space check"
        nvr_phase notices --expect low
        ssh_run "fallocate -l $((avail - floor + 536870912)) /srv/system/nvr-ballast" || no "could not fill the data partition any further"
        nvr_phase notices --expect full
        [ "$(ssh_run "find $rec -name '*.mp4' | wc -l" | tr -d ' ')" -ge "$files_before" ] && ok "nothing was deleted to make room" || no "recordings disappeared while the disk was full"
        ssh_run 'rm -f /srv/system/nvr-ballast'
        nvr_phase notices --expect none
        nvr_phase wait-recording --seconds 6
        # The power cut: more than 30 s into the open file, so that the recorder's fsync has run at least once.
        sleep 35
        open_file=$(ssh_run "ls -t $rec/*/*/*.mp4 | head -1")
        echo "  (power cut)"
        kill -9 "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        kill_qemu_pidfile
        qemu_pid=""
        rm -f "$ctl_path"
        start_vm yes "$work/disk.raw"
        wait_http "$boot_timeout" || { no "web UI did not come back after the power cut"; dump_serial; exit 1; }
        wait_ssh || { no "ssh did not come back after the power cut"; exit 1; }
        ok "the box came back after the power cut"
        ssh_has 'systemctl show camerabridged -p NRestarts --value' '^0$' && ok "the daemon started once and stayed up" || no "the daemon restarted after the power cut"
        nvr_phase wait-ready
        side="${open_file%.mp4}.cbidx"
        size=$(ssh_run "wc -c <$open_file | tr -d ' '")
        if ssh_run "test -f $side"; then
            ssh_run "cat $side" >"$nvr_dir/cut.cbidx"
            nvr_phase check-sidecar --file "$nvr_dir/cut.cbidx" --size "$size"
        else
            no "the recording that was open at the power cut has no sidecar after the start"
        fi
        missing=$(ssh_run 'bash -s' <<'EOS'
cd /var/lib/camera-bridge/recordings
find . -name '*.mp4' -type f -size +0 | while IFS= read -r f; do [ -f "${f%.mp4}.cbidx" ] || echo "$f"; done
EOS
)
        [ "$(echo "$missing" | grep -c .)" -le 1 ] && ok "every recording has a sidecar except at most the one being written now" || no "recordings without a sidecar after the start: $(echo "$missing" | tr '\n' ' ')"
        nvr_phase wait-recording --seconds 6
        nvr_phase fetch
        nvr_diag nvr-faults
    fi
fi

if selected requests; then
    echo "==> requests from the web UI (privilege separation)"
    ssh_run 'rm -f /run/camera-bridge/status/auto-update.json'   # the daemon test may have left a finished one
    ssh_run "runuser -u camerabridge -- sh -c 'echo {\\\"enabled\\\":true} > /run/camera-bridge/requests/auto-update.json'"
    n=0; st=""
    while [ $n -lt 20 ]; do st=$(ssh_run 'cat /run/camera-bridge/status/auto-update.json 2>/dev/null' || true); case $st in *'"ok"'*) break ;; esac; n=$((n + 1)); sleep 1; done
    case $st in *'"ok"'*) ok "auto-update request was processed" ;; *) no "auto-update request not processed ($st)" ;; esac
    ssh_run 'test -e /srv/system/auto-update' && ok "auto-update flag was set by the root helper" || no "flag missing"
    ssh_run "runuser -u camerabridge -- sh -c 'echo {} > /run/camera-bridge/requests/evil.json; ln -s /etc/shadow /run/camera-bridge/requests/reboot.json; echo not-json > /run/camera-bridge/requests/poweroff.json'"
    sleep 5
    ssh_has 'ls /run/camera-bridge/requests | wc -l' '^0$' && ok "unknown names, symlinks and non-JSON requests were discarded" || no "junk requests were left behind"
    [ "$(ssh_run 'systemctl is-system-running' || true)" = running ] && ok "junk requests did not reboot or power off the box" || no "system state changed after junk requests"
    ssh_run "runuser -u camerabridge -- sh -c 'echo {\\\"enabled\\\":false} > /run/camera-bridge/requests/auto-update.json'"
    sleep 4
    ssh_run 'test ! -e /srv/system/auto-update' && ok "auto-update switched off again" || no "auto-update flag still set"
    ssh_run 'runuser -u camerabridge -- touch /srv/system/x' 2>/dev/null && no "daemon user can write /srv/system" || ok "daemon user cannot write the system folder"
    ssh_run 'runuser -u camerabridge -- cat /srv/system/ssh/authorized_keys' 2>/dev/null && no "daemon user can read the SSH keys folder" || ok "daemon user cannot read the SSH folder"
fi

if selected factory-reset; then
    echo "==> factory reset through the marker file on the boot partition"
    key_before=$(ssh_run 'sha256sum /var/lib/camera-bridge/secrets/master.key | cut -d" " -f1')
    esp=$(ssh_run 'bootctl --print-esp-path')
    recordings_before=$(ssh_run "find $rec -type f 2>/dev/null | wc -l" | tr -d ' ')
    if selected nvr || selected nvr-archive || selected nvr-faults; then
        if is_stub_daemon; then echo "  (no recordings are expected: the stub daemon records nothing)"
        elif [ "${recordings_before:-0}" -gt 0 ]; then ok "recordings exist before the factory reset ($recordings_before files)"
        else no "the nvr tests left no recordings to erase"; fi
    fi
    ssh_run "echo keepme > /var/lib/camera-bridge/testfile; touch $esp/camera-bridge-factory-reset; sync; systemctl reboot" >/dev/null 2>&1 || true
    sleep 15
    wait_http "$boot_timeout" || { no "web UI did not come back after the reset"; dump_serial; exit 1; }
    wait_ssh || { no "ssh did not come back after the reset"; exit 1; }
    ssh_run 'test ! -e /var/lib/camera-bridge/testfile' && ok "settings were erased" || no "settings survived the factory reset"
    [ "$(ssh_run "find $rec -mindepth 1 2>/dev/null | wc -l" | tr -d ' ')" = 0 ] && ok "recordings were erased too (the folder is empty or gone)" || no "recordings survived the factory reset"
    ssh_run "test ! -e $esp/camera-bridge-factory-reset" && ok "marker file was removed (no reset loop)" || no "marker file still there"
    key_after=$(ssh_run 'sha256sum /var/lib/camera-bridge/secrets/master.key | cut -d" " -f1')
    [ "$key_before" != "$key_after" ] && ok "a new secrets key was generated" || no "secrets key unchanged"
    ssh_run 'test -e /var/lib/camera-bridge/first-run' && ok "first-run marker is back" || no "first-run marker missing after reset"
fi

if selected wifi; then
    echo "==> Wi-Fi: saved networks, the Wi-Fi file on the boot partition, the setup hotspot (two simulated radios)"
    ssh_has 'systemctl is-active NetworkManager' '^active' && ok "NetworkManager runs" || no "NetworkManager is not running"
    ssh_has 'cat /run/camera-bridge/status/wifi.json' '"(online|searching|no-wifi)"' && ok "the Wi-Fi watcher reports a state" || no "no Wi-Fi state was written"
    ssh_has 'cat /run/camera-bridge/status/wifi.json' '"state": *"hotspot"' && no "a hotspot opened although a network cable is in" || ok "with a network cable no hotspot opens"
    if ssh_run 'modprobe mac80211_hwsim radios=2' >/dev/null 2>&1; then
        for _ in $(seq 1 20); do ssh_has 'nmcli -t -f TYPE,STATE device' '^wifi:(disconnected|unavailable)' && break; sleep 1; done
        ssh_run 'nmcli -t -f DEVICE,TYPE,STATE device' | sed 's/^/        /'
        esp=$(ssh_run 'bootctl --print-esp-path')
        ssh_run "printf 'network=TestNet\\r\\npassword=sesame-12345\\r\\n' > '$esp/Camera-Bridge-WiFi.TXT' && systemctl restart camera-bridge-wifi-import" || true
        ssh_has "ls '$esp'" 'Camera-Bridge-WiFi' && no "the Wi-Fi file is still on the boot partition" || ok "the Wi-Fi file was read and deleted"
        ssh_has 'nmcli -t -f NAME connection show' '^TestNet$' && ok "the network in the file was saved" || no "the network in the file was not saved"
        ssh_has 'journalctl --no-pager -b | grep -c sesame-12345' '^0$' && ok "the password never reached the log" || no "the Wi-Fi password is in the log!"
        ssh_run 'cb-wifi --forget TestNet; rm -f /srv/system/wifi-pending' >/dev/null 2>&1 || true
        ssh_run 'systemctl stop camera-bridge-wifi'   # it would close the hotspot at once: the VM has a network cable
        if ssh_run 'cb-wifi --hotspot-now' >/dev/null 2>&1; then
            ok "the setup hotspot opens on the first radio"
            hotspot=$(ssh_run "jq -r '.hotspot.ssid' /run/camera-bridge/status/wifi.json")
            case $hotspot in CameraBridge-????) ok "the hotspot is called $hotspot" ;; *) no "unexpected hotspot name '$hotspot'" ;; esac
            client=$(ssh_run "nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '\$2==\"wifi\" && \$3!=\"connected\" {print \$1; exit}'")
            ssh_run "nmcli device wifi rescan ifname $client >/dev/null 2>&1; sleep 6; nmcli device wifi connect '$hotspot' ifname $client" | sed 's/^/        /' || true
            ssh_has "ip -4 addr show $client" 'inet 10\.42\.0\.' && ok "a phone (the second radio) gets an address from the hotspot" || no "the second radio got no address from the hotspot"
            ssh_has "resolvectl query -i $client captive.apple.com 2>&1" '10\.42\.0\.1' && ok "every name points at the box on the hotspot" || no "names do not point at the box"
            ssh_has "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: captive.apple.com' http://10.42.0.1/hotspot-detect.html" '^302 http://10\.42\.0\.1/setup\.html$' \
                && ok "a captive-portal check is sent to the setup page" || no "the captive-portal check is not redirected"
            ssh_has "curl -s http://10.42.0.1/api/v1/setup/wifi" "$hotspot" && ok "the setup page's API answers on the hotspot" || no "the setup API does not answer"
            ssh_has "curl -s -o /dev/null -w '%{http_code}' http://10.42.0.1/setup.html" '^200$' && ok "setup.html is served" || no "setup.html is not served"
            ssh_run "nmcli device disconnect $client; nmcli connection down id cb-setup-hotspot; nmcli connection delete id '$hotspot'" >/dev/null 2>&1 || true
        else
            no "the setup hotspot did not open on a simulated radio"
        fi
        ssh_run 'systemctl start camera-bridge-wifi; modprobe -r mac80211_hwsim' >/dev/null 2>&1 || true
    else
        no "mac80211_hwsim is not available: the Wi-Fi test cannot run"
    fi
fi

if selected recording-drive; then
    echo "==> recording drive: record to a second (virtual) disk"
    stop_vm
    qemu-img create -f raw "$work/rec.raw" 70G >/dev/null
    fresh_vars
    start_vm yes "$work/disk.raw" "$work/rec.raw"
    wait_http "$boot_timeout" && wait_ssh || { no "VM with a recording disk did not come up"; dump_serial; exit 1; }
    ssh_run 'cb-recording-drive --list' | sed 's/^/        /'
    ssh_has 'cb-recording-drive --list --json' '"name": *"vdb"' && ok "the recording drive lists the second disk" || no "the second disk is not listed"
    [ "$(ssh_run "cb-recording-drive --list --json | jq -r '.disks[] | select(.name==\"vdb\") | .eligible'")" = true ] && ok "the second disk is usable" || no "the second disk is not usable"
    ssh_has 'cb-recording-drive --list --json' '"name": *"vda"' && [ "$(ssh_run "cb-recording-drive --list --json | jq -r '.disks[] | select(.name==\"vda\") | .eligible'")" = false ] && ok "the disk the system runs from is refused" || no "the boot disk is not refused"
    before=$(ssh_run 'sfdisk -d /dev/vdb 2>&1 | sha256sum' || true)
    out=$(ssh_run 'cb-recording-drive --device /dev/vdb --confirm "yes please" 2>&1' || true)
    case $out in *"does not match"*) ok "a wrong sentence is refused" ;; *) no "a wrong sentence was not refused: $out" ;; esac
    [ "$(ssh_run 'sfdisk -d /dev/vdb 2>&1 | sha256sum')" = "$before" ] && ok "a refused choice wrote nothing" || no "a refused choice changed the disk!"
    out=$(ssh_run 'cb-recording-drive --device /dev/vda --confirm "ERASE ALL DATA ON vda" 2>&1' || true)
    case $out in *"can't be used"*) ok "the boot disk cannot be erased" ;; *) no "the boot disk was not refused: $out" ;; esac
    ssh_run 'cb-recording-drive --device /dev/vdb --confirm "ERASE ALL DATA ON vdb" 2>&1' | tail -3 | sed 's/^/        /' || true
    [ "$(ssh_run 'findmnt -no SOURCE /var/lib/camera-bridge/recordings')" = /dev/vdb1 ] && ok "the drive is mounted where the recorder writes" || no "the drive is not mounted on the recordings folder"
    ssh_has 'cat /run/camera-bridge/status/recording-drive.json' '"mounted"' && ok "the status says mounted" || no "the status does not say mounted"
    ssh_run 'runuser -u camerabridge -- sh -c "echo on-the-drive > /var/lib/camera-bridge/recordings/probe && sync"' && ok "the engine's user can write to the drive" || no "the engine's user cannot write to the drive"
    ssh_has 'findmnt -no OPTIONS /var/lib/camera-bridge/recordings' 'noexec' && ok "the drive is mounted noexec" || no "the drive is not noexec"
    ssh_has 'systemctl is-active camerabridged' 'active' && ok "the engine runs with the drive" || no "the engine is not running after the drive was chosen"
    ssh_run 'systemctl reboot' >/dev/null 2>&1 || true
    sleep 15
    wait_http "$boot_timeout" && wait_ssh || { no "the box did not come back after a reboot with a recording drive"; dump_serial; exit 1; }
    [ "$(ssh_run 'findmnt -no SOURCE /var/lib/camera-bridge/recordings')" = /dev/vdb1 ] && ok "the drive is mounted again after a reboot" || no "the drive was not mounted after a reboot"
    [ "$(ssh_run 'cat /var/lib/camera-bridge/recordings/probe')" = on-the-drive ] && ok "what was written to the drive is still there" || no "the probe file is gone"
    stop_vm
    fresh_vars
    start_vm yes "$work/disk.raw"
    wait_http "$boot_timeout" && wait_ssh || { no "the box did not come up without its recording drive"; dump_serial; exit 1; }
    [ "$(ssh_run 'findmnt -no FSTYPE /var/lib/camera-bridge/recordings')" = tmpfs ] && ok "without the drive a read-only placeholder is in its place" || no "no placeholder where the drive was"
    ssh_run 'runuser -u camerabridge -- sh -c "echo x > /var/lib/camera-bridge/recordings/nope" 2>/dev/null' && no "the engine could write without the drive" || ok "nothing can be written without the drive"
    ssh_has 'cat /run/camera-bridge/status/recording-drive.json' '"missing"' && ok "the status says the drive is missing" || no "the status does not say missing"
    stop_vm
    fresh_vars
    start_vm yes "$work/disk.raw" "$work/rec.raw"
    wait_http "$boot_timeout" && wait_ssh || { no "the box did not come up with its drive back"; dump_serial; exit 1; }
    [ "$(ssh_run 'findmnt -no SOURCE /var/lib/camera-bridge/recordings')" = /dev/vdb1 ] && ok "the drive is back in place when plugged in again" || no "the drive was not mounted again"
    ssh_run 'cb-recording-drive --forget 2>&1' | tail -2 | sed 's/^/        /' || true
    [ -z "$(ssh_run 'findmnt -no SOURCE /var/lib/camera-bridge/recordings')" ] && ok "forgetting the drive puts recording back on the box's own disk" || no "the drive is still mounted after forgetting it"
    ssh_has 'cat /run/camera-bridge/status/recording-drive.json' '"internal"' && ok "the status says internal" || no "the status does not say internal"
    # The tests after this one expect the box running from its own disk alone, as before.
    stop_vm
    fresh_vars
    start_vm yes "$work/disk.raw"
    wait_http "$boot_timeout" && wait_ssh || { no "the box did not come back after the recording drive test"; dump_serial; exit 1; }
fi

if selected installer; then
    echo "==> installer: copy the running system to a second (virtual) disk"
    ssh_run 'echo copied-by-installer > /var/lib/camera-bridge/testfile; sync'
    stop_vm
    qemu-img create -f raw "$work/target.raw" 14G >/dev/null
    start_vm yes "$work/disk.raw" "$work/target.raw"
    wait_http "$boot_timeout" && wait_ssh || { no "VM with two disks did not come up"; dump_serial; exit 1; }
    ssh_run 'cb-install-to-disk --list' | sed 's/^/        /'
    ssh_has 'cb-install-to-disk --list --json' '"eligible": *true' && ok "installer lists an eligible disk" || no "no eligible disk listed"
    out=$(ssh_run 'cb-install-to-disk --device /dev/vda --dry-run 2>&1' || true)
    case $out in *"running from"*) ok "installer refuses the boot disk" ;; *) no "installer did not refuse the boot disk: $out" ;; esac
    out=$(ssh_run 'cb-install-to-disk --device /dev/vda1 --dry-run 2>&1' || true)
    case $out in *"not a supported"*) ok "installer refuses a partition" ;; *) no "installer accepted a partition: $out" ;; esac
    before=$(ssh_run 'sfdisk -d /dev/vdb 2>&1 | sha256sum' || true)
    out=$(ssh_run 'cb-install-to-disk --device /dev/vdb --dry-run 2>&1' || true)
    case $out in *"DRY RUN"*) ok "dry run prints the plan" ;; *) no "dry run failed: $out" ;; esac
    [ "$(ssh_run 'sfdisk -d /dev/vdb 2>&1 | sha256sum')" = "$before" ] && ok "dry run wrote nothing" || no "dry run changed the disk!"
    out=$(ssh_run 'cb-install-to-disk --device /dev/vdb --confirm "yes please" 2>&1' || true)
    case $out in *"does not match"*) ok "wrong confirmation phrase is refused" ;; *) no "wrong phrase was not refused: $out" ;; esac
    [ "$(ssh_run 'sfdisk -d /dev/vdb 2>&1 | sha256sum')" = "$before" ] && ok "refused install wrote nothing" || no "refused install changed the disk!"
    out=$(ssh_run 'cb-install-to-disk --device /dev/vdb </dev/null 2>&1' || true)
    case $out in *"no confirmation given"*) ok "no terminal and no --confirm: refused" ;; *) no "install without confirmation was not refused: $out" ;; esac
    echo "  (installing for real; this copies 2.5 GB, takes a few minutes)"
    if ssh_run 'cb-install-to-disk --device /dev/vdb --copy-data --confirm "ERASE ALL DATA ON vdb" 2>&1' | tail -5 | sed 's/^/        /'; then :; fi
    ssh_run 'lsblk -nro NAME,SIZE,PARTLABEL /dev/vdb' | sed 's/^/        /'
    [ "$(ssh_run 'lsblk -nro PARTLABEL /dev/vdb | grep -c .')" -eq 4 ] && ok "target disk has the 4-partition layout" || no "target disk layout wrong"
    ssh_has 'journalctl -t cb-install-to-disk --no-pager' 'could not add a firmware boot entry' && no "the firmware boot entry could not be created" || ok "firmware boot entry was created for the new disk"
    ssh_has 'cat /run/camera-bridge/status/install-to-disk.json' '"ok"' && ok "installer reports success" || no "installer status is not ok"
    stop_vm
fi

if selected install-boot; then
    echo "==> boot from the installed disk alone"
    if [ -f "$work/target.raw" ]; then
        fresh_vars
        start_vm yes "$work/target.raw"
        if wait_http "$boot_timeout" && wait_ssh; then
            ok "the installed disk boots by itself (fallback boot path)"
            [ "$(ssh_run 'cat /var/lib/camera-bridge/testfile')" = copied-by-installer ] && ok "data was copied to the new disk" || no "copied data missing on the new disk"
            ssh_run 'findmnt -no SOURCE /srv' | sed 's/^/        data from: /'
            [ "$(ssh_run 'lsblk -bnro SIZE,PARTLABEL /dev/vda | awk "\$2==\"cb-data\"{print \$1}"')" -gt $((4 * 1024 * 1024 * 1024)) ] && ok "data partition fills the new disk" || no "data partition did not grow on the new disk"
        else
            no "installed disk did not boot"; dump_serial
        fi
        stop_vm
    else
        no "install-boot needs the installer test to run first"
    fi
fi

if selected update; then
    echo "==> A/B update from a fake GitHub (and automatic rollback)"
    if [ -z "$update_dir" ] || [ ! -d "$update_dir" ]; then
        no "--update-dir DIR is required for the update test"
    else
        run_update_test
    fi
fi

echo
echo "RESULT: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
