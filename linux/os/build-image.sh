#!/bin/bash
# Builds the Camera Bridge OS disk image. Runs as root INSIDE the build container (Dockerfile.builder), where mkosi,
# systemd-repart and friends are installed. Use build.sh, which starts this in the container for you.
#
#   build-image.sh --arch amd64|arm64 --version 0.1 --out DIR (--daemon FILE | --stub-daemon) [options]
#
#   --stub-broken        like --stub-daemon, but the daemon dies at once (tests the automatic rollback)
#   --web DIR            web UI files to install (default: none; the daemon falls back to its built-in page)
#   --helpers DIR        helper programs from fetch-go2rtc.sh (DIR/go2rtc, go2rtc.LICENSE, go2rtc.version) and build-helpers.sh
#                        (DIR/wyze-lake, wyze-lake.version, wyze-lake.doc/; DIR/eufy/, eufy-bridge, eufy-bridge.version);
#                        required with --release
#   --pubkey FILE        update verification public key (default: the one in mkosi.extra, a placeholder)
#   --mirror URL         Debian mirror
#   --release            refuse placeholder key, stub daemon, unsigned output
#   --work DIR           scratch space (default /work/build-<arch>)
#   --root-size SIZE     size of each root slot (default 2560M)
#
# Signing: if MINISIGN_SECRET_KEY (the content of the minisign secret key file) is set, SHA256SUMS and the image are
# signed with it (MINISIGN_PASSWORD is its password if it has one). The key never touches the output folder or the log.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
arch=amd64 version="" out="" daemon="" stub=0 broken=0 web="" helpers="" pubkey="" mirror="" release=0 work="" root_size=2560M

while [ $# -gt 0 ]; do
    case $1 in
        --arch) arch=$2; shift ;;
        --version) version=$2; shift ;;
        --out) out=$2; shift ;;
        --daemon) daemon=$2; shift ;;
        --stub-daemon) stub=1 ;;
        --stub-broken) stub=1; broken=1 ;;
        --web) web=$2; shift ;;
        --helpers) helpers=$2; shift ;;
        --pubkey) pubkey=$2; shift ;;
        --mirror) mirror=$2; shift ;;
        --release) release=1 ;;
        --work) work=$2; shift ;;
        --root-size) root_size=$2; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "error: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root (inside the build container)"
[ -n "$version" ] || die "--version is required"
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "version must look like 0.1 or 1.2.3 (digits and dots)"
[ -n "$out" ] || die "--out is required"
case $arch in amd64) mkosi_arch=x86-64 ;; arm64) mkosi_arch=arm64 ;; *) die "unknown architecture $arch" ;; esac
[ -n "$daemon" ] || [ "$stub" -eq 1 ] || die "give --daemon FILE or --stub-daemon"
[ -z "$daemon" ] || [ -f "$daemon" ] || die "no such daemon binary: $daemon"
work=${work:-/work/build-$arch}

# paths.env: where the daemon, the web UI and the helpers live in the image (one place).
# shellcheck source=paths.env
. "$HERE/paths.env"

placeholder=0
key_src=${pubkey:-$HERE/mkosi.extra/usr/share/camera-bridge/update-key.pub}
[ -f "$key_src" ] || die "no public key file: $key_src"
grep -q PLACEHOLDER "$key_src" && placeholder=1
if [ "$release" -eq 1 ]; then
    [ "$placeholder" -eq 0 ] || die "--release needs a real update public key (replace linux/os/mkosi.extra/usr/share/camera-bridge/update-key.pub)"
    [ "$stub" -eq 0 ] || die "--release cannot use the stub daemon"
    [ -n "${MINISIGN_SECRET_KEY:-}" ] || die "--release needs MINISIGN_SECRET_KEY in the environment"
    [ -n "$helpers" ] || die "--release needs --helpers (go2rtc, wyze-lake and, on amd64, eufy-bridge)"
fi

mkdir -p "$out"
rm -rf "$work"
mkdir -p "$work"/{stage,repart,cache,ws,mkosi-out}
stage=$work/stage

echo "==> staging the daemon, the web UI and the rendered unit"
if [ "$stub" -eq 1 ]; then
    if [ "$broken" -eq 1 ]; then
        install -D -m 0755 "$HERE/stub/camerabridged-broken" "$stage$CB_DAEMON"
    else
        install -D -m 0755 "$HERE/stub/camerabridged-stub" "$stage$CB_DAEMON"
    fi
else
    install -D -m 0755 "$daemon" "$stage$CB_DAEMON"
    # The Swift runtime's crash helper (build.sh puts it beside the daemon): a crash of the daemon prints where it was in the journal
    # (SWIFT_BACKTRACE in the unit, registers=none so no memory contents are printed). Root-owned, the daemon's user can only run it.
    # Apache-2.0: it is a program of its own (the runtime exception covers only what is built into camerabridged), so its licence ships too.
    backtracer="$(dirname "$daemon")/swift-backtrace-static"
    if [ -f "$backtracer" ]; then
        [ -s "$backtracer.LICENSE" ] || die "no swift-backtrace-static.LICENSE beside the daemon (run build.sh)"
        install -D -m 0755 -o root -g root "$backtracer" "$stage/usr/libexec/swift/linux/swift-backtrace-static"
        {
            echo "swift-backtrace-static, the Swift runtime's crash helper, https://www.swift.org"
            [ ! -s "$backtracer.version" ] || cat "$backtracer.version"
            echo "Installed unmodified from the swift.org toolchain at /usr/libexec/swift/linux/swift-backtrace-static."
            echo "License: Apache-2.0 with the Runtime Library Exception (below)."
            echo
            cat "$backtracer.LICENSE"
        } >"$work/swift-backtrace.copyright"
        install -D -m 0644 "$work/swift-backtrace.copyright" "$stage/usr/share/doc/swift-backtrace/copyright"
    elif [ "$release" -eq 1 ]; then
        die "no swift-backtrace-static beside the daemon: a release prints a crash's backtrace (run build.sh)"
    else
        echo "    (no swift-backtrace-static beside the daemon: a crash will not print a backtrace)"
    fi
fi
mkdir -p "$stage$CB_WEB_ROOT"
if [ -n "$web" ]; then
    [ -d "$web" ] || die "no such web directory: $web"
    cp -a "$web"/. "$stage$CB_WEB_ROOT"/
fi
if [ -n "$helpers" ]; then
    # go2rtc (MIT), where PlatformLinux's ProcessHelperLauncher finds it. Its licence goes where Debian keeps every package's.
    for f in go2rtc go2rtc.LICENSE go2rtc.version; do [ -s "$helpers/$f" ] || die "no $f in $helpers (run fetch-go2rtc.sh)"; done
    install -D -m 0755 -o root -g root "$helpers/go2rtc" "$stage$CB_HELPERS_DIR/go2rtc"
    {
        echo "go2rtc, https://github.com/AlexxIT/go2rtc"
        cat "$helpers/go2rtc.version"
        echo "Installed unmodified at $CB_HELPERS_DIR/go2rtc. License: MIT."
        echo
        cat "$helpers/go2rtc.LICENSE"
    } >"$work/go2rtc.copyright"
    install -D -m 0644 "$work/go2rtc.copyright" "$stage/usr/share/doc/go2rtc/copyright"

    # Our own helpers from build-helpers.sh, found by the daemon by name in the same folder: wyze-lake (Go, MIT) and eufy-bridge
    # (a launcher that starts the eufy/ folder's Node.js with the bundle). All root-owned and read-only to the daemon's user; the
    # eufy helper writes only to its state folder under the daemon's data directory (CB_EUFY_STATE_DIR, and HOME points there).
    if [ -e "$helpers/wyze-lake" ]; then
        for f in wyze-lake wyze-lake.version wyze-lake.doc/LICENSE wyze-lake.doc/NOTICE; do
            [ -s "$helpers/$f" ] || die "no $f in $helpers (run build-helpers.sh)"
        done
        [ "$(sha256sum "$helpers/wyze-lake" | awk '{print $1}')" = "$(awk '$1 == "sha256" { print $2 }' "$helpers/wyze-lake.version")" ] \
            || die "$helpers/wyze-lake does not match its stamp (run build-helpers.sh)"
        install -D -m 0755 -o root -g root "$helpers/wyze-lake" "$stage$CB_HELPERS_DIR/wyze-lake"
        {
            echo "wyze-lake, Camera Bridge's helper for Wyze cameras that stream through Wyze's cloud (source: linux/helpers/wyze-lake)"
            cat "$helpers/wyze-lake.version"
            echo "Installed at $CB_HELPERS_DIR/wyze-lake. License: MIT (below). Its Go modules' licence texts: LICENSES/ in this folder."
            echo
            cat "$helpers/wyze-lake.doc/LICENSE"
            echo
            cat "$helpers/wyze-lake.doc/NOTICE"
        } >"$work/wyze-lake.copyright"
        install -D -m 0644 "$work/wyze-lake.copyright" "$stage/usr/share/doc/wyze-lake/copyright"
        install -d -m 0755 "$stage/usr/share/doc/wyze-lake/LICENSES"
        install -m 0644 -o root -g root "$helpers/wyze-lake.doc/LICENSES"/* "$stage/usr/share/doc/wyze-lake/LICENSES/"
    elif [ "$release" -eq 1 ]; then
        die "--release needs the wyze-lake helper in $helpers (run build-helpers.sh)"
    fi
    if [ -d "$helpers/eufy" ]; then
        for f in eufy/node eufy/eufy-bridge.js eufy/package.json eufy/VERSION eufy/LICENSES/README.txt eufy-bridge eufy-bridge.version; do
            [ -s "$helpers/$f" ] || die "no $f in $helpers (run build-helpers.sh)"
        done
        [ "$(sha256sum "$helpers/eufy/node" | awk '{print $1}')" = "$(awk '$1 == "node-sha256" { print $2 }' "$helpers/eufy-bridge.version")" ] \
            || die "$helpers/eufy/node is not the pinned Node.js binary (run build-helpers.sh)"
        eufy=$stage$CB_HELPERS_DIR/eufy
        install -d -m 0755 -o root -g root "$eufy"
        install -m 0755 -o root -g root "$helpers/eufy/node" "$eufy/node"
        for f in eufy-bridge.js package.json VERSION; do install -m 0644 -o root -g root "$helpers/eufy/$f" "$eufy/$f"; done
        cp -R "$helpers/eufy/LICENSES" "$eufy/LICENSES"
        chown -R root:root "$eufy/LICENSES"
        find "$eufy/LICENSES" -type d -exec chmod 0755 {} +
        find "$eufy/LICENSES" -type f -exec chmod 0644 {} +
        # The launcher (written by build-helpers.sh): it must start this folder's node with the bundle.
        grep -qxF "exec $CB_HELPERS_DIR/eufy/node $CB_HELPERS_DIR/eufy/eufy-bridge.js \"\$@\"" "$helpers/eufy-bridge" \
            || die "$helpers/eufy-bridge is not the launcher for $CB_HELPERS_DIR/eufy (run build-helpers.sh)"
        install -m 0755 -o root -g root "$helpers/eufy-bridge" "$stage$CB_HELPERS_DIR/eufy-bridge"
        {
            echo "eufy-bridge, Camera Bridge's helper for Eufy cameras (source: linux/helpers/eufy-bridge)"
            cat "$helpers/eufy-bridge.version"
            echo
            cat "$helpers/eufy/VERSION"
            echo
            echo "Installed at $CB_HELPERS_DIR/eufy (started by $CB_HELPERS_DIR/eufy-bridge). It contains Node.js (MIT and others)"
            echo "and, bundled into eufy-bridge.js, @mega-yfue/eufy-sdk (Apache-2.0; its protobufjs loader is rewritten at bundle time"
            echo "to a plain require, the only change) and the npm packages below. Every licence text is in $CB_HELPERS_DIR/eufy/LICENSES."
            echo
            cat "$helpers/eufy/LICENSES/README.txt"
        } >"$work/eufy-bridge.copyright"
        install -D -m 0644 "$work/eufy-bridge.copyright" "$stage/usr/share/doc/eufy-bridge/copyright"
    elif [ "$release" -eq 1 ] && [ "$arch" = amd64 ]; then
        die "--release needs the eufy-bridge helper in $helpers (run build-helpers.sh)"
    fi
fi
install -d "$stage/usr/lib/systemd/system"
sed -e "s|@CB_DAEMON@|$CB_DAEMON|g" -e "s|@CB_WEB_ROOT@|$CB_WEB_ROOT|g" \
    "$HERE/units/camerabridged.service.in" >"$stage/usr/lib/systemd/system/camerabridged.service"
install -D -m 0644 "$key_src" "$stage/usr/share/camera-bridge/update-key.pub"
# The docs the image refers to.
if [ -f "$HERE/../../docs/linux/UPDATES.md" ]; then
    install -D -m 0644 "$HERE/../../docs/linux/UPDATES.md" "$stage/usr/share/camera-bridge/UPDATES.md"
fi
if [ "$stub" -eq 1 ]; then
    printf 'This is a TEST image with a stub daemon. Not for use.\n' >"$stage/usr/share/camera-bridge/STUB-IMAGE"
fi
# Our own license and notices, the license overview and the written source offer (GPL and LGPL parts of the system).
repo_root=$HERE/../..
docdir=$stage/usr/share/doc/camera-bridge
for f in LICENSE NOTICE THIRD_PARTY_LICENSES.md; do
    install -D -m 0644 "$repo_root/$f" "$docdir/$f"
done
install -D -m 0644 "$repo_root/docs/linux/LICENSES.md" "$docdir/OS-LICENSES.md"
sed -e "s|@VERSION@|$version|g" "$HERE/SOURCE-OFFER.txt.in" >"$docdir/SOURCE-OFFER.txt"

echo "==> rendering the partition layout (root slots $root_size, version $version)"
for f in "$HERE"/repart/image/*.conf; do
    sed -e "s|@VERSION@|$version|g" -e "s|@ROOT_SIZE@|$root_size|g" "$f" >"$work/repart/$(basename "$f")"
done

mkosi_args=(
    --directory "$HERE"
    --force
    --architecture "$mkosi_arch"
    --image-version "$version"
    --output-dir "$work/mkosi-out"
    --cache-dir "$work/cache"
    --workspace-dir "$work/ws"
    --repart-directory "$work/repart"
    --extra-tree "$stage"
)
[ -z "$mirror" ] || mkosi_args+=(--mirror "$mirror")
[ "$stub" -eq 0 ] || mkosi_args+=(--package python3-minimal)
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then mkosi_args+=(--source-date-epoch "$SOURCE_DATE_EPOCH"); fi

echo "==> mkosi build (this takes a while)"
mkosi "${mkosi_args[@]}" build

# The whole disk image by its exact name: newer mkosi versions also leave one file per partition next to it
# (camera-bridge-os.esp.raw, .root.raw, .srv.raw), which a wildcard would pick up.
raw="$work/mkosi-out/camera-bridge-os.raw"
[ -f "$raw" ] || { ls -la "$work/mkosi-out" >&2; die "mkosi produced no disk image"; }
uki="$work/mkosi-out/camera-bridge-os.efi"
[ -f "$uki" ] || { ls -la "$work/mkosi-out" >&2; die "mkosi produced no unified kernel image"; }

echo "==> checking the image layout"
sfdisk -J "$raw" >"$work/layout.json" || die "sfdisk could not read $raw"
if ! jq -e '(.partitiontable.partitions // []) | length > 0' "$work/layout.json" >/dev/null; then
    echo "--- sfdisk -J $raw" >&2; cat "$work/layout.json" >&2
    echo "--- sfdisk -d" >&2; sfdisk -d "$raw" >&2 || true
    echo "--- $work/mkosi-out" >&2; ls -la "$work/mkosi-out" >&2
    die "the disk image has no partitions that sfdisk can see"
fi
jq -r '.partitiontable.partitions[] | "  \(.node | split("/") | last)  type=\(.type)  start=\(.start)  size=\(.size)  name=\(.name)"' "$work/layout.json"
root_a=$(jq -r '[.partitiontable.partitions[] | select(.name == "cb-root_'"$version"'")] | first | "\(.start) \(.size)"' "$work/layout.json")
if [ -z "$root_a" ] || [ "$root_a" = "null null" ]; then die "root slot A (label cb-root_$version) not found in the image"; fi
jq -e '[.partitiontable.partitions[] | select(.name == "_empty")] | length == 1' "$work/layout.json" >/dev/null || die "root slot B not found"
jq -e '[.partitiontable.partitions[] | select(.name == "cb-data")] | length == 1' "$work/layout.json" >/dev/null || die "data partition not found"

echo "==> producing the release files"
img_name=camera-bridge-os-$version-$arch.img
uki_name=cb-os_${version}_${arch}.efi
root_name=cb-os_${version}_${arch}_root.raw.zst
sums=SHA256SUMS

cp --sparse=always "$raw" "$work/$img_name"
cp "$uki" "$out/$uki_name"
read -r start size <<<"$root_a"
dd if="$raw" of="$work/root.raw" bs=512 skip="$start" count="$size" status=none
# The package list and the source offer go next to the release files too (they are inside the image as well).
packages_name=camera-bridge-os-$version-packages.txt
debugfs -R "cat /usr/share/camera-bridge/packages.txt" "$work/root.raw" >"$out/$packages_name" 2>/dev/null
[ -s "$out/$packages_name" ] || die "could not read the package list from the image"
cp "$docdir/SOURCE-OFFER.txt" "$out/SOURCE-OFFER.txt"
for f in LICENSE NOTICE OS-LICENSES.md; do
    debugfs -R "stat /usr/share/doc/camera-bridge/$f" "$work/root.raw" >/dev/null 2>&1 || die "$f is missing from the image"
done
if [ "$stub" -eq 0 ] && [ -f "$(dirname "$daemon")/swift-backtrace-static" ]; then
    debugfs -R "stat /usr/share/doc/swift-backtrace/copyright" "$work/root.raw" >/dev/null 2>&1 || die "the crash helper's licence is missing from the image"
    st=$(debugfs -R "stat /usr/libexec/swift/linux/swift-backtrace-static" "$work/root.raw" 2>/dev/null)
    if ! grep -Eq 'User: +0 +Group: +0' <<<"$st" || ! grep -Eq 'Mode: +0?0755' <<<"$st"; then die "the crash helper in the image is not root-owned 0755"; fi
fi
if [ -n "$helpers" ]; then
    image_files=("$CB_HELPERS_DIR/go2rtc" /usr/share/doc/go2rtc/copyright)
    image_programs=("$CB_HELPERS_DIR/go2rtc")
    if [ -e "$helpers/wyze-lake" ]; then
        image_files+=("$CB_HELPERS_DIR/wyze-lake" /usr/share/doc/wyze-lake/copyright)
        image_programs+=("$CB_HELPERS_DIR/wyze-lake")
    fi
    if [ -d "$helpers/eufy" ]; then
        image_files+=("$CB_HELPERS_DIR/eufy-bridge" "$CB_HELPERS_DIR/eufy/node" "$CB_HELPERS_DIR/eufy/eufy-bridge.js"
                      "$CB_HELPERS_DIR/eufy/package.json" "$CB_HELPERS_DIR/eufy/VERSION" "$CB_HELPERS_DIR/eufy/LICENSES/README.txt"
                      /usr/share/doc/eufy-bridge/copyright)
        image_programs+=("$CB_HELPERS_DIR/eufy-bridge" "$CB_HELPERS_DIR/eufy/node")
    fi
    for f in "${image_files[@]}"; do
        debugfs -R "stat $f" "$work/root.raw" >/dev/null 2>&1 || die "$f is missing from the image"
    done
    # The programs: root-owned, 0755 (the daemon's user can run them, not change them).
    for f in "${image_programs[@]}"; do
        st=$(debugfs -R "stat $f" "$work/root.raw" 2>/dev/null)
        if ! grep -Eq 'User: +0 +Group: +0' <<<"$st" || ! grep -Eq 'Mode: +0?0755' <<<"$st"; then die "$f in the image is not root-owned 0755"; fi
    done
    if [ -d "$helpers/eufy" ]; then
        debugfs -R "dump $CB_HELPERS_DIR/eufy/node $work/node.check" "$work/root.raw" >/dev/null 2>&1
        [ "$(sha256sum "$work/node.check" | awk '{print $1}')" = "$(sha256sum "$helpers/eufy/node" | awk '{print $1}')" ] \
            || die "the image's $CB_HELPERS_DIR/eufy/node is not the verified Node.js binary"
        rm -f "$work/node.check"
    fi
fi
# How full the root slot is (the helpers live there; the slot size is fixed by --root-size, the same for both slots).
root_blocks=$(dumpe2fs -h "$work/root.raw" 2>/dev/null | awk -F: '/^Block count/ { gsub(/ /, "", $2); print $2 }')
root_free=$(dumpe2fs -h "$work/root.raw" 2>/dev/null | awk -F: '/^Free blocks/ { gsub(/ /, "", $2); print $2 }')
root_bsize=$(dumpe2fs -h "$work/root.raw" 2>/dev/null | awk -F: '/^Block size/ { gsub(/ /, "", $2); print $2 }')
if [ -n "$root_blocks" ] && [ -n "$root_free" ] && [ -n "$root_bsize" ]; then
    echo "    root slot: $(( (root_blocks - root_free) * root_bsize / 1048576 )) MiB used, $(( root_free * root_bsize / 1048576 )) MiB free of $(( root_blocks * root_bsize / 1048576 )) MiB"
fi
zstd -q -T0 -19 --long=27 -f "$work/root.raw" -o "$out/$root_name"
rm -f "$work/root.raw"
xz -T0 -6 -c "$work/$img_name" >"$out/$img_name.xz"
rm -f "$work/$img_name"

(
    cd "$out"
    sha256sum "$img_name.xz" >"$img_name.xz.sha256"
    sha256sum "$img_name.xz" "$uki_name" "$root_name" >"$sums"
)

sign() {
    # sign FILE SIGFILE
    local keyfile=$work/minisign.key
    ( umask 077; printf '%s\n' "$MINISIGN_SECRET_KEY" >"$keyfile" )
    if [ -n "${MINISIGN_PASSWORD:-}" ]; then
        printf '%s\n' "$MINISIGN_PASSWORD" | minisign -S -s "$keyfile" -m "$1" -x "$2" >/dev/null
    else
        minisign -S -s "$keyfile" -m "$1" -x "$2" >/dev/null
    fi
    shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"
}

if [ -n "${MINISIGN_SECRET_KEY:-}" ]; then
    echo "==> signing"
    sign "$out/$sums" "$out/$sums.sig"
    sign "$out/$img_name.xz" "$out/$img_name.xz.sig"
    # Verify with the public key that is baked into the image: catches a mismatched key before anything is published.
    minisign -V -q -p "$key_src" -m "$out/$sums" -x "$out/$sums.sig" || die "the signature does not verify with the image's public key"
else
    echo "==> no MINISIGN_SECRET_KEY: files are NOT signed (fine for tests, not for a release)"
fi

echo "==> done"
ls -la "$out"
