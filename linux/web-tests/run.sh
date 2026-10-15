#!/bin/sh
# Runs every test under linux/web-tests/ with Node's own runner (no npm, no install): sh linux/web-tests/run.sh [node --test options]
# The fixture clips are made first (they need ffmpeg; tests that need them skip, with the reason, when they cannot be made).
set -eu
cd "$(dirname "$0")/../.."
[ -s linux/web-dev/fixtures/gop2.mp4 ] || sh linux/web-dev/make-fixtures.sh || echo "run.sh: no fixtures; tests that need them will be skipped." >&2
exec node --test "$@" "linux/web-tests/**/*.test.mjs"
