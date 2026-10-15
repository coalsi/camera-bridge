#!/bin/bash
# Checks a downloaded Camera Bridge OS release before anybody flashes it: the nine release files are there and nothing else,
# the signatures verify with the update key, the SHA-256 lists match, the compressed files are whole, and (with --github) the
# release page agrees with the files. Also checks the boot-test log of the workflow run that made the release.
#
#   Tools/verify-os-release.sh [--pubkey FILE] [--github [--repo OWNER/REPO]] [--facts --commit SHA --run ID] DIR VERSION
#   Tools/verify-os-release.sh --smoke-log FILE [--min-passed N] [--min-nvr N]       (FILE "-" reads standard input)
#   Tools/verify-os-release.sh --self-test
#
#   DIR        an empty folder the release was downloaded into (gh release download os-vVERSION --dir DIR)
#   VERSION    digits and dots, as in the tag os-vVERSION (0.2)
#   --pubkey   the minisign public key (default: the one baked into the image, linux/os/mkosi.extra/usr/share/camera-bridge/update-key.pub)
#   --github   also compare with the release page (needs gh signed in and jq): tag, pre-release flag, file names and sizes
#   --repo     default coalsi/camera-bridge
#   --facts    after the checks, print the block of facts the Wednesday checklist carries (needs --commit and --run)
#   --smoke-log  the log of the "Boot test in QEMU" job (gh run view --job ID --log): KVM was used, the result line says 0 failed,
#              at least N tests passed (default 62: more than the 61 of the old list), the daemon section ran and at least
#              --min-nvr (default 3: the nvr, nvr-archive and nvr-faults tests) sections with NVR in their title ran
#
# Exit status 0 only if every check passed. Works with the bash 3.2 of macOS and with Linux. Reads files; writes only to a
# temporary folder it removes; never runs anything from DIR.
# shellcheck disable=SC2001,SC2012,SC2015,SC2030,SC2031
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEFAULT_PUBKEY=$ROOT/linux/os/mkosi.extra/usr/share/camera-bridge/update-key.pub
PASSED=0
FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cb-verify.XXXXXX")

OUT=1   # where the check lines go; 2 with --facts, so that standard output carries only the facts block
ok() { echo "  ok    $*" >&"$OUT"; PASSED=$((PASSED + 1)); }
no() { echo "  FAIL  $*" >&"$OUT"; FAILED=$((FAILED + 1)); }
note() { echo "  note  $*" >&"$OUT"; }
die() { echo "error: $*" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

# The nine files the workflow attaches to a release (.github/workflows/os-image.yml, step "Create the release").
expected_files() {
    local v=$1
    printf '%s\n' \
        "SHA256SUMS" "SHA256SUMS.sig" "SOURCE-OFFER.txt" \
        "camera-bridge-os-$v-amd64.img.xz" "camera-bridge-os-$v-amd64.img.xz.sha256" "camera-bridge-os-$v-amd64.img.xz.sig" \
        "camera-bridge-os-$v-packages.txt" "cb-os_${v}_amd64.efi" "cb-os_${v}_amd64_root.raw.zst"
}

# --- the tests: they run first and fail until the checks below exist ----------------------------------------------------

# A release folder as the workflow makes it, signed with the throwaway key KEY.key (KEY.pub is its public half).
make_fixture() { # make_fixture DIR VERSION KEY
    local dir=$1 v=$2 key=$3 img
    img=camera-bridge-os-$v-amd64.img.xz
    mkdir -p "$dir"
    printf 'image %s\n' "$v" | xz -c >"$dir/$img"
    printf 'kernel %s\n' "$v" >"$dir/cb-os_${v}_amd64.efi"
    if command -v zstd >/dev/null 2>&1; then printf 'root %s\n' "$v" | zstd -q -c >"$dir/cb-os_${v}_amd64_root.raw.zst"
    else printf 'root %s\n' "$v" >"$dir/cb-os_${v}_amd64_root.raw.zst"; fi
    printf 'package list\n' >"$dir/camera-bridge-os-$v-packages.txt"
    printf 'Camera Bridge OS %s: written offer of source code\n' "$v" >"$dir/SOURCE-OFFER.txt"
    (
        cd "$dir"
        shasum -a 256 "$img" >"$img.sha256"
        shasum -a 256 "$img" "cb-os_${v}_amd64.efi" "cb-os_${v}_amd64_root.raw.zst" >SHA256SUMS
    )
    minisign -S -s "$key.key" -m "$dir/SHA256SUMS" -x "$dir/SHA256SUMS.sig" >/dev/null 2>&1
    minisign -S -s "$key.key" -m "$dir/$img" -x "$dir/$img.sig" >/dev/null 2>&1
}

SELF_PASSED=0
SELF_FAILED=0
expect() { # expect pass|fail "description" "text the output must contain" COMMAND...
    local want=$1 desc=$2 pattern=$3 out rc
    shift 3
    if out=$("$@" 2>&1); then rc=0; else rc=$?; fi
    if { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ] && grep -qF -- "$pattern" <<<"$out"; }; then
        echo "  ok    self-test: $desc"; SELF_PASSED=$((SELF_PASSED + 1))
    else
        echo "  FAIL  self-test: $desc (wanted $want, status $rc, looking for: $pattern)"; sed 's/^/          | /' <<<"$out"; SELF_FAILED=$((SELF_FAILED + 1))
    fi
}
run_verify() { ( PASSED=0; FAILED=0; verify_release "$@" || exit 1; [ "$FAILED" -eq 0 ] ); }
run_json() { ( PASSED=0; FAILED=0; compare_release_json "$@" || exit 1; [ "$FAILED" -eq 0 ] ); }
run_smoke() { ( PASSED=0; FAILED=0; check_smoke_log "$@" || exit 1; [ "$FAILED" -eq 0 ] ); }
run_facts() { # run_facts DIR VERSION KEY COMMIT RUN: the block names the image's sha256, the commit and the run, inside one fenced block
    local out
    out=$(print_facts "$@") || exit 1
    grep -q "^  sha256    $(awk '{ print $1 }' "$1/camera-bridge-os-$2-amd64.img.xz.sha256")$" <<<"$out" && grep -q "^  commit    $4$" <<<"$out" \
        && grep -q "^  run       $5 " <<<"$out" && [ "$(grep -c '^```$' <<<"$out")" -eq 2 ]
}

self_test() {
    local work v=0.2 good=$TMP/good bad
    command -v minisign >/dev/null || die "minisign is required for the self-test"
    command -v xz >/dev/null || die "xz is required for the self-test"
    work=$TMP/self
    mkdir -p "$work"
    minisign -G -W -p "$work/t.pub" -s "$work/t.key" >/dev/null 2>&1
    minisign -G -W -p "$work/o.pub" -s "$work/o.key" >/dev/null 2>&1
    printf 'untrusted comment: PLACEHOLDER minisign public key\nRWQaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"$work/placeholder.pub"
    make_fixture "$good" "$v" "$work/t"

    expect pass "a release made the way the workflow makes it passes" "" run_verify "$good" "$v" "$work/t.pub"
    expect fail "another key does not verify" "does not verify" run_verify "$good" "$v" "$work/o.pub"
    expect fail "the placeholder key is refused" "placeholder" run_verify "$good" "$v" "$work/placeholder.pub"

    bad=$work/bad-efi; cp -R "$good" "$bad"; printf 'x' >>"$bad/cb-os_${v}_amd64.efi"
    expect fail "a changed update file does not match SHA256SUMS" "does not match SHA256SUMS" run_verify "$bad" "$v" "$work/t.pub"
    bad=$work/bad-sig; cp -R "$good" "$bad"
    awk 'NR == 2 { c = substr($0, 10, 1); $0 = substr($0, 1, 9) (c == "A" ? "B" : "A") substr($0, 11) } { print }' "$good/SHA256SUMS.sig" >"$bad/SHA256SUMS.sig"
    expect fail "a damaged SHA256SUMS.sig is refused" "SHA256SUMS.sig does not verify" run_verify "$bad" "$v" "$work/t.pub"
    bad=$work/bad-img; cp -R "$good" "$bad"; printf 'x' >>"$bad/camera-bridge-os-$v-amd64.img.xz"
    expect fail "a changed image fails the image signature" "image signature does not verify" run_verify "$bad" "$v" "$work/t.pub"
    bad=$work/missing; cp -R "$good" "$bad"; rm "$bad/camera-bridge-os-$v-packages.txt"
    expect fail "a missing package list is reported" "exactly the nine" run_verify "$bad" "$v" "$work/t.pub"
    bad=$work/extra; cp -R "$good" "$bad"; printf 'x' >"$bad/notes.txt"
    expect fail "an extra file is reported" "exactly the nine" run_verify "$bad" "$v" "$work/t.pub"
    bad=$work/link; cp -R "$good" "$bad"; ln -s SHA256SUMS "$bad/SHA256SUMS.link"
    expect fail "a symbolic link is refused" "symbolic link or sub-folder" run_verify "$bad" "$v" "$work/t.pub"
    bad=$work/offer; cp -R "$good" "$bad"; printf 'Camera Bridge OS 9.9\n' >"$bad/SOURCE-OFFER.txt"
    expect fail "a source offer for another version is reported" "SOURCE-OFFER.txt" run_verify "$bad" "$v" "$work/t.pub"
    expect fail "a version that is not digits and dots is refused" "digits and dots" run_verify "$good" "0.2;rm" "$work/t.pub"

    local json=$work/release.json
    for f in "$good"/*; do echo "$(basename "$f") $(wc -c <"$f" | tr -d ' ')"; done | jq -R -s --arg v "$v" \
        '{tagName: ("os-v" + $v), isPrerelease: true, assets: (split("\n") | map(select(length > 0) | split(" ") | {name: .[0], size: (.[1] | tonumber)}))}' >"$json"
    expect pass "the release page agrees with the files" "" run_json "$json" "$good" "$v"
    jq '.isPrerelease = false' "$json" >"$work/stable.json"
    expect fail "a 0.x release that is not a pre-release is reported" "not marked pre-release" run_json "$work/stable.json" "$good" "$v"
    jq '.assets |= map(select(.name != "SOURCE-OFFER.txt"))' "$json" >"$work/short.json"
    expect fail "a missing release file is reported" "exactly the nine" run_json "$work/short.json" "$good" "$v"
    jq '.assets |= map(if .name == "cb-os_0.2_amd64.efi" then .size = 1 else . end)' "$json" >"$work/size.json"
    expect fail "a size that differs from the download is reported" "bytes there" run_json "$work/size.json" "$good" "$v"

    local log=$work/smoke.log
    printf '%s\n' 'QEMU: qemu-system-x86_64, accelerator: kvm, web UI wait limit: 300s' '==> boot 1: first boot, no SSH credential' \
        '==> the daemon (needs an image built with the real camerabridged, not --stub-daemon)' '  ok    something' \
        '==> the NVR: record, read it back over HTTP, sound, the limits of the unit' '  ok    something else' \
        '==> the NVR: a large archive, a torn recording, start-up, retention, a reboot' '==> the NVR: free space, the banner, and a power cut while recording' \
        '' 'RESULT: 130 passed, 0 failed' >"$log"
    expect pass "a boot-test log with KVM, the daemon and three NVR sections passes" "" run_smoke "$log" 62 3
    sed 's/accelerator: kvm/accelerator: tcg/' "$log" >"$work/tcg.log"
    expect fail "a log without KVM is refused" "KVM" run_smoke "$work/tcg.log" 62 3
    grep -vi 'nvr' "$log" >"$work/nonvr.log"
    expect fail "a log without an NVR section is refused" "nvr section" run_smoke "$work/nonvr.log" 62 3
    awk '/the NVR:/ { n++; if (n > 1) next } { print }' "$log" >"$work/onenvr.log"
    expect fail "a log with only one of the three NVR sections is refused" "only 1 nvr section" run_smoke "$work/onenvr.log" 62 3
    grep -v 'daemon' "$log" >"$work/nodaemon.log"
    expect fail "a log without a daemon section is refused" "daemon section" run_smoke "$work/nodaemon.log" 62 3
    sed 's/130 passed, 0 failed/129 passed, 1 failed/' "$log" >"$work/failed.log"
    expect fail "a log with a failed test is refused" "1 failed" run_smoke "$work/failed.log" 62 3
    sed 's/130 passed/61 passed/' "$log" >"$work/old.log"
    expect fail "a log with no more tests than the old list is refused" "61 passed" run_smoke "$work/old.log" 62 3
    local prefixed=$work/prefixed.log
    sed $'s/^/Boot test in QEMU\tUNKNOWN STEP\t2026-10-10T01:02:39.7457273Z /' "$log" >"$prefixed"
    expect pass "the prefix the GitHub log adds to every line is understood" "" run_smoke "$prefixed" 62 3

    expect pass "the facts block carries the image's sha256, the commit and the run" "" run_facts "$good" "$v" "$work/t.pub" 0123456789abcdef0123456789abcdef01234567 4242

    echo
    echo "SELF-TEST: $SELF_PASSED ok, $SELF_FAILED failed"
    [ "$SELF_FAILED" -eq 0 ]
}

# --- the checks ------------------------------------------------------------------------------------------------------------

# sha256 -c over a list whose names are relative to DIR. It runs from here, never from inside DIR.
sha256_check() { # sha256_check LISTFILE DIR  -> status 0 when every listed file matches
    local list=$1 dir=$2 absolute=$TMP/absolute.sums
    awk -v d="$dir" '{ print $1 "  " d "/" $2 }' "$list" >"$absolute"
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 -c "$absolute" >/dev/null 2>&1; else sha256sum -c "$absolute" >/dev/null 2>&1; fi
}

verify_release() { # verify_release DIR VERSION PUBKEY
    local dir=$1 v=$2 key=$3 name want have listed wanted_listed img efi root
    [[ $v =~ ^[0-9]+(\.[0-9]+)*$ ]] || { no "the version must be digits and dots (0.2), not '$v'"; return 0; }
    [ -d "$dir" ] || { no "$dir is not a folder"; return 0; }
    img=camera-bridge-os-$v-amd64.img.xz efi=cb-os_${v}_amd64.efi root=cb-os_${v}_amd64_root.raw.zst

    want=$(expected_files "$v" | sort)
    have=$(ls -A "$dir" | sort)
    if [ "$want" = "$have" ]; then ok "exactly the nine release files are there"
    else no "the folder does not hold exactly the nine release files:"; diff <(echo "$want") <(echo "$have") | sed 's/^/          /' >&"$OUT" || true; fi
    if [ -n "$(find "$dir" -mindepth 1 \( -type l -o -type d \))" ]; then no "the folder holds a symbolic link or sub-folder"; fi
    for name in $want; do [ ! -e "$dir/$name" ] || [ -s "$dir/$name" ] || no "$name is empty"; done

    [ -f "$key" ] || { no "no public key file: $key"; return 0; }
    if grep -q PLACEHOLDER "$key"; then no "the public key is the placeholder, not the release key"; return 0; fi
    ok "public key $(sed -n 's/^untrusted comment: minisign public key //p' "$key" | head -1)"

    if minisign -V -q -p "$key" -m "$dir/SHA256SUMS" -x "$dir/SHA256SUMS.sig" >/dev/null 2>&1; then ok "SHA256SUMS.sig verifies"
    else no "SHA256SUMS.sig does not verify with $(basename "$key")"; fi
    if minisign -V -q -p "$key" -m "$dir/$img" -x "$dir/$img.sig" >/dev/null 2>&1; then ok "the image signature verifies"
    else no "the image signature does not verify with $(basename "$key")"; fi

    listed=$(awk '{ print $2 }' "$dir/SHA256SUMS" 2>/dev/null | sort)
    wanted_listed=$(printf '%s\n' "$img" "$efi" "$root" | sort)
    if [ "$listed" = "$wanted_listed" ]; then ok "SHA256SUMS lists the image and the two update files"
    else no "SHA256SUMS lists: $(echo "$listed" | tr '\n' ' ')"; fi
    if sha256_check "$dir/SHA256SUMS" "$dir"; then ok "every file matches SHA256SUMS"; else no "a file does not match SHA256SUMS"; fi
    if sha256_check "$dir/$img.sha256" "$dir"; then ok "the image matches its .sha256 file"; else no "the image does not match its .sha256 file"; fi

    if xz -t "$dir/$img" >/dev/null 2>&1; then ok "the image is a whole xz file"; else no "the image is not a whole xz file"; fi
    if command -v zstd >/dev/null 2>&1; then
        if zstd -tq "$dir/$root" >/dev/null 2>&1; then ok "the root image is a whole zstd file"; else no "the root image is not a whole zstd file"; fi
    else note "zstd is not installed: the root image was not tested"; fi
    if grep -q "Camera Bridge OS $v" "$dir/SOURCE-OFFER.txt" 2>/dev/null; then ok "SOURCE-OFFER.txt names version $v"
    else no "SOURCE-OFFER.txt does not name version $v"; fi
}

compare_release_json() { # compare_release_json JSONFILE DIR VERSION
    local json=$1 dir=$2 v=$3 want got name size local_size bad=0
    if [ "$(jq -r '.tagName' "$json")" = "os-v$v" ]; then ok "release page: the tag is os-v$v"
    else no "release page: the tag is $(jq -r '.tagName' "$json"), not os-v$v"; fi
    case $v in
        0.*) if [ "$(jq -r '.isPrerelease' "$json")" = true ]; then ok "release page: marked pre-release (a version before 1.0)"
             else no "release page: not marked pre-release, but a version before 1.0 must be"; fi ;;
        *) if [ "$(jq -r '.isPrerelease' "$json")" = false ]; then ok "release page: a stable release"
           else no "release page: a stable version is marked pre-release"; fi ;;
    esac
    want=$(expected_files "$v" | sort)
    got=$(jq -r '.assets[].name' "$json" | sort)
    if [ "$want" = "$got" ]; then ok "release page: exactly the nine files"
    else no "release page: the files are not exactly the nine expected:"; diff <(echo "$want") <(echo "$got") | sed 's/^/          /' >&"$OUT" || true; fi
    for name in $want; do
        [ -f "$dir/$name" ] || continue
        size=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .size' "$json")
        local_size=$(wc -c <"$dir/$name" | tr -d ' ')
        if [ "$size" != "$local_size" ]; then no "release page: $name is $size bytes there and $local_size bytes here"; bad=1; fi
    done
    if [ "$bad" -eq 0 ]; then ok "release page: every file has the size of the downloaded copy"; fi
}

# The boot-test log of the workflow run (job "Boot test in QEMU"). gh puts "job<TAB>step<TAB>timestamp " in front of every line.
check_smoke_log() { # check_smoke_log FILE MINIMUM_PASSED MINIMUM_NVR_SECTIONS
    local file=$1 min=$2 min_nvr=${3:-3} text result passed failed nvr_sections
    if [ "$file" = - ]; then text=$(cat); else text=$(cat "$file"); fi
    text=$(sed -E $'s/^[^\t]*\t[^\t]*\t[0-9T:.Z-]+ //' <<<"$text")
    if grep -q 'accelerator: kvm' <<<"$text"; then ok "the boot test ran with KVM"; else no "the boot test did not run with KVM (no 'accelerator: kvm' line)"; fi
    result=$(grep -E '^RESULT: [0-9]+ passed, [0-9]+ failed$' <<<"$text" | tail -1 || true)
    if [ -z "$result" ]; then no "the log has no RESULT line"
    else
        passed=$(sed -E 's/^RESULT: ([0-9]+) passed.*/\1/' <<<"$result"); failed=$(sed -E 's/.* ([0-9]+) failed$/\1/' <<<"$result")
        if [ "$failed" -eq 0 ]; then ok "$result"; else no "$result"; fi
        if [ "$passed" -ge "$min" ]; then ok "$passed tests passed (at least $min required)"
        else no "only $passed tests passed (at least $min required: the old list had 61, the daemon and nvr sections add more)"; fi
    fi
    if grep -q '^  FAIL ' <<<"$text"; then no "the log has a FAIL line"; fi
    if grep -E '^==> ' <<<"$text" | grep -qi 'daemon'; then ok "the daemon section ran"; else no "no daemon section in the log (the workflow's test list must include daemon)"; fi
    nvr_sections=$(grep -E '^==> ' <<<"$text" | grep -ci 'nvr' || true)
    if [ "$nvr_sections" -ge "$min_nvr" ]; then ok "$nvr_sections nvr sections ran (at least $min_nvr required)"
    else no "only $nvr_sections nvr section(s) in the log (at least $min_nvr required: the workflow's test list must include nvr, nvr-archive and nvr-faults)"; fi
}

print_facts() { # print_facts DIR VERSION PUBKEY COMMIT RUN
    local dir=$1 v=$2 key=$3 commit=$4 run=$5 img
    img=camera-bridge-os-$v-amd64.img.xz
    echo
    echo "## The image you are testing"
    echo
    echo '```'
    echo "FACTS FOR THIS BUILD"
    echo "  release   Camera Bridge OS $v (amd64), pre-release, tag os-v$v"
    echo "  commit    $commit"
    echo "  run       $run (GitHub Actions, workflow Camera Bridge OS image)"
    echo "  image     $img"
    echo "  size      $(wc -c <"$dir/$img" | tr -d ' ') bytes"
    echo "  sha256    $(awk '{ print $1 }' "$dir/$img.sha256")"
    echo "  signed    minisign key $(sed -n 's/^untrusted comment: minisign public key //p' "$key" | head -1)"
    echo '```'
}

# --- command line ----------------------------------------------------------------------------------------------------------
mode=verify pubkey="" repo=coalsi/camera-bridge github=0 facts=0 commit="" run="" smoke="" min_passed=62 min_nvr=3 dir="" version=""
while [ $# -gt 0 ]; do
    case $1 in
        --pubkey) pubkey=${2:?--pubkey needs a file}; shift ;;
        --repo) repo=${2:?--repo needs OWNER/REPO}; shift ;;
        --github) github=1 ;;
        --facts) facts=1; OUT=2 ;;
        --commit) commit=${2:?--commit needs a sha}; shift ;;
        --run) run=${2:?--run needs a run id}; shift ;;
        --smoke-log) mode=smoke; smoke=${2:?--smoke-log needs a file}; shift ;;
        --min-passed) min_passed=${2:?--min-passed needs a number}; shift ;;
        --min-nvr) min_nvr=${2:?--min-nvr needs a number}; shift ;;
        --self-test) mode=selftest ;;
        -h|--help) awk 'NR > 1 { if (/^# shellcheck/) next; if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
        -*) die "unknown option: $1 (try --help)" ;;
        *) if [ -z "$dir" ]; then dir=$1; elif [ -z "$version" ]; then version=$1; else die "too many arguments"; fi ;;
    esac
    shift
done

case $mode in
    selftest) self_test; exit $? ;;
    smoke) check_smoke_log "$smoke" "$min_passed" "$min_nvr" ;;
    verify)
        [ -n "$dir" ] && [ -n "$version" ] || die "usage: Tools/verify-os-release.sh [options] DIR VERSION (try --help)"
        verify_release "$dir" "$version" "${pubkey:-$DEFAULT_PUBKEY}"
        if [ "$github" -eq 1 ]; then
            command -v gh >/dev/null && command -v jq >/dev/null || die "--github needs gh and jq"
            gh release view "os-v$version" --repo "$repo" --json tagName,isPrerelease,assets >"$TMP/release.json"
            compare_release_json "$TMP/release.json" "$dir" "$version"
        fi
        if [ "$facts" -eq 1 ]; then
            [ "$FAILED" -eq 0 ] || die "no facts block: a check failed"
            [ -n "$commit" ] && [ -n "$run" ] || die "--facts needs --commit and --run"
            print_facts "$dir" "$version" "${pubkey:-$DEFAULT_PUBKEY}" "$commit" "$run"
        fi ;;
esac
echo >&"$OUT"
echo "VERIFY: $PASSED ok, $FAILED failed" >&"$OUT"
[ "$FAILED" -eq 0 ]
