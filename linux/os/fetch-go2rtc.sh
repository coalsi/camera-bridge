#!/bin/bash
# Builds the go2rtc streaming helper (MIT, github.com/AlexxIT/go2rtc) for Camera Bridge OS from a pinned commit, with the
# official Go toolchain in Docker, and checks the result against the SHA-256 pinned below. build.sh runs it; the image gets the
# binary at /usr/lib/camera-bridge/helpers/go2rtc (where the engine's ProcessHelperLauncher looks for it on Linux).
#
#   linux/os/fetch-go2rtc.sh --arch amd64|arm64 [--output DIR]   build (or reuse a verified DIR/go2rtc); default DIR: build/os-helpers/<arch>
#   linux/os/fetch-go2rtc.sh --arch amd64 --verify               check DIR/go2rtc against the pinned checksum; build nothing
#   linux/os/fetch-go2rtc.sh --arch amd64 --test                 also run go2rtc's own tests of pkg/tutk and pkg/wyze (Wyze's TUTK protocol)
#
# Writes DIR/go2rtc (0755), DIR/go2rtc.LICENSE (the project's LICENSE at that commit) and DIR/go2rtc.version (what was built).
#
# Why a commit and not the v1.9.14 release binary: the native Wyze source (wyze://, pkg/tutk + pkg/wyze) was written in the weeks
# before v1.9.14 and fixed after it (75bd1f1 "Improve packet loss on old TUTK proto", 2026-01-20). The pinned commit is the head
# of master on 2026-10-15; it still calls itself 1.9.14 and prints "1.9.14+dev.c245815" for -version.
#
# Reproducible: the source is fetched by its full commit hash (git checks it), the Go modules are checked against go.sum (and
# Go's checksum database), the toolchain image is pinned by digest, the build is CGO_ENABLED=0 -trimpath with fixed ldflags, and
# the binary must match the pinned SHA-256: the same bytes on an Apple Silicon Mac (Go cross-compiles, no emulation) and on the
# x86-64 GitHub runner. A mismatch installs nothing.
#
# To update go2rtc: change GO2RTC_COMMIT (and GO2RTC_VERSION to what the new build prints), set the checksums to the new build's
# (the script prints them on a mismatch; build on two machines and compare before committing), update docs/third-party/go2rtc.md,
# NOTICE, THIRD_PARTY_LICENSES.md and docs/linux/LICENSES.md, and run with --test.
set -euo pipefail

GO2RTC_COMMIT="c245815e75e2a5fd60b4290f12bfc04e55a984d3"   # master, 2026-07-13 (head on 2026-10-15)
GO2RTC_VERSION="1.9.14+dev.c245815"                         # what `go2rtc -version` prints for this build
GO_IMAGE="golang:1.25.14-bookworm@sha256:3b4a11519ad929d1e1d261a12cff056f0c85b735253d7d861346b9c6f8b36437"
SHA256_AMD64="260d20fa932ec302f49ddb94bfe0669b357e902d15232f2b154e1972998ba363"   # go2rtc, linux/amd64
SHA256_ARM64="7c1cefffbe19548580c60df6c03b41dcbd7b08deed64161aa6f79deb26323729"   # go2rtc, linux/arm64
SHA256_LICENSE="b0dcf4855af5a72b4dfbd9117c207b330f4cc35658576a0b5351d6e2becac546" # LICENSE at GO2RTC_COMMIT

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SOURCE_URL="${CB_GO2RTC_GIT_URL:-https://github.com/AlexxIT/go2rtc}"
CACHE_VOLUME=cb-os-go   # Go module and build caches (removed by build.sh --clean, like the other cb-os-* volumes)

arch="" output="" verify_only=0 run_tests=0
die() { echo "go2rtc: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --arch) arch=${2:-}; shift ;;
        --output) output=${2:-}; shift ;;
        --verify) verify_only=1 ;;
        --test) run_tests=1 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

case $arch in
    amd64) expected=$SHA256_AMD64 ;;
    arm64) expected=$SHA256_ARM64 ;;
    *) die "--arch must be amd64 or arm64" ;;
esac
output=${output:-$REPO/build/os-helpers/$arch}

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
# check FILE EXPECTED: succeeds when the file exists and its SHA-256 equals EXPECTED.
check() { [ -f "$1" ] && [ "$(sha256_of "$1")" = "$2" ]; }

stamp="go2rtc $GO2RTC_VERSION, commit $GO2RTC_COMMIT, linux/$arch, built with $GO_IMAGE, sha256 $expected"
if check "$output/go2rtc" "$expected" && check "$output/go2rtc.LICENSE" "$SHA256_LICENSE" && [ "$run_tests" -eq 0 ]; then
    chmod 0755 "$output/go2rtc"
    printf '%s\n' "$stamp" >"$output/go2rtc.version"
    echo "go2rtc: $output/go2rtc matches the pinned checksum ($GO2RTC_VERSION, linux/$arch)"
    exit 0
fi
[ "$verify_only" -eq 0 ] || die "$output/go2rtc (or go2rtc.LICENSE) is missing or does not match the pinned checksum"
command -v docker >/dev/null || die "Docker is required to build go2rtc"

mkdir -p "$output"
output=$(cd "$output" && pwd)
rm -f "$output/go2rtc.partial" "$output/go2rtc.LICENSE.partial"
docker volume create "$CACHE_VOLUME" >/dev/null
docker image inspect "$GO_IMAGE" >/dev/null 2>&1 || docker pull -q "$GO_IMAGE" >/dev/null

echo "go2rtc: building $GO2RTC_VERSION (commit ${GO2RTC_COMMIT:0:12}) for linux/$arch with ${GO_IMAGE%@*}"
# The container runs on the machine's own architecture and Go cross-compiles (GOARCH), so no emulation is involved.
docker run --rm \
    -v "$CACHE_VOLUME":/cache -v "$output":/out \
    -e GOMODCACHE=/cache/mod -e GOCACHE=/cache/build -e GOTOOLCHAIN=local -e GOFLAGS=-mod=readonly \
    -e COMMIT="$GO2RTC_COMMIT" -e URL="$SOURCE_URL" -e TARGET_ARCH="$arch" -e RUN_TESTS="$run_tests" \
    -e OWNER="$(id -u):$(id -g)" \
    "$GO_IMAGE" bash -c '
        set -euo pipefail
        git config --global advice.detachedHead false
        git init -q /src && cd /src
        git fetch -q --depth 1 "$URL" "$COMMIT"
        git checkout -q --detach FETCH_HEAD
        [ "$(git rev-parse HEAD)" = "$COMMIT" ] || { echo "go2rtc: fetched commit is not $COMMIT" >&2; exit 1; }
        go mod download
        go mod verify
        if [ "$RUN_TESTS" = 1 ]; then
            go vet ./pkg/tutk/... ./pkg/wyze/... ./internal/wyze/...
            go test -count=1 ./pkg/tutk/... ./pkg/wyze/... ./internal/wyze/...
        fi
        CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" go build -trimpath -buildvcs=true -ldflags "-s -w -buildid=" -o /out/go2rtc.partial .
        install -m 0644 LICENSE /out/go2rtc.LICENSE.partial
        chown "$OWNER" /out/go2rtc.partial /out/go2rtc.LICENSE.partial'

got=$(sha256_of "$output/go2rtc.partial")
if [ "$got" != "$expected" ]; then
    rm -f "$output/go2rtc.partial" "$output/go2rtc.LICENSE.partial"
    die "CHECKSUM MISMATCH for linux/$arch: expected $expected, got $got. Nothing was installed."
fi
got=$(sha256_of "$output/go2rtc.LICENSE.partial")
if [ "$got" != "$SHA256_LICENSE" ]; then
    rm -f "$output/go2rtc.partial" "$output/go2rtc.LICENSE.partial"
    die "CHECKSUM MISMATCH for LICENSE: expected $SHA256_LICENSE, got $got. Nothing was installed."
fi
chmod 0755 "$output/go2rtc.partial"
mv "$output/go2rtc.partial" "$output/go2rtc"
mv "$output/go2rtc.LICENSE.partial" "$output/go2rtc.LICENSE"
printf '%s\n' "$stamp" >"$output/go2rtc.version"
echo "go2rtc: wrote $output/go2rtc ($(wc -c <"$output/go2rtc" | tr -d ' ') bytes, sha256 $expected)"
