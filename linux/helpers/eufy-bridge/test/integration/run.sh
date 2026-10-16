#!/bin/sh
# Build the test image (Debian bookworm + ffmpeg + go2rtc @ pinned commit) and run both integration scripts on linux/amd64.
#
#   test/integration/run.sh            against out/eufy-bridge (what ./build.sh made), as root
#   test/integration/run.sh DIR        against a helpers folder in the Camera Bridge OS layout (DIR/eufy-bridge, the launcher,
#                                      and DIR/eufy/, e.g. build/os-helpers/amd64 from linux/os/build-helpers.sh), mounted
#                                      read-only at /usr/lib/camera-bridge/helpers and run as an unprivileged user on a
#                                      read-only root file system (only /tmp is writable), like the daemon's sandbox
set -u
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source-path=SCRIPTDIR/../.. source=pins.env
. ./pins.env
LAYOUT=${1:-}
if [ -n "$LAYOUT" ]; then
  if [ ! -x "$LAYOUT/eufy-bridge" ] || [ ! -x "$LAYOUT/eufy/node" ]; then echo "$LAYOUT has no eufy-bridge launcher or eufy/node"; exit 1; fi
  LAYOUT=$(cd "$LAYOUT" && pwd)
  set -- -v "$LAYOUT":/usr/lib/camera-bridge/helpers:ro --user 65534:65534 --read-only --tmpfs /tmp:exec,mode=1777 \
    -e EUFY_BRIDGE=/usr/lib/camera-bridge/helpers/eufy-bridge -e EUFY_DIR=/usr/lib/camera-bridge/helpers/eufy -e HOME=/tmp/eufy-state
else
  [ -x out/eufy-bridge/eufy-bridge ] || { echo "run ./build.sh first"; exit 1; }
  set -- -v "$PWD/out/eufy-bridge":/opt/eufy-bridge:ro
fi
docker build --platform linux/amd64 -q -t eufy-bridge-itest test/integration >/dev/null
RC=0
for t in container go2rtc; do
  echo "=== $t ==="
  docker run --rm --platform linux/amd64 "$@" -v "$PWD/test/integration":/t:ro -e NODE_VERSION="$NODE_VERSION" \
    eufy-bridge-itest sh "/t/$t.sh" || RC=1
done
exit $RC
