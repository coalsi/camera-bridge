#!/bin/bash
# Builds Camera Bridge OS: the camerabridged daemon (static Swift build), the Debian image (mkosi), the compressed
# release files, SHA-256 sums and signatures. Works on a Mac (Docker / OrbStack) and on Linux (Docker). Needs only Docker.
#
#   linux/os/build.sh --version 0.1 [--arch amd64|arm64] [--out DIR]
#                     [--daemon FILE | --stub-daemon | (default: build the daemon with Swift in a container)]
#                     [--release] [--pubkey FILE] [--mirror URL] [--clean]
#
#   --version V        image version (digits and dots, e.g. 0.1): the os-v<V> tag
#   --arch A           amd64 (default) or arm64. Build the architecture of the machine you are on: on an Apple Silicon Mac that is
#                      arm64 (amd64 needs a Linux x86-64 machine or GitHub Actions: Docker's x86 emulation lacks a system call mkosi needs)
#   --out DIR          where the release files go (default: linux/os/out)
#   --daemon FILE      use this prebuilt Linux camerabridged instead of building it
#   --stub-daemon      put a tiny Python stand-in in the image (tests of the OS itself; never for releases)
#   --stub-broken      like --stub-daemon, but the daemon dies at once (tests automatic rollback)
#   --release          refuse a placeholder update key, the stub daemon and unsigned output
#   --pubkey FILE      update verification key to bake into the image (tests; releases use the file in the repository)
#   --mirror URL       Debian mirror
#   --clean            remove the Docker volumes and image this script created (cb-os-*), then exit
#
# Signing (releases): export MINISIGN_SECRET_KEY="$(cat path/to/camera-bridge.key)" and, if the key has a password,
# MINISIGN_PASSWORD. See docs/linux/BUILDING.md. The secret key is never written to the output or the log.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

version="" arch=amd64 out="$HERE/out" daemon="" stub=0 broken=0 release=0 pubkey="" mirror="" clean=0
# The engine and its tests use Swift 6.4. The -noble (Ubuntu 24.04) image on purpose: a binary built on a newer distribution
# links libxml2.so.16 and newer glibc symbols that Debian 13 (the image) does not have.
SWIFT_IMAGE=${CB_SWIFT_IMAGE:-swift:6.4-noble}
SWIFT_BUILD_IMAGE=cb-os-swift-build
BUILDER_IMAGE=cb-os-builder
WORK_VOLUME=cb-os-work

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --version) version=$2; shift ;;
        --arch) arch=$2; shift ;;
        --out) out=$2; shift ;;
        --daemon) daemon=$2; shift ;;
        --stub-daemon) stub=1 ;;
        --stub-broken) stub=1; broken=1 ;;
        --release) release=1 ;;
        --pubkey) pubkey=$2; shift ;;
        --mirror) mirror=$2; shift ;;
        --clean) clean=1 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

command -v docker >/dev/null || die "Docker is required (Docker Desktop, OrbStack, or docker.io on Linux)"

if [ "$clean" -eq 1 ]; then
    docker volume ls -q --filter name='^cb-os-' | xargs -r docker volume rm
    docker image rm -f "$BUILDER_IMAGE:amd64" "$BUILDER_IMAGE:arm64" "$SWIFT_BUILD_IMAGE:amd64" "$SWIFT_BUILD_IMAGE:arm64" >/dev/null 2>&1 || true
    echo "removed the cb-os-* volumes and the $BUILDER_IMAGE images"
    exit 0
fi

[ -n "$version" ] || die "--version is required (for example --version 0.1)"
case $arch in amd64|arm64) ;; *) die "--arch must be amd64 or arm64" ;; esac
[ "$release" -eq 0 ] || [ "$stub" -eq 0 ] || die "--release cannot be combined with --stub-daemon"
case "$(uname -m)" in
    arm64|aarch64)
        if [ "$arch" = amd64 ] && [ "${CB_ALLOW_CROSS:-0}" != 1 ]; then
            die "cannot build the amd64 image on an ARM machine: mkosi needs the mount_setattr() system call, which Docker's x86 emulation does not provide. Build on a Linux x86-64 machine or with the GitHub Actions workflow (or --arch arm64 here; set CB_ALLOW_CROSS=1 to try anyway)."
        fi ;;
esac
mkdir -p "$out"
out=$(cd "$out" && pwd)

# --- 1. the daemon -----------------------------------------------------------------------------------------------------
daemon_dir=""
if [ "$stub" -eq 0 ] && [ -z "$daemon" ]; then
    [ -d "$REPO/Packages/CameraBridgeKit/Sources/camerabridged" ] \
        || die "Packages/CameraBridgeKit/Sources/camerabridged does not exist yet; build with --stub-daemon (tests) or --daemon FILE"
    echo "==> building camerabridged ($arch, static Swift stdlib) in $SWIFT_IMAGE"
    # (--build-system native: with the default build system of Swift 6.4 the static link of Foundation fails on missing CoreFoundation symbols.)
    # The Swift image plus what the package links against on Linux (dns_sd from Avahi, libcurl and libxml2 for Foundation).
    docker build -q --platform "linux/$arch" -t "$SWIFT_BUILD_IMAGE:$arch" - >/dev/null <<EOF
FROM $SWIFT_IMAGE
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libavahi-compat-libdnssd-dev ca-certificates \\
        libcurl4-openssl-dev libxml2-dev && rm -rf /var/lib/apt/lists/*
EOF
    docker volume create "cb-os-swift-$arch" >/dev/null
    docker run --rm --platform "linux/$arch" \
        -v "$REPO":/src:ro -v "cb-os-swift-$arch":/scratch -v "$WORK_VOLUME":/work \
        -w /src/Packages/CameraBridgeKit "$SWIFT_BUILD_IMAGE:$arch" \
        bash -c 'set -euo pipefail
                 swift build -c release --product camerabridged --static-swift-stdlib --build-system native --scratch-path /scratch
                 mkdir -p /work/daemon-'"$arch"'
                 bin="$(swift build -c release --product camerabridged --static-swift-stdlib --build-system native --scratch-path /scratch --show-bin-path)/camerabridged"
                 strip --strip-debug "$bin"
                 install -m 0755 "$bin" /work/daemon-'"$arch"'/camerabridged'
    daemon_in_container=/work/daemon-$arch/camerabridged
fi

# --- 2. the image, inside the builder container ---------------------------------------------------------------------
echo "==> preparing the builder image ($BUILDER_IMAGE:$arch)"
docker build -q --platform "linux/$arch" -f "$HERE/Dockerfile.builder" -t "$BUILDER_IMAGE:$arch" "$HERE" >/dev/null
docker volume create "$WORK_VOLUME" >/dev/null

args=(--arch "$arch" --version "$version" --out /out)
if [ "$stub" -eq 1 ]; then
    if [ "$broken" -eq 1 ]; then args+=(--stub-broken); else args+=(--stub-daemon); fi
elif [ -n "$daemon" ]; then
    [ -f "$daemon" ] || die "no such file: $daemon"
    daemon_dir=$(cd "$(dirname "$daemon")" && pwd)
    args+=(--daemon "/daemon/$(basename "$daemon")")
else
    args+=(--daemon "$daemon_in_container")
fi
[ -d "$REPO/linux/web" ] && args+=(--web /src/linux/web)
[ "$release" -eq 0 ] || args+=(--release)
[ -z "$mirror" ] || args+=(--mirror "$mirror")

mounts=(-v "$REPO":/src:ro -v "$WORK_VOLUME":/work -v "$out":/out)
[ -z "$daemon_dir" ] || mounts+=(-v "$daemon_dir":/daemon:ro)
if [ -n "$pubkey" ]; then
    [ -f "$pubkey" ] || die "no such file: $pubkey"
    mounts+=(-v "$(cd "$(dirname "$pubkey")" && pwd)/$(basename "$pubkey")":/pubkey.pub:ro)
    args+=(--pubkey /pubkey.pub)
fi

env_args=()
[ -z "${MINISIGN_SECRET_KEY:-}" ] || env_args+=(-e MINISIGN_SECRET_KEY)
[ -z "${MINISIGN_PASSWORD:-}" ] || env_args+=(-e MINISIGN_PASSWORD)
[ -z "${SOURCE_DATE_EPOCH:-}" ] || env_args+=(-e SOURCE_DATE_EPOCH)

echo "==> building the image in the container"
docker run --rm --privileged --platform "linux/$arch" "${mounts[@]}" ${env_args[@]+"${env_args[@]}"} "$BUILDER_IMAGE:$arch" \
    /src/linux/os/build-image.sh "${args[@]}"

echo
echo "Files in $out:"
ls -la "$out"
echo
echo "The Docker volumes cb-os-* keep caches (several GB). Remove them with: linux/os/build.sh --clean"
