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
#   CB_SWIFT_IMAGE   base image (default swift:6.4)
#   CB_PLATFORM      docker platform, e.g. linux/amd64 to run x86_64 under emulation (default: the machine's own)
#
# Docker objects it creates, all named cb-linux-*: the image cb-linux-swift (the Swift image plus the system packages the
# package needs) and the volume cb-linux-build (the .build cache, kept out of the source tree and out of the Mac's .build).
# Remove them with: docker rmi cb-linux-swift; docker volume rm cb-linux-build
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_IMAGE="${CB_SWIFT_IMAGE:-swift:6.4}"
IMAGE="cb-linux-swift"
VOLUME="cb-linux-build"
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

# The Swift image plus what the package links against on Linux (dns_sd from Avahi, ffmpeg for the codecs, libs Foundation needs).
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Building the $IMAGE image from $BASE_IMAGE..."
    # shellcheck disable=SC2086
    docker build $PLATFORM_ARGS -t "$IMAGE" - <<EOF
FROM $BASE_IMAGE
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config libavahi-compat-libdnssd-dev iproute2 ffmpeg ca-certificates libcurl4-openssl-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*
EOF
fi

MODE="${1:-all}"
[ "$#" -gt 0 ] && shift

# --scratch-path keeps the build products in the volume. The source tree is mounted read-write (SwiftPM writes Package.resolved).
RUN="docker run --rm --cap-add NET_ADMIN $PLATFORM_ARGS -v $ROOT:/src -v $VOLUME:/cache -w /src/Packages/CameraBridgeKit -e CI=1"
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
