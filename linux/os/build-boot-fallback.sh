#!/bin/bash
# Builds camera-bridge-boot-fallback, a Debian package of our own that only mkosi's default initrd installs (InitrdPackages= in mkosi.conf): the
# unit that restarts a box stopped in emergency or rescue mode after 30 seconds and the drop-ins of emergency.target and rescue.target that pull
# it in, the same files the system has in mkosi.extra. mkosi's default initrd takes packages, not files; build-image.sh runs this into the folder
# it gives mkosi as --package-directory, which mkosi makes a local package repository of (with reprepro, in Dockerfile.builder).
#
#   linux/os/build-boot-fallback.sh --version V --out DIR      writes DIR/camera-bridge-boot-fallback_V_all.deb (needs dpkg-deb)
set -euo pipefail
umask 022

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNITS=$HERE/mkosi.extra/usr/lib/systemd/system
FILES=(camera-bridge-emergency-reboot.service emergency.target.d/10-camera-bridge.conf rescue.target.d/10-camera-bridge.conf)

version="" out=""
die() { echo "boot-fallback: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
    case $1 in
        --version) version=${2:-}; shift ;;
        --out) out=${2:-}; shift ;;
        -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "--version must look like 0.1 or 1.2.3 (digits and dots)"
[ -n "$out" ] || die "--out is required"
command -v dpkg-deb >/dev/null || die "dpkg-deb is required (run it in the build container)"

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
chmod 0755 "$root"   # the package's own "./": a folder only root could read would be wrong for the initrd's /
for f in "${FILES[@]}"; do
    [ -s "$UNITS/$f" ] || die "no $UNITS/$f"
    install -D -m 0644 "$UNITS/$f" "$root/usr/lib/systemd/system/$f"
done
install -d -m 0755 "$root/DEBIAN"
cat >"$root/DEBIAN/control" <<EOF
Package: camera-bridge-boot-fallback
Version: $version
Architecture: all
Maintainer: Camera Bridge OS build
Section: admin
Priority: optional
Description: restart a Camera Bridge OS box that stops in emergency or rescue mode
 Installed only into the initrd of the Camera Bridge OS image: a boot that stops
 there restarts after 30 seconds, so boot counting can try again and fall back.
EOF
mkdir -p "$out"
dpkg-deb --root-owner-group --build "$root" "$out/camera-bridge-boot-fallback_${version}_all.deb" >/dev/null
echo "boot-fallback: wrote $out/camera-bridge-boot-fallback_${version}_all.deb"
