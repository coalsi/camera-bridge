#!/bin/bash
# Static checks of the Camera Bridge OS sources. No image, no VM, no hardware needed; takes about a minute.
# Runs everything inside a throw-away Debian 13 container (Docker), so the tool versions match the image.
#
#   linux/os/test-static.sh            (from the repository root or anywhere)
#
# Checks: shellcheck + bash -n on every script, the go2rtc pins (fetch-go2rtc.sh), the pins of our helpers (linux/helpers),
# the nftables ruleset (nft -c), every systemd unit (systemd-analyze verify), sysusers/tmpfiles/repart definitions, the mkosi
# configuration (mkosi summary), the stub daemon's syntax, the internet guard's DNS configuration (dnsmasq --test), the secure address's scripts and TLS front (test-tls.sh, nginx -t).
# What this does NOT prove: that the image boots (see test-vm.sh) or works on real hardware (docs/linux/BUILDING.md).
# shellcheck disable=SC2016,SC2001
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "${1:-}" != "--inside" ]; then
    command -v docker >/dev/null || { echo "Docker is required" >&2; exit 1; }
    docker build -q -f "$HERE/Dockerfile.builder" -t cb-os-builder:static "$HERE" >/dev/null
    exec docker run --rm --privileged -v "$HERE/../..":/src:ro cb-os-builder:static /src/linux/os/test-static.sh --inside
fi

OS=/src/linux/os
fail=0
pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
check() { # check DESCRIPTION COMMAND...
    local desc=$1; shift
    if out=$("$@" 2>&1); then pass "$desc"; else bad "$desc"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}

cd "$OS"
# Our own helpers' build and test scripts (linux/helpers) are checked here too: build-helpers.sh runs them for the image.
helper_scripts=(../helpers/wyze-lake/build.sh ../helpers/wyze-lake/test/run.sh
                ../helpers/eufy-bridge/build.sh ../helpers/eufy-bridge/scripts/build-inner.sh
                ../helpers/eufy-bridge/test/integration/run.sh ../helpers/eufy-bridge/test/integration/container.sh
                ../helpers/eufy-bridge/test/integration/go2rtc.sh)
scripts=(build.sh build-image.sh fetch-go2rtc.sh build-helpers.sh test-static.sh test-vm.sh mkosi.postinst.chroot mkosi.finalize stub/camerabridged-broken
         mkosi.extra/usr/sbin/cb-system mkosi.extra/usr/sbin/cb-update mkosi.extra/usr/sbin/cb-install-to-disk mkosi.extra/usr/sbin/cb-guard mkosi.extra/usr/sbin/cb-tls mkosi.extra/usr/sbin/cb-wifi test-tls.sh test-wifi.sh
         mkosi.extra/usr/lib/camera-bridge/lib.sh "${helper_scripts[@]}")
while IFS= read -r f; do scripts+=("$f"); done < <(find mkosi.extra/usr/lib/camera-bridge -name 'cb-*' -type f | sort)

for f in "${scripts[@]}"; do [ -f "$f" ] || continue; check "bash -n $f" bash -n "$f"; done
# (C.UTF-8: shellcheck cannot print the non-ASCII characters some scripts contain in the C locale)
check "shellcheck (all scripts)" env LC_ALL=C.UTF-8 shellcheck -x "${scripts[@]}"
check "stub daemon parses" python3 -c "import ast; ast.parse(open('stub/camerabridged-stub').read())"
check "scripts are executable" bash -c 'for f in build.sh build-image.sh fetch-go2rtc.sh build-helpers.sh '"${helper_scripts[*]}"' test-static.sh test-vm.sh test-tls.sh test-wifi.sh mkosi.postinst.chroot mkosi.finalize stub/camerabridged-broken mkosi.extra/usr/sbin/cb-* mkosi.extra/usr/lib/camera-bridge/cb-* stub/camerabridged-stub; do [ -x "$f" ] || { echo "not executable: $f"; exit 1; }; done'

# --- the go2rtc helper: a pinned commit, toolchain digest and checksums; installed where the engine looks ---------------------
check "fetch-go2rtc.sh pins a full commit hash" grep -Eq '^GO2RTC_COMMIT="[0-9a-f]{40}"' fetch-go2rtc.sh
check "fetch-go2rtc.sh pins a version" grep -Eq '^GO2RTC_VERSION="[0-9]+\.[0-9]+\.[0-9]+[^"]*"' fetch-go2rtc.sh
check "fetch-go2rtc.sh pins the Go image by digest" grep -Eq '^GO_IMAGE="golang:[0-9.]+[^@"]*@sha256:[0-9a-f]{64}"' fetch-go2rtc.sh
check "fetch-go2rtc.sh pins SHA-256 checksums (amd64, arm64, LICENSE)" bash -c 'for v in SHA256_AMD64 SHA256_ARM64 SHA256_LICENSE; do grep -Eq "^$v=\"[0-9a-f]{64}\"" fetch-go2rtc.sh || { echo "no 64-hex $v"; exit 1; }; done'
check "fetch-go2rtc.sh --help" ./fetch-go2rtc.sh --help
check "fetch-go2rtc.sh refuses an unknown architecture" bash -c '! ./fetch-go2rtc.sh --arch riscv64 --verify 2>/dev/null'
check "build-image.sh installs go2rtc under CB_HELPERS_DIR" grep -q 'CB_HELPERS_DIR/go2rtc' build-image.sh
# --- our own helpers (linux/helpers): toolchains pinned by digest, Node.js by version and SHA-256, the names the daemon looks for ----
LAKE=../helpers/wyze-lake EUFY=../helpers/eufy-bridge
check "wyze-lake pins a version" grep -Eq '^WYZE_LAKE_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$LAKE/pins.env"
check "wyze-lake pins the Go image by digest" grep -Eq '^GO_IMAGE=golang:[0-9.]+[^@]*@sha256:[0-9a-f]{64}$' "$LAKE/pins.env"
check "wyze-lake builds with -mod=readonly after go mod verify" bash -c 'grep -q "GOFLAGS=-mod=readonly" "$0/build.sh" && grep -q "go mod verify" "$0/build.sh"' "$LAKE"
check "wyze-lake ships its licence texts" bash -c 'for f in LICENSE NOTICE LICENSES/go-stdlib.txt; do [ -s "$0/$f" ] || { echo "no $f"; exit 1; }; done' "$LAKE"
check "eufy-bridge pins Node.js (version, tarball and binary SHA-256)" bash -c '. "$0/pins.env"; [[ $NODE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ $NODE_SHA256 =~ ^[0-9a-f]{64}$ ]] && [[ $NODE_BIN_SHA256 =~ ^[0-9a-f]{64}$ ]]' "$EUFY"
check "eufy-bridge pins the Node image by digest" grep -Eq '^NODE_IMAGE=node@sha256:[0-9a-f]{64}$' "$EUFY/pins.env"
check "eufy-bridge pins the SDK (version, full commit) and the lockfile agrees" bash -c '. "$0/pins.env"; [[ $SDK_COMMIT =~ ^[0-9a-f]{40}$ ]] && [ "$(jq -r ".packages[\"node_modules/@mega-yfue/eufy-sdk\"].version" "$0/package-lock.json")" = "$SDK_VERSION" ]' "$EUFY"
check "build-helpers.sh --help" ./build-helpers.sh --help
check "build-helpers.sh refuses an unknown architecture" bash -c '! ./build-helpers.sh --arch riscv64 --verify 2>/dev/null'
check "build-image.sh installs wyze-lake, eufy-bridge and eufy/ under CB_HELPERS_DIR" bash -c 'grep -q "CB_HELPERS_DIR/wyze-lake" build-image.sh && grep -q "CB_HELPERS_DIR/eufy-bridge" build-image.sh && grep -q "CB_HELPERS_DIR/eufy/node" build-image.sh'
check "the helpers have the names the daemon looks for" bash -c 'grep -q "program = \"eufy-bridge\"" /src/Packages/CameraBridgeKit/Sources/CameraAdapters/Integrations/Eufy/EufyBridge.swift && grep -q "\"wyze-lake\"" /src/Packages/CameraBridgeKit/Sources/CameraAdapters/Integrations/Wyze/WyzeHelperDriver.swift'
check "CB_HELPERS_DIR is a folder ProcessHelperLauncher searches" bash -c '. ./paths.env; [ -n "$CB_HELPERS_DIR" ] && grep -q "\"$CB_HELPERS_DIR\"" /src/Packages/CameraBridgeKit/Sources/PlatformLinux/System/ProcessHelperLauncher.swift'

check "systemd-sysupdate binary exists where cb-update expects it" test -x /usr/lib/systemd/systemd-sysupdate
check "sysupdate definitions are in place" test -f mkosi.extra/usr/lib/sysupdate.d/10-root.transfer -a -f mkosi.extra/usr/lib/sysupdate.d/20-uki.transfer
check "nftables ruleset parses (nft -c)" nft -c -f mkosi.extra/etc/nftables.conf
check "ruleset is default-deny inbound" grep -q 'policy drop' mkosi.extra/etc/nftables.conf
# The box is the cameras' time server: NTP (UDP 123) only from local/private addresses, in the firewall and in chrony.
check "firewall lets NTP in from local addresses only" bash -c 'f=mkosi.extra/etc/nftables.conf; grep -q "ip saddr @lan4 udp dport 123 accept" "$f" && grep -q "ip6 saddr @lan6 udp dport 123 accept" "$f" && ! grep -E "dport[^#]*\b123\b" "$f" | grep -vq "saddr @lan[46]"'
# The internet guard (Watch): DNS (port 53) only from the setup hotspot and from the watched cameras' sets, so the box is never a resolver
# for the house; nothing is logged or forwarded yet (Seal, the next stage, adds that).
check "firewall has the sets of watched cameras" bash -c 'f=mkosi.extra/etc/nftables.conf; grep -Pzq "set guarded4 \\{\\s*type ipv4_addr\\s*\\}" "$f" && grep -Pzq "set guarded6 \\{\\s*type ipv6_addr\\s*\\}" "$f"'
check "firewall lets DNS in from the watched cameras, a limited rate from each" bash -c 'f=mkosi.extra/etc/nftables.conf; for r in "ip saddr @guarded4 udp dport 53 meter guard_dns4 size 128 { ip saddr limit rate" "ip saddr @guarded4 tcp dport 53 meter guard_tcp4 size 128 { ip saddr limit rate" "ip6 saddr @guarded6 udp dport 53 meter guard_dns6 size 128 { ip6 saddr limit rate" "ip6 saddr @guarded6 tcp dport 53 meter guard_tcp6 size 128 { ip6 saddr limit rate"; do grep -qF "$r" "$f" || { echo "missing: $r"; exit 1; }; done'
check "firewall lets DNS in only from the setup hotspot on the Wi-Fi and the watched cameras" bash -c 'f=mkosi.extra/etc/nftables.conf; ! sed "s/#.*//" "$f" | grep -E "dport[^;]*\b(53|domain)\b" | grep -Ev "^\s*(iifname \"wl\*\" ip saddr 10\.42\.0\.0/24 (udp|tcp) dport 53 accept|ip saddr @guarded4 (udp|tcp) dport 53 meter [a-z0-9_]+ size [0-9]+ \{ ip saddr limit rate [0-9]+/second burst [0-9]+ packets \} accept|ip6 saddr @guarded6 (udp|tcp) dport 53 meter [a-z0-9_]+ size [0-9]+ \{ ip6 saddr limit rate [0-9]+/second burst [0-9]+ packets \} accept)$"'
check "firewall logs nothing and has no prerouting chain yet" bash -c 'f=mkosi.extra/etc/nftables.conf; ! sed "s/#.*//" "$f" | grep -Eq "\blog\b|hook prerouting"'
check "chrony serves only local and private networks, also without the internet" bash -c 'f=mkosi.extra/etc/chrony/chrony.conf; grep -Eq "^allow " "$f" && ! grep -Eq "^(allow|allow all|allow 0\.0\.0\.0/0|allow ::/0)\s*$" "$f" && ! grep -Ev "^allow (10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|169\.254\.0\.0/16|fc00::/7|fe80::/10)$" "$f" | grep -q "^allow" && grep -Eq "^local stratum [0-9]+" "$f" && ! grep -Eq "^port 0" "$f"'

# --- units: install the tree into this disposable container, render the daemon unit, ask systemd to verify -------------------
cp -a mkosi.extra/. /
# shellcheck source=paths.env
. ./paths.env
sed -e "s|@CB_DAEMON@|$CB_DAEMON|g" -e "s|@CB_WEB_ROOT@|$CB_WEB_ROOT|g" units/camerabridged.service.in >/usr/lib/systemd/system/camerabridged.service
install -D -m 0755 stub/camerabridged-stub "$CB_DAEMON"
check "rendered unit has no leftover @placeholders@" bash -c '! grep -n "@CB_" /usr/lib/systemd/system/camerabridged.service'
check "paths.env and the unit agree" grep -q "ExecStart=$CB_DAEMON" /usr/lib/systemd/system/camerabridged.service
check "a crash of the daemon prints its backtrace, never register or memory contents" bash -c 'l=$(grep "^Environment=SWIFT_BACKTRACE=" /usr/lib/systemd/system/camerabridged.service); for o in enable=yes swift-backtrace=/usr/libexec/swift/linux/swift-backtrace-static interactive=no registers=none; do grep -q "[=,]$o\(,\|$\)" <<<"$l" || { echo "missing $o"; exit 1; }; done; grep -q "swift-backtrace-static" build.sh && grep -q "/usr/libexec/swift/linux/swift-backtrace-static" build-image.sh'
groupadd -r -g 931 camerabridge 2>/dev/null || true
useradd -r -u 931 -g 931 -s /usr/sbin/nologin camerabridge 2>/dev/null || true
groupadd -r -g 932 cbupdate 2>/dev/null || true
useradd -r -u 932 -g 932 -s /usr/sbin/nologin cbupdate 2>/dev/null || true
useradd -r -s /usr/sbin/nologin _chrony 2>/dev/null || true
for g in video render; do getent group "$g" >/dev/null || groupadd -r "$g"; done

units=()
while IFS= read -r u; do units+=("$u"); done < <(cd /usr/lib/systemd/system && ls camerabridged.service camera-bridge-*.service camera-bridge-*.timer camera-bridge-*.path var-log-journal.mount 'var-lib-camera\x2dbridge.mount')
for u in "${units[@]}"; do
    case $u in camera-bridge-job@.service) target="camera-bridge-job@test.service"; cp "/usr/lib/systemd/system/$u" "/usr/lib/systemd/system/$target" ;; *) target=$u ;; esac
    # Missing units that only exist on a booted system (srv.mount from gpt-auto, efi.mount) are expected and are not errors here.
    out=$(systemd-analyze verify --man=no "/usr/lib/systemd/system/$target" 2>&1 || true)
    out=$(grep -v -E "srv\.mount|efi\.(auto)?mount|Failed to prepare filename|^$" <<<"$out" || true)
    if [ -z "$out" ]; then pass "systemd-analyze verify $u"; else bad "systemd-analyze verify $u"; sed 's/^/        /' <<<"$out"; fi
done

check "the boot waits for Ethernet or Wi-Fi with our unit; networkd's wait-online and pcrlock are masked (they left the box degraded)" bash -c '
    p=mkosi.postinst.chroot
    grep -q "^    camera-bridge-wait-online.service \\\\$" "$p" || { echo "camera-bridge-wait-online.service is not enabled"; exit 1; }
    grep -q "^systemctl mask systemd-networkd-wait-online.service$" "$p" || { echo "systemd-networkd-wait-online is not masked"; exit 1; }
    grep -q "^systemctl mask \$pcrlock_units" "$p" || { echo "the pcrlock units are not masked"; exit 1; }
    units=$(sed -n "s/^pcrlock_units=\"\(.*\)\"$/\1/p" "$p")
    for u in file-system firmware-code firmware-config machine-id make-policy secureboot-authority secureboot-policy; do
        grep -qw "systemd-pcrlock-$u.service" <<<"$units" || { echo "not in pcrlock_units: systemd-pcrlock-$u"; exit 1; }
    done
    [ ! -e mkosi.extra/usr/lib/systemd/system/systemd-networkd-wait-online.service.d ] || { echo "a drop-in for the masked unit is left"; exit 1; }'
check "cb-wait-online returns at once on a network and after its limit without one, never failing" bash -c '
    s=$(date +%s); out=$(/usr/lib/camera-bridge/cb-wait-online 5 2>&1) || { echo "failed with a route: $out"; exit 1; }; [ $(($(date +%s) - s)) -le 1 ] && grep -q "on the network" <<<"$out" || { echo "with a route: $out"; exit 1; }
    s=$(date +%s); out=$(unshare -n /usr/lib/camera-bridge/cb-wait-online 2 2>&1) || { echo "failed without a network: $out"; exit 1; }
    t=$(($(date +%s) - s)); [ "$t" -ge 2 ] && [ "$t" -le 4 ] && grep -q "no network after 2 s" <<<"$out" || { echo "without a route after $t s: $out"; exit 1; }
    s=$(date +%s); out=$(unshare -n bash -c "ip link set lo up && ip addr add 192.0.2.5/24 dev lo && /usr/lib/camera-bridge/cb-wait-online 5" 2>&1) || { echo "failed with an address: $out"; exit 1; }
    [ $(($(date +%s) - s)) -le 1 ] && grep -q "on the network" <<<"$out" || { echo "a camera network without a router is not online: $out"; exit 1; }
    ! /usr/lib/camera-bridge/cb-wait-online abc >/dev/null 2>&1 || { echo "accepted a bad limit"; exit 1; }'
check "a factory reset finishes before SSH and the guard read their settings" bash -c 'u=/usr/lib/systemd/system/camera-bridge-factory-reset.service; for s in camera-bridge-ssh camera-bridge-credentials ssh camera-bridge-guard; do grep -Eq "^Before=.*\b$s\.service\b" "$u" || { echo "not Before=: $s.service"; exit 1; }; done'

# --- the internet guard: its DNS configuration, its job, its units ------------------------------------------------------------
check "the guard's DNS configuration is valid (dnsmasq --test)" bash -c '/usr/sbin/cb-guard config >/tmp/guard-dnsmasq.conf && dnsmasq --test --conf-file=/tmp/guard-dnsmasq.conf'
check "the guard's DNS answers every name \"does not exist\" and never asks anyone" bash -c 'c=$(/usr/sbin/cb-guard config); grep -qx "address=/#/" <<<"$c" && grep -qx "no-resolv" <<<"$c" && ! grep -Eq "^(server|resolv-file|listen-address)=" <<<"$c"'
check "the guard-set request is allowed and handled" bash -c 'grep -q "^ALLOWED_JOBS=\".*\bguard-set\b" mkosi.extra/usr/sbin/cb-system && grep -q "guard-set) /usr/sbin/cb-guard set" mkosi.extra/usr/sbin/cb-system'
check "every allowed request is in the README's table" bash -c 'jobs=$(sed -n "s/^ALLOWED_JOBS=\"\(.*\)\"/\1/p" mkosi.extra/usr/sbin/cb-system); for j in $jobs; do grep -q "^| \`$j\`\|, \`$j\`" README.md || { echo "not in README.md: $j"; exit 1; }; done'
check "the guard is applied at boot" grep -q "camera-bridge-guard.service" mkosi.postinst.chroot
check "the guard's collector cannot hang with its lock" grep -Eq "^TimeoutStartSec=[0-9]+min$" /usr/lib/systemd/system/camera-bridge-guard-collect.service
check "the guard's log is read in a folder only root can change" bash -c 'grep -q "^d /run/camera-bridge/guard/work 0700 root root -" /usr/lib/tmpfiles.d/camera-bridge.conf && grep -q "^WORKDIR=\$RUN/work" /usr/sbin/cb-guard'

# --- the secure address: its certificate script and hook (test-tls.sh), the TLS front's configuration, its units -----------------------
check "the secure address's scripts pass their self-test (test-tls.sh)" bash test-tls.sh
check "the 5 GHz preference passes its self-test (test-wifi.sh)" bash test-wifi.sh
check "the TLS front's configuration is valid (nginx -t, with a throw-away certificate)" bash -c '
    d=$(mktemp -d) && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $d/k.pem -out $d/c.pem -days 1 -subj /CN=t 2>/dev/null &&
    sed -e "s|/srv/system/tls/fullchain.pem|$d/c.pem|; s|/srv/system/tls/privkey.pem|$d/k.pem|; s|^pid .*|pid $d/nginx.pid;|" mkosi.extra/etc/nginx/nginx.conf >$d/nginx.conf &&
    mkdir -p /run/nginx-tls && nginx -t -c $d/nginx.conf'
check "the certificate status is published before the daemon starts and nginx waits for a certificate" bash -c 'u=/usr/lib/systemd/system/camera-bridge-tls.service; grep -q "^Before=camerabridged.service" $u && grep -q "camera-bridge-tls.service" mkosi.postinst.chroot && grep -q "nginx.service" mkosi.postinst.chroot'

# --- sysusers / tmpfiles / repart definitions ---------------------------------------------------------------------------
tmp=$(mktemp -d)
check "sysusers.d snippet" systemd-sysusers --root="$tmp" /usr/lib/sysusers.d/camera-bridge.conf
check "tmpfiles.d snippet" systemd-tmpfiles --dry-run --create /usr/lib/tmpfiles.d/camera-bridge.conf
check "runtime repart.d (first-boot growth) is valid" systemd-repart --definitions=mkosi.extra/usr/lib/repart.d --dry-run=yes --empty=create --size=16G --seed=random "$tmp/runtime.img"
rendered=$(mktemp -d)
for f in repart/image/*.conf; do sed -e 's|@VERSION@|0.1|g' -e 's|@ROOT_SIZE@|2560M|g' "$f" >"$rendered/$(basename "$f")"; done
# the image definitions copy files from the image root; point repart at an empty fake root
fake=$(mktemp -d); mkdir -p "$fake/boot" "$fake/efi"
check "image repart definitions are valid" systemd-repart --root="$fake" --definitions="$rendered" --dry-run=yes --empty=create --size=8G --seed=random "$tmp/image.img"

# --- mkosi ---------------------------------------------------------------------------------------------------------------
check "mkosi parses the configuration (x86-64)" mkosi --directory "$OS" --architecture x86-64 --image-version 0.1 summary
check "mkosi parses the configuration (arm64)" mkosi --directory "$OS" --architecture arm64 --image-version 0.1 summary

# --- the installer's guard rails (read-only operations only) ----------------------------------------------------------------
check "cb-install-to-disk refuses to run without --device" bash -c '! mkosi.extra/usr/sbin/cb-install-to-disk 2>/dev/null'
check "cb-install-to-disk --help" mkosi.extra/usr/sbin/cb-install-to-disk --help
check "cb-install-to-disk rejects a partition name" bash -c 'out=$(mkosi.extra/usr/sbin/cb-install-to-disk --device /dev/sda1 --dry-run 2>&1); [ $? -ne 0 ] || exit 1; grep -q "not a supported whole-disk name" <<<"$out"'
check "cb-install-to-disk rejects a path outside /dev" bash -c 'out=$(mkosi.extra/usr/sbin/cb-install-to-disk --device /tmp/x --dry-run 2>&1); [ $? -ne 0 ] || exit 1; grep -q "not a supported" <<<"$out"'

rm -rf "$tmp" "$rendered" "$fake"
if [ "$fail" -eq 0 ]; then echo; echo "ALL STATIC CHECKS PASSED"; else echo; echo "SOME CHECKS FAILED"; exit 1; fi
