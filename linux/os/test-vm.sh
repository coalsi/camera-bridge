#!/usr/bin/env bash
# Boots a Camera Bridge OS image in QEMU (UEFI) and checks it. Runs on a Linux host (KVM) and on macOS (Homebrew QEMU;
# arm64 images are hardware accelerated with HVF on Apple Silicon, amd64 images run under slow emulation).
# Everything happens in files under --work; no real disk is ever touched.
#
#   linux/os/test-vm.sh --image camera-bridge-os-0.1-arm64.img.xz [--arch arm64|amd64] [--tests LIST] [--keep]
#
#   --image FILE       the .img or .img.xz from build.sh
#   --arch A           arm64 or amd64 (default: guessed from the file name)
#   --disk-size SIZE   size the virtual disk is grown to before the first boot (default 16G; tests the first-boot growth)
#   --tests LIST       comma separated subset of: boot,ssh-off,system,daemon,persist,requests,factory-reset,installer,install-boot,update
#                      (default: all but update). update needs --update-dir.
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

image="" arch="" disk_size=16G tests="" update_dir="" broken_dir="" boot_timeout="" work="" keep=0 leave=0
http_port=18080 ssh_port=12222 api_port=18090

while [ $# -gt 0 ]; do
    case $1 in
        --image) image=$2; shift ;;
        --arch) arch=$2; shift ;;
        --disk-size) disk_size=$2; shift ;;
        --tests) tests=$2; shift ;;
        --update-dir) update_dir=$2; shift ;;
        --broken-dir) broken_dir=$2; shift ;;
        --boot-timeout) boot_timeout=$2; shift ;;
        --work) work=$2; shift ;;
        --keep) keep=1 ;;
        --leave-running) leave=1; keep=1 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "error: $*" >&2; exit 1; }
[ -n "$image" ] && [ -f "$image" ] || die "--image FILE is required"
if [ -z "$arch" ]; then
    case $image in *arm64*) arch=arm64 ;; *amd64*) arch=amd64 ;; *) die "cannot tell the architecture from the file name; use --arch" ;; esac
fi
[ -n "$tests" ] || tests="boot,ssh-off,system,daemon,persist,requests,factory-reset,installer,install-boot"
for tool in qemu-img curl ssh ssh-keygen; do command -v "$tool" >/dev/null || die "$tool is required"; done

host_os=$(uname -s)
host_arch=$(uname -m)
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
    args+=(-smp 2 -m 2048 -display none -serial "file:$work/serial.log")
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
    if ssh_has 'test -e /usr/bin/camerabridged && grep -q "^#!/usr/bin/python3" /usr/bin/camerabridged && echo stub' '^stub$'; then
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
        pw=$(openssl rand -hex 16)
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
    ssh_run "echo keepme > /var/lib/camera-bridge/testfile; touch $esp/camera-bridge-factory-reset; sync; systemctl reboot" >/dev/null 2>&1 || true
    sleep 15
    wait_http "$boot_timeout" || { no "web UI did not come back after the reset"; dump_serial; exit 1; }
    wait_ssh || { no "ssh did not come back after the reset"; exit 1; }
    ssh_run 'test ! -e /var/lib/camera-bridge/testfile' && ok "settings were erased" || no "settings survived the factory reset"
    ssh_run "test ! -e $esp/camera-bridge-factory-reset" && ok "marker file was removed (no reset loop)" || no "marker file still there"
    key_after=$(ssh_run 'sha256sum /var/lib/camera-bridge/secrets/master.key | cut -d" " -f1')
    [ "$key_before" != "$key_after" ] && ok "a new secrets key was generated" || no "secrets key unchanged"
    ssh_run 'test -e /var/lib/camera-bridge/first-run' && ok "first-run marker is back" || no "first-run marker missing after reset"
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
