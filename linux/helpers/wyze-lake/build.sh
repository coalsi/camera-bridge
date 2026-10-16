#!/bin/sh
# Builds wyze-lake for Linux (static, CGO off) in the official Go image pinned by digest (pins.env), after go mod verify,
# go vet and the tests. Needs only Docker; runnable from a Mac. The container runs on the machine's own architecture and Go
# cross-compiles (GOARCH), so no emulation is involved. linux/os/build-helpers.sh runs this for the Camera Bridge OS image.
#
#   ./build.sh [--arch amd64|arm64] [--out DIR]   writes DIR/wyze-lake (default DIR: out, or out/arm64 for arm64)
#   SKIP_TESTS=1 ./build.sh                       build without the tests
#   FULL_TESTS=1 ./build.sh                       install ffmpeg (libx264, libx265, libopus) in the container first, so
#                                                 the tests that need it run instead of skipping
#
# Reproducible: the modules are checked against go.sum (go mod verify, -mod=readonly), -trimpath, fixed ldflags, no build id.
# The Go module and build caches are in the Docker volume cb-os-go (linux/os/build.sh --clean removes it).
# shellcheck source-path=SCRIPTDIR
set -eu
cd "$(dirname "$0")"
. ./pins.env

ARCH=amd64 OUT=""
while [ $# -gt 0 ]; do
    case $1 in
        --arch) ARCH=${2:-}; shift ;;
        --out) OUT=${2:-}; shift ;;
        amd64|arm64) ARCH=$1 ;;   # the old positional form
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "wyze-lake: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case $ARCH in amd64|arm64) ;; *) echo "wyze-lake: --arch must be amd64 or arm64" >&2; exit 2 ;; esac
if [ -z "$OUT" ]; then if [ "$ARCH" = amd64 ]; then OUT=out; else OUT=out/$ARCH; fi; fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
rm -f "$OUT/wyze-lake.partial"

docker volume create cb-os-go >/dev/null
docker run --rm -v "$PWD":/src:ro -v "$OUT":/out -v cb-os-go:/cache -w /src \
    -e CGO_ENABLED=0 -e GOFLAGS=-mod=readonly -e GOTOOLCHAIN=local -e GOMODCACHE=/cache/mod -e GOCACHE=/cache/build \
    -e TARGET_ARCH="$ARCH" -e VERSION="$WYZE_LAKE_VERSION" -e SKIP_TESTS="${SKIP_TESTS:-0}" -e FULL_TESTS="${FULL_TESTS:-0}" \
    -e OWNER="$(id -u):$(id -g)" \
    "$GO_IMAGE" sh -c '
        set -eu
        go mod download
        go mod verify
        go vet ./...
        if [ "$SKIP_TESTS" != 1 ]; then
            if [ "$FULL_TESTS" = 1 ]; then
                apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends ffmpeg >/dev/null
            fi
            go test -count=1 ./...
        fi
        GOOS=linux GOARCH="$TARGET_ARCH" go build -trimpath -buildvcs=false \
            -ldflags "-s -w -buildid= -X main.version=$VERSION" -o /out/wyze-lake.partial .
        # Run it when the container can (same architecture): it must say the pinned version.
        if [ "$(go env GOHOSTARCH)" = "$TARGET_ARCH" ]; then
            got=$(/out/wyze-lake.partial --version)
            [ "$got" = "wyze-lake $VERSION" ] || { echo "wyze-lake: --version printed \"$got\"" >&2; exit 1; }
        fi
        chown "$OWNER" /out/wyze-lake.partial'
chmod 0755 "$OUT/wyze-lake.partial"
mv "$OUT/wyze-lake.partial" "$OUT/wyze-lake"
echo "$(wc -c <"$OUT/wyze-lake" | tr -d ' ') $OUT/wyze-lake"
if command -v sha256sum >/dev/null; then sha256sum "$OUT/wyze-lake"; else shasum -a 256 "$OUT/wyze-lake"; fi
