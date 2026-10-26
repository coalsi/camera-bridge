#!/bin/bash
# Self-test of cb-recording-drive (mkosi.extra/usr/sbin/cb-recording-drive): the recording drive's and the archive drive's forms against stand-ins
# for lsblk, blkid, blockdev, findmnt, mountpoint, mount, umount, wipefs, sfdisk, mkfs.ext4, udevadm and systemctl, over a made-up set of disks
# (a fake table that the stand-ins read and change). No root, no disk, no systemd. Needs bash, jq, awk and sed. Runs in the static checks job.
# What it cannot show (a real mount, the read-only placeholder refusing a write, the engine's sandbox) is test-vm.sh's recording-drive test.
#
#   bash linux/os/test-recording-drive.sh
# shellcheck disable=SC2016
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/mkosi.extra/usr/sbin/cb-recording-drive
LIB=$HERE/mkosi.extra/usr/lib/camera-bridge/lib.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

pass() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
expect() { # expect DESCRIPTION ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        expected: %s\n        actual:   %s\n' "$3" "$2"; fi
}
contains() { # contains DESCRIPTION TEXT PART
    case $2 in *"$3"*) pass "$1" ;; *) bad "$1"; printf '        expected to contain: %s\n        actual: %s\n' "$3" "$2" ;; esac
}

[ -x "$SCRIPT" ] || bad "cb-recording-drive is missing or not executable"

# --- the fake machine ------------------------------------------------------------------------------------------------------
FAKE=$tmp/fake BIN=$tmp/bin ROOT=$tmp/root
mkdir -p "$FAKE" "$BIN" "$ROOT/data" "$ROOT/system" "$ROOT/run/status"
export FAKE
GIB=1073741824
# sda: the disk the system runs from. sdb: the owner's archive drive as the coordinator made it (one GPT partition, ext4 CBARCHIVE, not mounted,
# nothing chosen). sdc: a recording drive. sdd: a stick too small. sde: an empty 1 TB disk, not plugged in yet.
jq -n --argjson g "$GIB" '{blockdevices: [
  {kname: "sda", path: "/dev/sda", type: "disk", size: 476000000000, model: "SATA SSD", serial: "S0", tran: "sata", rm: false, present: true, children: [
    {kname: "sda1", path: "/dev/sda1", type: "part", size: 536870912, fstype: "vfat", label: null, uuid: "AAAA-0001", partlabel: "esp"},
    {kname: "sda2", path: "/dev/sda2", type: "part", size: (8 * $g), fstype: "erofs", label: null, uuid: "root-a", partlabel: "root-a"},
    {kname: "sda3", path: "/dev/sda3", type: "part", size: (400 * $g), fstype: "ext4", label: null, uuid: "data-0", partlabel: "cb-data"}]},
  {kname: "sdb", path: "/dev/sdb", type: "disk", size: 4000787030016, model: "Expansion HDD", serial: "NAAB1", tran: "usb", rm: false, present: true, children: [
    {kname: "sdb1", path: "/dev/sdb1", type: "part", size: 4000785960960, fstype: "ext4", label: "CBARCHIVE", uuid: "arch-1111", partlabel: null}]},
  {kname: "sdc", path: "/dev/sdc", type: "disk", size: (500 * $g), model: "Portable SSD", serial: "T7", tran: "usb", rm: false, present: true, children: [
    {kname: "sdc1", path: "/dev/sdc1", type: "part", size: (500 * $g), fstype: "ext4", label: "CBRECORDINGS", uuid: "rec-2222", partlabel: null}]},
  {kname: "sdd", path: "/dev/sdd", type: "disk", size: (32 * $g), model: "Stick", serial: "U1", tran: "usb", rm: true, present: true, children: []},
  {kname: "sde", path: "/dev/sde", type: "disk", size: 1000204886016, model: "Spare HDD", serial: "W1", tran: "usb", rm: false, present: false, children: []}
]}' >"$FAKE/disks.json"
# The mounts: "SOURCE TARGET TYPE OPTIONS", the last one of a target on top.
printf '%s\n' "/dev/sda2 / erofs ro" "/dev/sda3 /srv ext4 rw" "/dev/sda1 /efi vfat rw" "/dev/sda3[/camera-bridge] /var/lib/camera-bridge ext4 rw" >"$FAKE/mounts"
: >"$FAKE/calls"

cat >"$BIN/fake-lib" <<'STUB'
# Shared by the stand-ins: the fake table and the device a call is about.
J=$FAKE/disks.json
present() { jq -e --arg p "$1" '[.blockdevices[] | select(.present) | ., (.children[])] | any(.path == $p)' "$J" >/dev/null; }
node() { jq -c --arg p "$1" '[.blockdevices[] | ., (.children[] + {pkname: (.path | ltrimstr("/dev/") | sub("[0-9]+$"; ""))})] | map(select(.path == $p)) | .[0] // empty' "$J"; }
family() { jq -c --arg p "$1" '.blockdevices[] | select(.path == $p) | ., (.children[])' "$J"; }
STUB
cat >"$BIN/lsblk" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/fake-lib"
args="$*" dev="${*: -1}"
case $args in
    -J*) jq '{blockdevices: [.blockdevices[] | select(.present) | {name: .kname, kname, path, type, size, model, serial, tran, rm, ro: false,
                fstype: null, label: null, uuid: null, partlabel: null, mountpoints: [null], pkname: null,
                children: [.children[] | {name: .kname, kname, path, type, size, fstype, label, uuid, partlabel, mountpoints: [null], pkname: null}]}]}' "$J" ;;
    "-dno TYPE "*) present "$dev" && node "$dev" | jq -r '.type' ;;
    "-dno PKNAME "*) present "$dev" && node "$dev" | jq -r '.pkname // empty' ;;
    "-nro MOUNTPOINTS "*) present "$dev" || exit 1
        for p in $(family "$dev" | jq -r '.path'); do awk -v p="$p" '$1 == p {print $2}' "$FAKE/mounts"; done ;;
    "-nrpo PATH,FSTYPE,LABEL "*) present "$dev" && family "$dev" | jq -r '"\(.path) \(.fstype // "") \(.label // "")"' ;;
    "-nro UUID "*) present "$dev" && family "$dev" | jq -r '.uuid // ""' ;;
    *) echo "lsblk stand-in: unexpected $args" >&2; exit 64 ;;
esac
STUB
cat >"$BIN/blkid" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/fake-lib"
case "$1" in
    -U) jq -r --arg u "$2" '.blockdevices[] | select(.present) | .children[] | select(.uuid == $u) | .path' "$J" | grep . || exit 2 ;;
    -s) present "$5" && node "$5" | jq -r '.uuid // empty' ;;
    *) exit 64 ;;
esac
STUB
cat >"$BIN/blockdev" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/fake-lib"
case "$1" in
    --getro) echo 0 ;;
    --getsize64) node "$2" | jq -r '.size' ;;
esac
STUB
cat >"$BIN/findmnt" <<'STUB'
#!/bin/bash
# findmnt -n -o SOURCE --target PATH | --mountpoint PATH
case "$4" in
    --mountpoint) awk -v t="$5" '$2 == t {s = $1} END {if (s != "") print s}' "$FAKE/mounts" ;;
    --target) awk -v t="$5" 'BEGIN {best = ""; len = -1} { if ((t == $2 || index(t, $2 "/") == 1 || $2 == "/") && length($2) > len) { best = $1; len = length($2) } } END {print best}' "$FAKE/mounts" ;;
esac
STUB
cat >"$BIN/mountpoint" <<'STUB'
#!/bin/bash
awk -v t="$2" '$2 == t {found = 1} END {exit found ? 0 : 1}' "$FAKE/mounts"
STUB
cat >"$BIN/mount" <<'STUB'
#!/bin/bash
# mount -t TYPE -o OPTIONS SOURCE TARGET
echo "mount $*" >>"$FAKE/calls"
printf '%s %s %s %s\n' "$5" "$6" "$2" "$4" >>"$FAKE/mounts"
STUB
cat >"$BIN/umount" <<'STUB'
#!/bin/bash
echo "umount $*" >>"$FAKE/calls"
target="${*: -1}"
awk -v t="$target" '{lines[NR] = $0; if ($2 == t) last = NR} END {for (i = 1; i <= NR; i++) if (i != last) print lines[i]}' "$FAKE/mounts" >"$FAKE/mounts.new"
mv "$FAKE/mounts.new" "$FAKE/mounts"
STUB
cat >"$BIN/sfdisk" <<'STUB'
#!/bin/bash
# sfdisk --quiet --wipe always DEVICE (the table on stdin): one partition over the whole disk.
cat >/dev/null
dev="${*: -1}"
echo "sfdisk $dev" >>"$FAKE/calls"
jq --arg p "$dev" '.blockdevices |= map(if .path == $p then .children = [{kname: (.kname + "1"), path: (.path + "1"), type: "part", size: (.size - 1048576), fstype: null, label: null, uuid: null, partlabel: null}] else . end)' "$FAKE/disks.json" >"$FAKE/disks.new"
mv "$FAKE/disks.new" "$FAKE/disks.json"
STUB
cat >"$BIN/mkfs.ext4" <<'STUB'
#!/bin/bash
# mkfs.ext4 -q -F -L LABEL -m 0 -T largefile PARTITION
echo "mkfs.ext4 $*" >>"$FAKE/calls"
label="" part="${*: -1}"
while [ $# -gt 0 ]; do case $1 in -L) label=$2; shift ;; esac; shift; done
jq --arg p "$part" --arg l "$label" '.blockdevices |= map(.children |= map(if .path == $p then .fstype = "ext4" | .label = $l | .uuid = ("new-" + $l) else . end))' "$FAKE/disks.json" >"$FAKE/disks.new"
mv "$FAKE/disks.new" "$FAKE/disks.json"
STUB
for tool in wipefs udevadm systemctl; do printf '#!/bin/bash\necho "%s $*" >>"$FAKE/calls"\n' "$tool" >"$BIN/$tool"; done
printf '#!/bin/bash\nexit 0\n' >"$BIN/logger"
printf '#!/bin/bash\nexit 0\n' >"$BIN/sleep"
printf '#!/bin/bash\nexit 0\n' >"$BIN/chown"
printf '#!/bin/bash\nexit 0\n' >"$BIN/swapon"
cat >"$BIN/install" <<'STUB'
#!/bin/bash
# install -d [-m MODE] [-o USER] [-g GROUP] DIRECTORY: the folder only (no owner change without root).
mkdir -p "${*: -1}"
STUB
chmod +x "$BIN"/*

# A copy of the script that needs no root, reads lib.sh from the repository, keeps its folders under $ROOT and asks the fake table whether a device exists.
sed -e "s#^export PATH=.*#export PATH=$BIN:\$PATH#" \
    -e "s#^\. /usr/lib/camera-bridge/lib.sh#. $LIB; CB_RUN=$ROOT/run; CB_STATUS=$ROOT/run/status; CB_DATA=$ROOT/data; CB_SYSTEM=$ROOT/system; fake_block() { . $BIN/fake-lib; present \"\$1\"; }#" \
    -e 's/^\[ "\$(id -u)" -eq 0 \].*$/true/' \
    -e 's/\[ -b \("\$[a-z]*"\) \]/fake_block \1/g' \
    "$SCRIPT" >"$tmp/cb-recording-drive"
# (fake_block PATH, defined with the folders: the device is in the fake table and plugged in.)
grep -q 'fake_block() {' "$tmp/cb-recording-drive" || bad "the test copy has its fake_block"
! grep -q '\[ -b ' "$tmp/cb-recording-drive" || bad "every block-device test of the script goes to the fake table"

drive() { bash "$tmp/cb-recording-drive" "$@" 2>&1; }
status() { jq -r "$2" "$ROOT/run/status/$1.json" 2>/dev/null; }
calls() { cat "$FAKE/calls"; }
reset_calls() { : >"$FAKE/calls"; }
mounted_on() { awk -v t="$1" '$2 == t {s = $1 " " $3 " " $4} END {print s}' "$FAKE/mounts"; }
plug() { jq --arg p "$1" --argjson v "$2" '.blockdevices |= map(if .path == $p then .present = $v else . end)' "$FAKE/disks.json" >"$FAKE/disks.new"; mv "$FAKE/disks.new" "$FAKE/disks.json"; }
ARCHIVE=$ROOT/data/archive RECORDINGS=$ROOT/data/recordings

# --- the list --------------------------------------------------------------------------------------------------------------
list=$(drive --list --json)
disk() { jq -c --arg n "$1" ".disks[] | select(.name == \$n) | $2" <<<"$list"; }
expect "the list has the plugged-in disks" "$(jq -c '[.disks[].name]' <<<"$list")" '["sda","sdb","sdc","sdd"]'
expect "the disk the system runs from is refused in both views" "$(disk sda '[.eligible, .archiveEligible, (.problems | any(test("running from")))]')" '[false,false,true]'
expect "the coordinator's drive is an archive drive, usable for both, in use for neither" \
    "$(disk sdb '[.isArchiveDrive, .isRecordingDrive, .archiveEligible, .eligible, .archiveInUse, .inUse]')" '[true,false,true,true,false,false]'
expect "a recording drive is one" "$(disk sdc '[.isRecordingDrive, .isArchiveDrive]')" '[true,false]'
expect "a stick is too small" "$(disk sdd '.archiveProblems')" '["smaller than 64 GiB"]'
expect "each disk has its sentence" "$(disk sdb '.phrase')" '"ERASE ALL DATA ON sdb"'
contains "the text list of the archive form names an archive drive" "$(drive --archive --list)" "already an archive drive"

# --- refusals: nothing is written ------------------------------------------------------------------------------------------
reset_calls
contains "the boot disk is refused" "$(drive --archive --device /dev/sda --confirm "ERASE ALL DATA ON sda" || true)" "this is the disk the system is running from"
contains "a wrong sentence is refused" "$(drive --archive --device /dev/sdb --confirm "yes please" || true)" "the confirmation sentence does not match"
contains "no sentence at all is refused" "$(drive --archive --device /dev/sdb || true)" "the confirmation sentence does not match"
contains "a partition is refused" "$(drive --archive --device /dev/sdb1 --keep || true)" "not a disk this system can use"
contains "a stick is refused" "$(drive --archive --device /dev/sdd --keep || true)" "smaller than 64 GiB"
contains "keeping a disk that is no archive drive is refused" "$(drive --archive --device /dev/sdc --keep || true)" "not a Camera Bridge archive drive"
contains "an unplugged disk is refused" "$(drive --archive --device /dev/sde --confirm "ERASE ALL DATA ON sde" || true)" "not a block device"
expect "a refusal wrote nothing" "$(calls)" ""
expect "a refusal chose nothing" "$(ls "$ROOT/system")" ""
expect "a refusal says so in the status" "$(status archive-drive .state)" "failed"

# --- --keep: exactly the drive the coordinator prepared ------------------------------------------------------------------
reset_calls
drive --archive --device /dev/sdb --keep >/dev/null
expect "the choice is the partition's file system UUID" "$(cat "$ROOT/system/archive-drive")" "arch-1111"
expect "it is mounted where the engine looks, noexec" "$(mounted_on "$ARCHIVE")" "/dev/sdb1 ext4 nodev,nosuid,noexec,noatime"
expect "the marker names the drive" "$(jq -c . "$ARCHIVE/.camera-bridge-archive")" '{"uuid":"arch-1111"}'
expect "the status says mounted" "$(status archive-drive '[.state, .uuid] | join(" ")')" "mounted arch-1111"
expect "nothing was erased, and the engine was neither stopped nor restarted" "$(calls | grep -cE '^(wipefs|sfdisk|mkfs|systemctl)' || true)" "0"
expect "the recordings folder is left alone" "$(mounted_on "$RECORDINGS")" ""
reset_calls
drive --archive --apply >/dev/null
expect "applying again mounts nothing more" "$(calls | grep -c '^mount' || true)" "0"
expect "and keeps it mounted" "$(status archive-drive .state)" "mounted"
list=$(drive --list --json)
expect "the list shows it in use as the archive" "$(disk sdb '[.archiveInUse, .archiveEligible, .inUse]')" '[true,true,false]'
expect "as a recording drive it is refused: it is mounted for the archive" "$(disk sdb '.eligible')" 'false'
contains "the archive drive cannot become the recording drive" "$(drive --device /dev/sdb --keep || true)" "can't be used"
if [ ! -e "$ROOT/system/recording-drive" ]; then pass "and nothing was chosen for it"; else bad "the archive drive was chosen as the recording drive"; fi

# --- unplugged and plugged in again ----------------------------------------------------------------------------------------
plug /dev/sdb false
reset_calls
drive --archive --apply >/dev/null
expect "unplugged: a read-only placeholder in its place" "$(mounted_on "$ARCHIVE")" "cb-archive-drive-missing tmpfs ro,size=64k,mode=0555,nodev,nosuid,noexec"
expect "the status says missing" "$(status archive-drive .state)" "missing"
expect "the engine was not restarted for it" "$(calls | grep -c '^systemctl' || true)" "0"
drive --archive --apply >/dev/null
expect "applying again keeps one placeholder" "$(awk -v t="$ARCHIVE" '$2 == t' "$FAKE/mounts" | wc -l | tr -d ' ')" "1"
plug /dev/sdb true
drive --archive --apply >/dev/null
expect "plugged in again: the drive is back, the placeholder gone" "$(awk -v t="$ARCHIVE" '$2 == t {print $1}' "$FAKE/mounts" | tr '\n' ' ')" "/dev/sdb1 "
expect "mounted again" "$(status archive-drive .state)" "mounted"

# --- the recording drive and the archive drive refuse each other --------------------------------------------------------------
reset_calls
drive --device /dev/sdc --keep >/dev/null
expect "the recording drive's form is as before: chosen, mounted on the recordings, the engine stopped and started" \
    "$(cat "$ROOT/system/recording-drive") | $(mounted_on "$RECORDINGS") | $(calls | grep '^systemctl' | tr '\n' ';')" \
    "rec-2222 | /dev/sdc1 ext4 nodev,nosuid,noexec,noatime | systemctl stop camerabridged.service;systemctl start camerabridged.service;"
reset_calls
contains "the recording drive cannot become the archive drive" "$(drive --archive --device /dev/sdc --confirm "ERASE ALL DATA ON sdc" || true)" "can't be used"
"$BIN/umount" -l "$RECORDINGS"
contains "not even while it is unplugged from its folder" "$(drive --archive --device /dev/sdc --confirm "ERASE ALL DATA ON sdc" || true)" "that disk is the recording drive"
expect "neither refusal erased anything" "$(calls | grep -cE '^(wipefs|sfdisk|mkfs)' || true)" "0"
expect "the archive is still the coordinator's drive" "$(cat "$ROOT/system/archive-drive")" "arch-1111"

# --- erasing a new disk for the archive ------------------------------------------------------------------------------------------
plug /dev/sde true
reset_calls
drive --archive --device /dev/sde --confirm "ERASE ALL DATA ON sde" >/dev/null
expect "the disk is erased, partitioned and made ext4 CBARCHIVE like a recording drive" \
    "$(calls | grep -E '^(wipefs|sfdisk|mkfs)' | tr '\n' ';')" "wipefs -a -f /dev/sde;sfdisk /dev/sde;mkfs.ext4 -q -F -L CBARCHIVE -m 0 -T largefile /dev/sde1;"
expect "it is the archive now" "$(cat "$ROOT/system/archive-drive") | $(mounted_on "$ARCHIVE")" "new-CBARCHIVE | /dev/sde1 ext4 nodev,nosuid,noexec,noatime"
expect "the marker follows the drive" "$(jq -r .uuid "$ARCHIVE/.camera-bridge-archive")" "new-CBARCHIVE"
expect "the engine was not stopped: it did not have this disk open" "$(calls | grep -c '^systemctl' || true)" "0"
reset_calls
drive --archive --device /dev/sde --confirm "ERASE ALL DATA ON sde" >/dev/null
expect "erasing the archive in use quiets the engine first and starts it after" "$(calls | grep '^systemctl' | tr '\n' ';')" \
    "systemctl stop camerabridged.service;systemctl start camerabridged.service;"

# --- forgetting it ---------------------------------------------------------------------------------------------------------------
reset_calls
drive --archive --forget >/dev/null
if [ ! -e "$ROOT/system/archive-drive" ]; then pass "forgetting removes the choice"; else bad "the choice is still there"; fi
expect "nothing is mounted on the archive's folder" "$(mounted_on "$ARCHIVE")" ""
expect "the status says none" "$(status archive-drive .state)" "none"
expect "the drive itself is not touched, and the engine is not restarted" "$(calls | grep -cE '^(wipefs|sfdisk|mkfs|systemctl)' || true)" "0"
drive --archive --apply >/dev/null
expect "applying with none chosen mounts nothing" "$(mounted_on "$ARCHIVE")" ""
contains "the help names the archive form" "$(drive --help)" "--archive FORM"

# --- the wiring ------------------------------------------------------------------------------------------------------------------
X=$HERE/mkosi.extra
check() { # check DESCRIPTION COMMAND...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else bad "$desc"; fi
}
check "cb-system allows and handles the archive requests, as heavy jobs" bash -c "s='$X/usr/sbin/cb-system'; grep -q '^ALLOWED_JOBS=\".*\\barchive-use\\b.*\\barchive-forget\\b' \$s && grep -q '^HEAVY_JOBS=\".* archive-use archive-forget ' \$s && grep -q 'cb-recording-drive --archive --device' \$s && grep -q 'cb-recording-drive --archive --forget' \$s"
check "the archive drive is put in place at boot, before the engine, and the engine only wants it" bash -c "u='$X/usr/lib/systemd/system/camera-bridge-archive-drive.service'; grep -q '^ExecStart=/usr/sbin/cb-recording-drive --archive --apply$' \$u && grep -q '^Before=camerabridged.service' \$u && grep -q '^Wants=camera-bridge-archive-drive.service' '$X/usr/lib/systemd/system/camerabridged.service.d/30-archive-drive.conf' && ! grep -q '^Requires=' '$X/usr/lib/systemd/system/camerabridged.service.d/30-archive-drive.conf' && grep -q 'camera-bridge-archive-drive.service' '$HERE/mkosi.postinst.chroot'"
check "a CBARCHIVE partition that appears is mounted (udev), without restarting the engine" bash -c "grep -q 'ENV{ID_FS_LABEL}==\"CBARCHIVE\".*camera-bridge-archive-drive-plug.service' '$X/usr/lib/udev/rules.d/60-camera-bridge-archive-drive.rules' && grep -q '^ExecStart=/usr/sbin/cb-recording-drive --archive --apply$' '$X/usr/lib/systemd/system/camera-bridge-archive-drive-plug.service'"
check "the engine may write the archive's folder (inside its ReadWritePaths)" bash -c "grep -q '^ReadWritePaths=/var/lib/camera-bridge ' '$HERE/units/camerabridged.service.in'"

[ "$fail" -eq 0 ] && echo "all passed"
exit "$fail"
