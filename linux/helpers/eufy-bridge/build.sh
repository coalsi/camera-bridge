#!/bin/sh
# Builds DIR/eufy-bridge/ (node + eufy-bridge.js + launcher + package.json + LICENSES + VERSION) for linux/amd64.
# Everything runs in Docker, in the Node image pinned by digest (pins.env); runnable from a Mac with Docker (the container is
# linux/amd64, emulated on Apple Silicon). linux/os/build-helpers.sh runs this for the Camera Bridge OS image.
#
#   ./build.sh [--out DIR]   build (runs the unit tests first); default DIR: out
#   SKIP_TESTS=1 ./build.sh  build without tests
#
# SOURCE_DATE_EPOCH, when set, is the build date written into VERSION and the bundle.
# shellcheck source-path=SCRIPTDIR
set -eu
cd "$(dirname "$0")"
. ./pins.env

OUT=out
while [ $# -gt 0 ]; do
    case $1 in
        --out) OUT=${2:-}; shift ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "eufy-bridge: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# The image has no ffmpeg; the build container installs it only to run the stream tests.
docker run --rm --platform linux/amd64 \
  -v "$PWD":/src:ro -v "$OUT":/out \
  -e NODE_VERSION="$NODE_VERSION" -e NODE_SHA256="$NODE_SHA256" -e NODE_BIN_SHA256="$NODE_BIN_SHA256" \
  -e SDK_VERSION="$SDK_VERSION" -e SDK_COMMIT="$SDK_COMMIT" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
  -e SKIP_TESTS="${SKIP_TESTS:-0}" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$NODE_IMAGE" sh -c '
    set -e
    if [ "${SKIP_TESTS}" != "1" ]; then
      apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null
    fi
    sh /src/scripts/build-inner.sh
  '
echo "built $OUT/eufy-bridge:"
ls -la "$OUT/eufy-bridge"
cat "$OUT/eufy-bridge/VERSION"
