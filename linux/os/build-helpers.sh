#!/bin/bash
# Builds Camera Bridge's own helper programs for Camera Bridge OS from linux/helpers/, each with its own build script (Docker,
# toolchain images pinned by digest), and checks the results. build.sh runs it after fetch-go2rtc.sh; build-image.sh installs
# what it leaves in the helpers folder:
#
#   wyze-lake     (Go, ours, MIT)  linux/helpers/wyze-lake      -> /usr/lib/camera-bridge/helpers/wyze-lake
#   eufy-bridge   (Node.js + the eufy SDK, Apache-2.0)          -> /usr/lib/camera-bridge/helpers/eufy/ and the launcher
#                 linux/helpers/eufy-bridge, amd64 only            /usr/lib/camera-bridge/helpers/eufy-bridge
#
#   linux/os/build-helpers.sh --arch amd64|arm64 [--output DIR]   build (or reuse verified results); default DIR: build/os-helpers/<arch>
#   linux/os/build-helpers.sh --arch amd64 --verify               check what DIR holds against the sources and pins; build nothing
#
# Writes into DIR:
#   wyze-lake (0755), wyze-lake.version (the stamp), wyze-lake.doc/ (LICENSE, NOTICE, LICENSES/: its Go modules' licences)
#   eufy/ (node, eufy-bridge.js, package.json, LICENSES/, VERSION), eufy-bridge.version (the stamp), eufy-bridge (the launcher,
#   0755: execs CB_HELPERS_DIR/eufy/node with the bundle); amd64 only
#
# Checks: wyze-lake's modules against go.sum, go vet and its tests, then the binary is an ELF file of the right architecture
# (and prints the pinned version where the build container can run it). eufy-bridge's lockfile pins the SDK version, its tests
# pass, Node.js is the official release binary (tarball SHA-256 and SHASUMS256.txt, then the binary's own SHA-256, all pinned in
# linux/helpers/eufy-bridge/pins.env; checked again here and in build-image.sh). A stamp records the SHA-256 of the sources
# (every file of the helper's folder but out/, node_modules/), the pins and the result; a later run reuses a result whose stamp
# matches the current sources and whose files still match the stamp, and rebuilds otherwise. A failed check installs nothing.
#
# The eufy helper is amd64 only (the Node.js binary is pinned for linux-x64); for arm64 it is left out and the daemon says
# "This copy of Camera Bridge OS doesn't include the Eufy helper".
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
LAKE_SRC=$REPO/linux/helpers/wyze-lake
EUFY_SRC=$REPO/linux/helpers/eufy-bridge

arch="" output="" verify_only=0
die() { echo "helpers: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --arch) arch=${2:-}; shift ;;
        --output) output=${2:-}; shift ;;
        --verify) verify_only=1 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
case $arch in
    amd64) elf_machine=3e00 ;;
    arm64) elf_machine=b700 ;;
    *) die "--arch must be amd64 or arm64" ;;
esac
output=${output:-$REPO/build/os-helpers/$arch}
mkdir -p "$output"
output=$(cd "$output" && pwd)

sha256_of() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
sha256_stdin() {
    if command -v sha256sum >/dev/null; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}
# source_hash DIR: one SHA-256 over the names and contents of the helper's source files (build output and caches left out).
source_hash() {
    (cd "$1" && find . -type f ! -path './out/*' ! -path './node_modules/*' ! -path './dl-*' ! -name '.DS_Store' -print | LC_ALL=C sort |
        while IFS= read -r f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done) | sha256_stdin
}
# stamp_field FILE KEY: the value after "KEY " in a stamp line (KEY value, one per line).
stamp_field() { [ -f "$1" ] && awk -v k="$2" '$1 == k { print $2; exit }' "$1"; }
# The ELF machine field (bytes 18-19), as hex.
elf_check() {
    [ "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" = 7f454c46 ] || return 1
    [ "$(od -An -tx1 -j18 -N2 "$1" | tr -d ' \n')" = "$elf_machine" ]
}

# --- wyze-lake ---------------------------------------------------------------------------------------------------------------
# shellcheck source=../helpers/wyze-lake/pins.env
. "$LAKE_SRC/pins.env"
lake_src_hash=$(source_hash "$LAKE_SRC")
lake_stamp=$output/wyze-lake.version
lake_ok() {
    [ -f "$output/wyze-lake" ] && [ -f "$output/wyze-lake.doc/LICENSE" ] && [ -f "$output/wyze-lake.doc/NOTICE" ] || return 1
    [ "$(stamp_field "$lake_stamp" source)" = "$lake_src_hash" ] || return 1
    [ "$(stamp_field "$lake_stamp" sha256)" = "$(sha256_of "$output/wyze-lake")" ] || return 1
    elf_check "$output/wyze-lake"
}
if lake_ok; then
    chmod 0755 "$output/wyze-lake"
    echo "wyze-lake: $output/wyze-lake matches its sources ($WYZE_LAKE_VERSION, linux/$arch)"
else
    [ "$verify_only" -eq 0 ] || die "$output/wyze-lake is missing or was not built from the current linux/helpers/wyze-lake"
    command -v docker >/dev/null || die "Docker is required to build wyze-lake"
    echo "wyze-lake: building $WYZE_LAKE_VERSION for linux/$arch with ${GO_IMAGE%@*}"
    tmp=$output/.wyze-lake.build
    rm -rf "$tmp" && mkdir -p "$tmp"
    "$LAKE_SRC/build.sh" --arch "$arch" --out "$tmp"
    elf_check "$tmp/wyze-lake" || { rm -rf "$tmp"; die "the wyze-lake build is not an ELF program for linux/$arch; nothing was installed"; }
    rm -rf "$output/wyze-lake.doc"
    mkdir -p "$output/wyze-lake.doc"
    cp "$LAKE_SRC/LICENSE" "$LAKE_SRC/NOTICE" "$output/wyze-lake.doc/"
    cp -R "$LAKE_SRC/LICENSES" "$output/wyze-lake.doc/LICENSES"
    mv "$tmp/wyze-lake" "$output/wyze-lake"
    rm -rf "$tmp"
    {
        echo "name wyze-lake"
        echo "version $WYZE_LAKE_VERSION"
        echo "arch linux/$arch"
        echo "source $lake_src_hash"
        echo "toolchain $GO_IMAGE"
        echo "sha256 $(sha256_of "$output/wyze-lake")"
    } >"$lake_stamp"
    echo "wyze-lake: wrote $output/wyze-lake ($(wc -c <"$output/wyze-lake" | tr -d ' ') bytes, sha256 $(sha256_of "$output/wyze-lake"))"
fi

# --- eufy-bridge -------------------------------------------------------------------------------------------------------------
eufy_stamp=$output/eufy-bridge.version
if [ "$arch" != amd64 ]; then
    rm -rf "$output/eufy" "$output/eufy-bridge" "$eufy_stamp"
    echo "eufy-bridge: amd64 only (Node.js is pinned for linux-x64); left out of the $arch image"
    exit 0
fi
# shellcheck source=../helpers/eufy-bridge/pins.env
. "$EUFY_SRC/pins.env"
# shellcheck source=paths.env
. "$HERE/paths.env"
# The launcher the daemon starts (installed as CB_HELPERS_DIR/eufy-bridge): absolute paths, so it needs neither PATH nor a
# writable directory.
write_launcher() {
    cat >"$output/eufy-bridge.partial" <<EOF
#!/bin/sh
# Camera Bridge OS: the eufy-bridge helper, Node.js and the bundled eufy SDK in $CB_HELPERS_DIR/eufy (see its VERSION and LICENSES).
exec $CB_HELPERS_DIR/eufy/node $CB_HELPERS_DIR/eufy/eufy-bridge.js "\$@"
EOF
    chmod 0755 "$output/eufy-bridge.partial"
    mv "$output/eufy-bridge.partial" "$output/eufy-bridge"
}
eufy_src_hash=$(source_hash "$EUFY_SRC")
eufy_ok() {
    local f
    for f in node eufy-bridge.js package.json VERSION LICENSES/README.txt LICENSES/node/LICENSE; do
        [ -s "$output/eufy/$f" ] || return 1
    done
    [ "$(stamp_field "$eufy_stamp" source)" = "$eufy_src_hash" ] || return 1
    [ "$(sha256_of "$output/eufy/node")" = "$NODE_BIN_SHA256" ] || return 1
    [ "$(stamp_field "$eufy_stamp" bundle)" = "$(sha256_of "$output/eufy/eufy-bridge.js")" ] || return 1
    elf_check "$output/eufy/node"
}
if eufy_ok; then
    if [ "$verify_only" -eq 1 ]; then
        [ -x "$output/eufy-bridge" ] || die "$output/eufy-bridge (the launcher) is missing"
    else
        chmod 0755 "$output/eufy/node"
        write_launcher
    fi
    echo "eufy-bridge: $output/eufy matches its sources (node $NODE_VERSION, @mega-yfue/eufy-sdk $SDK_VERSION)"
    exit 0
fi
[ "$verify_only" -eq 0 ] || die "$output/eufy is missing or was not built from the current linux/helpers/eufy-bridge"
command -v docker >/dev/null || die "Docker is required to build eufy-bridge"
echo "eufy-bridge: building with node $NODE_VERSION and @mega-yfue/eufy-sdk $SDK_VERSION"
tmp=$output/.eufy-bridge.build
rm -rf "$tmp" && mkdir -p "$tmp"
"$EUFY_SRC/build.sh" --out "$tmp"
built=$tmp/eufy-bridge
got=$(sha256_of "$built/node")
[ "$got" = "$NODE_BIN_SHA256" ] || { rm -rf "$tmp"; die "CHECKSUM MISMATCH for node: expected $NODE_BIN_SHA256, got $got. Nothing was installed."; }
elf_check "$built/node" || { rm -rf "$tmp"; die "node is not an ELF program for linux/$arch; nothing was installed"; }
for f in eufy-bridge.js package.json VERSION LICENSES/README.txt LICENSES/node/LICENSE; do
    [ -s "$built/$f" ] || { rm -rf "$tmp"; die "the eufy-bridge build has no $f; nothing was installed"; }
done
# The image's launcher is written below (CB_HELPERS_DIR/eufy-bridge); the build's own eufy-bridge script stays out of eufy/.
rm -rf "$output/eufy"
mkdir -p "$output/eufy"
for f in node eufy-bridge.js package.json VERSION; do mv "$built/$f" "$output/eufy/$f"; done
mv "$built/LICENSES" "$output/eufy/LICENSES"
rm -rf "$tmp"
chmod 0755 "$output/eufy/node"
{
    echo "name eufy-bridge"
    echo "version $(awk 'NR == 1 { print $2 }' "$output/eufy/VERSION")"
    echo "arch linux/$arch"
    echo "source $eufy_src_hash"
    echo "node $NODE_VERSION"
    echo "node-sha256 $NODE_BIN_SHA256"
    echo "sdk @mega-yfue/eufy-sdk@$SDK_VERSION+${SDK_COMMIT:0:12}"
    echo "toolchain $NODE_IMAGE"
    echo "bundle $(sha256_of "$output/eufy/eufy-bridge.js")"
} >"$eufy_stamp"
write_launcher
echo "eufy-bridge: wrote $output/eufy and the launcher $output/eufy-bridge ($(du -sk "$output/eufy" | awk '{print $1}') KiB)"
