#!/bin/sh
# Builds and tests the engine on Linux inside a Swift container (Docker or OrbStack), so a Mac can check the Linux port.
#
# Usage: sh Tools/linux-test.sh [build|test|shell] [swift arguments...]
#   sh Tools/linux-test.sh                          swift build, then swift test (everything)
#   sh Tools/linux-test.sh test --filter HAPTests   only the matching tests
#   sh Tools/linux-test.sh build                    only swift build
#   sh Tools/linux-test.sh shell                    an interactive shell in the container
#
# Environment:
#   CB_SWIFT_IMAGE   base image (default swift:6.4.0-noble, the one CI and the releases use)
#   CB_CPUS          limit the container to this many CPUs (2 reproduces a GitHub-hosted runner, 4 the box). A whole number also pins it to
#                    that many (the first ones), so the engine sees that many cores, as libdispatch sizes its threads by them; --cpus alone
#                    only caps the time and leaves every core of the machine in view
#   CB_PLATFORM      docker platform, e.g. linux/amd64 to run x86_64 under emulation (default: the machine's own)
#
# Docker objects it creates, all named cb-linux-*: the image cb-linux-swift (the Swift image plus the system packages the
# package needs) and the volume cb-linux-build (the .build cache, kept out of the source tree and out of the Mac's .build).
# Remove them with: docker rmi cb-linux-swift; docker volume rm cb-linux-build
# Another CB_SWIFT_IMAGE gets its own image and volume, named after it (swift:6.4: cb-linux-swift-swift-6.4, cb-linux-build-swift-6.4),
# so an image built from one base is never used for another. Each image also records the base it was built from (label cb.base): one
# built from another base, or before it recorded one (an older default's), is built again, and the old one removed if nothing uses it.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_IMAGE="swift:6.4.0-noble"
BASE_IMAGE="${CB_SWIFT_IMAGE:-$DEFAULT_IMAGE}"
IMAGE="cb-linux-swift"
VOLUME="cb-linux-build"
if [ "$BASE_IMAGE" != "$DEFAULT_IMAGE" ]; then
    BASE_SUFFIX="$(printf '%s' "$BASE_IMAGE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.' '-')"
    IMAGE="$IMAGE-$BASE_SUFFIX"
    VOLUME="$VOLUME-$BASE_SUFFIX"
fi
PLATFORM_ARGS=""
[ -n "${CB_PLATFORM:-}" ] && PLATFORM_ARGS="--platform $CB_PLATFORM" && IMAGE="$IMAGE-$(echo "$CB_PLATFORM" | tr '/' '-')" && VOLUME="$VOLUME-$(echo "$CB_PLATFORM" | tr '/' '-')"

command -v docker >/dev/null 2>&1 || { echo "docker not found (install OrbStack or Docker Desktop)" >&2; exit 1; }

if ! docker info >/dev/null 2>&1; then
    # OrbStack: start it and wait at most two minutes.
    if command -v orb >/dev/null 2>&1; then
        echo "Starting OrbStack..."
        orb start >/dev/null 2>&1 || open -a OrbStack >/dev/null 2>&1 || true
    fi
    tries=0
    while ! docker info >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -gt 60 ] && { echo "the container engine did not start within two minutes" >&2; exit 1; }
        sleep 2
    done
fi

# The Swift image plus what the package links against on Linux (dns_sd from Avahi, ffmpeg for the codecs, libs Foundation needs), built
# again when the image there was built from another base than BASE_IMAGE, or does not say which (label cb.base).
BUILT_FROM="$(docker image inspect -f '{{ index .Config.Labels "cb.base" }}' "$IMAGE" 2>/dev/null || true)"
if [ "$BUILT_FROM" != "$BASE_IMAGE" ]; then
    OLD_ID="$(docker image inspect -f '{{ .Id }}' "$IMAGE" 2>/dev/null || true)"
    if [ -z "$OLD_ID" ]; then
        echo "Building the $IMAGE image from $BASE_IMAGE..."
    elif [ -z "$BUILT_FROM" ]; then
        echo "The $IMAGE image does not say which image it was built from: building it again from $BASE_IMAGE..."
    else
        echo "The $IMAGE image was built from $BUILT_FROM, not $BASE_IMAGE: building it again..."
    fi
    # shellcheck disable=SC2086
    docker build $PLATFORM_ARGS -t "$IMAGE" - <<EOF
FROM $BASE_IMAGE
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config libavahi-compat-libdnssd-dev iproute2 ffmpeg ca-certificates libcurl4-openssl-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*
LABEL cb.base="$BASE_IMAGE"
EOF
    [ -z "$OLD_ID" ] || docker rmi "$OLD_ID" >/dev/null 2>&1 || true
fi

MODE="${1:-all}"
[ "$#" -gt 0 ] && shift

CPU_ARGS=""
if [ -n "${CB_CPUS:-}" ]; then
    CPU_ARGS="--cpus $CB_CPUS"
    case "$CB_CPUS" in
        *[!0-9]*) ;;
        *) if [ "$CB_CPUS" -gt 0 ]; then CPU_ARGS="$CPU_ARGS --cpuset-cpus 0-$((CB_CPUS - 1))"; fi ;;
    esac
fi

# --scratch-path keeps the build products in the volume. The source tree is mounted read-write (SwiftPM writes Package.resolved).
RUN="docker run --rm --cap-add NET_ADMIN $CPU_ARGS $PLATFORM_ARGS -v $ROOT:/src -v $VOLUME:/cache -w /src/Packages/CameraBridgeKit -e CI=1"
case "$MODE" in
    build) exec $RUN "$IMAGE" swift build --scratch-path /cache/build "$@" ;;
    test) exec $RUN "$IMAGE" swift test --scratch-path /cache/build "$@" ;;
    shell) exec docker run --rm -it $PLATFORM_ARGS -v "$ROOT:/src" -v "$VOLUME:/cache" -w /src/Packages/CameraBridgeKit "$IMAGE" bash ;;
    all)
        $RUN "$IMAGE" swift build --scratch-path /cache/build "$@"
        exec $RUN "$IMAGE" swift test --scratch-path /cache/build "$@"
        ;;
    *) echo "usage: linux-test.sh [build|test|shell] [swift arguments...]" >&2; exit 2 ;;
esac
