#!/bin/bash
# Builds the Camera Bridge OS disk image. Runs as root INSIDE the build container (Dockerfile.builder), where mkosi,
# systemd-repart and friends are installed. Use build.sh, which starts this in the container for you.
#
#   build-image.sh --arch amd64|arm64 --version 0.1 --out DIR (--daemon FILE | --stub-daemon) [options]
#
#   --stub-broken        like --stub-daemon, but the daemon dies at once (tests the automatic rollback)
#   --web DIR            web UI files to install (default: none; the daemon falls back to its built-in page)
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
arch=amd64 version="" out="" daemon="" stub=0 broken=0 web="" pubkey="" mirror="" release=0 work="" root_size=2560M

while [ $# -gt 0 ]; do
    case $1 in
        --arch) arch=$2; shift ;;
        --version) version=$2; shift ;;
        --out) out=$2; shift ;;
        --daemon) daemon=$2; shift ;;
        --stub-daemon) stub=1 ;;
        --stub-broken) stub=1; broken=1 ;;
        --web) web=$2; shift ;;
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

# paths.env: where the daemon and the web UI live in the image (one place).
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
fi
mkdir -p "$stage$CB_WEB_ROOT"
if [ -n "$web" ]; then
    [ -d "$web" ] || die "no such web directory: $web"
    cp -a "$web"/. "$stage$CB_WEB_ROOT"/
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

raw=$(find "$work/mkosi-out" -maxdepth 1 -name 'camera-bridge-os*.raw' | head -1)
[ -f "$raw" ] || { ls -la "$work/mkosi-out" >&2; die "mkosi produced no disk image"; }
uki=$(find "$work/mkosi-out" -maxdepth 1 -name '*.efi' | head -1)
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
