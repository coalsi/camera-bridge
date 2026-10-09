#!/bin/bash
# Fetches the go2rtc helper (MIT, github.com/AlexxIT/go2rtc), checks it against the SHA-256 pinned below, and writes a universal
# macOS binary to build/helpers/go2rtc. The app bundles it as Contents/Helpers/go2rtc (Tools/embed-go2rtc.sh, run by the build);
# a build without the file simply has no streaming helper.
#
#   Tools/fetch-go2rtc.sh                    fetch (or reuse the verified cache) and build build/helpers/go2rtc
#   Tools/fetch-go2rtc.sh --verify           check the cached downloads and the built binary; fetch nothing
#   Tools/fetch-go2rtc.sh --output DIR       write DIR/go2rtc instead of build/helpers/go2rtc
#
# Environment:
#   CB_GO2RTC_BASE_URL   where the release files are (default: the official GitHub release for the pinned version). The pinned
#                        checksums still decide: a mirror cannot change what is accepted.
#   CB_GO2RTC_CACHE      where downloads are kept (default: build/helpers/cache)
#
# To update go2rtc: change VERSION and both checksums (the "digest" values of the release assets, which GitHub shows next to each file;
# check them against the downloaded files before committing), update docs/third-party/go2rtc.md, and run the helper tests.
set -euo pipefail

VERSION="1.9.14"
SHA256_ARM64="919b78adc759d6b3883d1e1b2ac915ac0985bb903ff1897b4d228527bd64690c"   # go2rtc_mac_arm64.zip
SHA256_AMD64="9b0b9a27a4dc3a5b8b93376e7e8fc2787c6af624a512842622be84aec0171c7a"   # go2rtc_mac_amd64.zip

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${CB_GO2RTC_BASE_URL:-https://github.com/AlexxIT/go2rtc/releases/download/v${VERSION}}"
CACHE="${CB_GO2RTC_CACHE:-$ROOT/build/helpers/cache}"
OUTPUT="$ROOT/build/helpers"
VERIFY_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) VERIFY_ONLY=1 ;;
    --output) shift; OUTPUT="${1:?--output needs a folder}" ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# check FILE EXPECTED: succeeds when the file's SHA-256 equals EXPECTED.
check() { [ -f "$1" ] && [ "$(sha256_of "$1")" = "$2" ]; }

fetch() {  # fetch NAME EXPECTED
  local name="$1" expected="$2" file="$CACHE/$1"
  if check "$file" "$expected"; then
    echo "go2rtc: $name is in the cache and matches the pinned checksum"
    return 0
  fi
  [ "$VERIFY_ONLY" = 1 ] && { echo "go2rtc: $name is missing or does not match the pinned checksum" >&2; return 1; }
  mkdir -p "$CACHE"
  local partial="$file.partial"
  rm -f "$partial"
  echo "go2rtc: downloading $name ($VERSION)"
  curl --fail --silent --show-error --location --proto '=https,file' --max-time 300 --output "$partial" "$BASE_URL/$name"
  if ! check "$partial" "$expected"; then
    echo "go2rtc: CHECKSUM MISMATCH for $name: expected $expected, got $(sha256_of "$partial"). Nothing was installed." >&2
    rm -f "$partial"
    return 1
  fi
  mv "$partial" "$file"
}

fetch "go2rtc_mac_arm64.zip" "$SHA256_ARM64"
fetch "go2rtc_mac_amd64.zip" "$SHA256_AMD64"

BINARY="$OUTPUT/go2rtc"
STAMP="$OUTPUT/go2rtc.version"
WANT="$VERSION $SHA256_ARM64 $SHA256_AMD64"
if [ -x "$BINARY" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$WANT" ]; then
  echo "go2rtc: $BINARY is up to date ($VERSION)"
  exit 0
fi
[ "$VERIFY_ONLY" = 1 ] && { echo "go2rtc: $BINARY is missing or out of date" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/go2rtc.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/arm64" "$WORK/amd64"
unzip -q -o "$CACHE/go2rtc_mac_arm64.zip" -d "$WORK/arm64"
unzip -q -o "$CACHE/go2rtc_mac_amd64.zip" -d "$WORK/amd64"
[ -f "$WORK/arm64/go2rtc" ] && [ -f "$WORK/amd64/go2rtc" ] || { echo "go2rtc: the archives do not hold a go2rtc file" >&2; exit 1; }

mkdir -p "$OUTPUT"
lipo -create "$WORK/arm64/go2rtc" "$WORK/amd64/go2rtc" -output "$WORK/go2rtc"
chmod 755 "$WORK/go2rtc"
mv "$WORK/go2rtc" "$BINARY"
printf '%s\n' "$WANT" > "$STAMP"
echo "go2rtc: wrote $BINARY ($(lipo -archs "$BINARY"))"
