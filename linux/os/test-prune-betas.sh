#!/bin/bash
# Self-test of prune-betas.sh. No network, no GitHub: a fake gh on PATH serves a recorded release list (in two pages, as the
# releases API sends them), keeps the release os-sources in a folder, and records every call; each case checks exactly which
# releases would be removed and which package lists and source offers were kept first. It ends with the release workflow's
# settings for the clean-up and for pre-releases. The static checks job of .github/workflows/os-image.yml runs it.
#
#   linux/os/test-prune-betas.sh        (needs bash and jq)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRUNE=$HERE/prune-betas.sh
WORKFLOW=$HERE/../../.github/workflows/os-image.yml
REPO=coalsi/camera-bridge
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

passed=0 failed=0
pass() { printf 'ok    %s\n' "$*"; passed=$((passed + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; failed=$((failed + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1"; printf '        got:  %s\n        want: %s\n' "$2" "$3"; fi; }   # check DESCRIPTION GOT WANT

# --- the recorded list: OS betas, the Mac app's releases, a draft, full OS releases and odd tags -------------------------------
id=0
assets() { # assets TAG KIND: full (image, package list, source offer), image (image only, as os-v0.1 was published), nooffer, dmg
    local v=${1#os-v} sep="" name
    local names=()
    case $2 in
        full) names=("camera-bridge-os-$v-amd64.img.xz" SHA256SUMS "camera-bridge-os-$v-packages.txt" SOURCE-OFFER.txt) ;;
        image) names=("camera-bridge-os-$v-amd64.img.xz" SHA256SUMS) ;;
        nooffer) names=("camera-bridge-os-$v-amd64.img.xz" SHA256SUMS "camera-bridge-os-$v-packages.txt") ;;
        dmg) names=("CameraBridge-${1#v}.dmg") ;;
    esac
    printf '['
    for name in "${names[@]}"; do printf '%s{"name":"%s","size":%d}' "$sep" "$name" "${#name}"; sep=,; done
    printf ']'
}
release() { # release TAG PRERELEASE DRAFT KIND
    id=$((id + 1))
    printf '{"id":%d,"tag_name":"%s","name":"%s","draft":%s,"prerelease":%s,"html_url":"https://github.com/%s/releases/tag/%s","assets":%s}' \
        "$id" "$1" "$1" "$3" "$2" "$REPO" "$1" "$(assets "$1" "$4")"
}
page() { # page "TAG PRERELEASE DRAFT KIND"...
    local sep="" r tag pre draft kind
    printf '['
    for r in "$@"; do read -r tag pre draft kind <<<"$r"; printf '%s' "$sep"; release "$tag" "$pre" "$draft" "${kind:-full}"; sep=,; done
    printf ']\n'
}
# Newest first, as GitHub lists them (by date, not by version). os-v0.1 has no package list, as on GitHub.
page1=$(page "os-v0.1.109 true true" "os-v0.1.108 true false" "v1.0.1 false false dmg" "os-v0.1.107 true false" "os-v1.1 true false" \
             "os-v0.1.106 true false" "os-v1.0 false false" "os-v0.1.105 true false" "v0.9 true false dmg")
page2=$(page "os-v0.1.104 true false" "os-v0.1.103 true false" "os-v0.1.100 false false" "os-v0.1.102 true false" "v1.0 false false dmg" \
             "os-v0.1-test true false" "os-v0.1.99 true false nooffer" "os-v0.1.1 true false" "os-v0.1 true false image")
printf '%s\n%s\n' "$page1" "$page2" >"$work/pages.json"                     # pages one after another (gh api --paginate)
jq -s add "$work/pages.json" >"$work/merged.json"                           # one list (a saved listing)
# The betas by version: 0.1.108 .. 0.1.102, then 0.1.99 (after 0.1.100 by number, before it by letters), 0.1.1, 0.1.
# Never removed: the draft 0.1.109, the full release 0.1.100, os-v1.0 and os-v1.1, os-v0.1-test, and v0.9 / v1.0 / v1.0.1 (Mac app).
# os-v0.1 stays too: it has no package list to keep.
EXPECTED_KEEP2="os-v0.1.106 os-v0.1.105 os-v0.1.104 os-v0.1.103 os-v0.1.102 os-v0.1.99 os-v0.1.1"
# What os-sources holds after the default run (sorted): each removed build's package list and source offer; 0.1.99 has no offer.
EXPECTED_ARCHIVE=$(for v in 0.1.1 0.1.102 0.1.103 0.1.104 0.1.105 0.1.106 0.1.99; do
    printf 'camera-bridge-os-%s-packages.txt\n' "$v"
    [ "$v" = 0.1.99 ] || printf 'camera-bridge-os-%s-SOURCE-OFFER.txt\n' "$v"
done | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')

# The same list with os-sources already there, holding the files named (one by hand: the package list of 0.1).
SEEDED=(camera-bridge-os-0.1.106-packages.txt camera-bridge-os-0.1.106-SOURCE-OFFER.txt camera-bridge-os-0.1.105-packages.txt camera-bridge-os-0.1-packages.txt)
mkdir -p "$work/seed"
seed_assets=$(for name in "${SEEDED[@]}"; do printf 'seeded %s\n' "$name" >"$work/seed/$name"; printf '{"name":"%s","size":%d}\n' "$name" "$(wc -c <"$work/seed/$name")"; done | jq -s -c .)
printf '[{"id":900,"tag_name":"os-sources","name":"os-sources","draft":false,"prerelease":false,"assets":%s}]\n' "$seed_assets" >"$work/archive-page.json"
cat "$work/pages.json" "$work/archive-page.json" >"$work/pages-archive.json"

# --- the fake gh ----------------------------------------------------------------------------------------------------------------
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/bin/bash
# Fake gh: records the call on one line, serves the recorded pages for "api", keeps os-sources in $FAKE_GH_STATE/archive.
#   FAKE_GH_FAIL           "release delete" of this tag fails
#   FAKE_GH_FAIL_CREATE    "release create" fails
#   FAKE_GH_FAIL_DOWNLOAD  "release download" from this tag fails
#   FAKE_GH_FAIL_UPLOAD    "release upload" of a file whose name holds this text fails
#   FAKE_GH_LOSE_UPLOAD    "release upload" of a file whose name holds this text says yes, but the file never arrives
set -u
line=$*; printf '%s\n' "${line//$'\n'/ }" >>"$FAKE_GH_LOG"
state=$FAKE_GH_STATE
option() { # option NAME ARGS...: the value after NAME
    local name=$1; shift
    while [ $# -gt 1 ]; do [ "$1" = "$name" ] && { printf '%s' "$2"; return; }; shift; done
}
case ${1:-} in
    api)
        path=""; for a in "$@"; do path=$a; done
        case $path in
            repos/*/releases\?per_page=100) cat "$FAKE_GH_PAGES" ;;
            repos/*/releases/tags/os-sources)
                [ -e "$state/archive.id" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                printf '{"id":%s,"tag_name":"os-sources"}\n' "$(cat "$state/archive.id")" ;;
            repos/*/releases/*/assets\?per_page=100)
                [ -e "$state/archive.id" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                [ "${path#*/releases/}" = "$(cat "$state/archive.id")/assets?per_page=100" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                found=0
                for f in "$state"/archive/*; do   # one page per file, as --paginate prints pages one after another
                    [ -e "$f" ] || continue
                    printf '[{"name":"%s","size":%d}]\n' "$(basename "$f")" "$(wc -c <"$f")"; found=1
                done
                [ "$found" = 1 ] || echo '[]' ;;
            *) exit 2 ;;
        esac ;;
    release)
        case ${2:-} in
            delete) if [ -n "${FAKE_GH_FAIL:-}" ] && [ "${3:-}" = "$FAKE_GH_FAIL" ]; then echo "HTTP 500" >&2; exit 1; fi ;;
            create)
                [ "${3:-}" = os-sources ] || exit 2
                [ -z "${FAKE_GH_FAIL_CREATE:-}" ] || { echo "HTTP 422" >&2; exit 1; }
                mkdir -p "$state/archive"; echo 901 >"$state/archive.id"
                echo "https://github.com/x/y/releases/tag/os-sources" ;;
            download)
                tag=$3 pattern=$(option --pattern "$@") dir=$(option --dir "$@")
                [ "${FAKE_GH_FAIL_DOWNLOAD:-}" != "$tag" ] || { echo "HTTP 502" >&2; exit 1; }
                jq -e -s --arg t "$tag" --arg n "$pattern" 'add | any(.[]; .tag_name == $t and any(.assets[]; .name == $n))' "$FAKE_GH_PAGES" >/dev/null \
                    || { echo "no assets match the file pattern" >&2; exit 1; }
                mkdir -p "$dir"; printf '%s %s\n' "$tag" "$pattern" >"$dir/$pattern" ;;
            upload)
                [ "${3:-}" = os-sources ] && [ -e "$state/archive.id" ] || exit 2
                shift 3
                while [ $# -gt 0 ] && [ "$1" != --repo ]; do
                    name=$(basename "$1")
                    [ ! -e "$state/archive/$name" ] || { echo "asset under the same name already exists: $name" >&2; exit 1; }
                    case $name in *"${FAKE_GH_FAIL_UPLOAD:-//}"*) echo "HTTP 500" >&2; exit 1 ;; esac
                    case $name in *"${FAKE_GH_LOSE_UPLOAD:-//}"*) ;; *) cp "$1" "$state/archive/$name" ;; esac
                    shift
                done ;;
            *) exit 2 ;;
        esac ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$work/bin/gh"

# run NAME [VAR=VALUE...] -- ARGS...: runs prune-betas.sh with the fake gh; sets STATUS, OUT (stdout and stderr), LOG (gh calls) and
# STATE (os-sources). With pages=FILE and seed=FOLDER set, the list and os-sources start from those.
pages=$work/pages.json seed=""
run() {
    local name=$1; shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    LOG=$work/$name.log; : >"$LOG"
    STATE=$work/$name.state; mkdir -p "$STATE"
    if [ -n "$seed" ]; then cp -R "$seed" "$STATE/archive"; echo 900 >"$STATE/archive.id"; fi
    STATUS=0
    OUT=$(env -u KEEP -u GITHUB_REPOSITORY -u GITHUB_ACTIONS PATH="$work/bin:$PATH" FAKE_GH_LOG="$LOG" FAKE_GH_PAGES="$pages" \
        FAKE_GH_STATE="$STATE" ${envs[@]+"${envs[@]}"} bash "$PRUNE" "$@" 2>&1) || STATUS=$?
}
# shellcheck disable=SC2001
show() { sed 's/^/        | /' <<<"$OUT"; }
removed() { awk '$1 == "release" && $2 == "delete" { printf "%s%s", sep, $3; sep = " " }' "$LOG"; }
archive() { if [ -d "$STATE/archive" ]; then (cd "$STATE/archive" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'); fi; }
calls() { awk -v what="$1" '$1 == "release" && $2 == what' "$LOG" | wc -l | tr -d ' '; }   # calls create|upload|download|delete
expect() { # expect DESCRIPTION STATUS REMOVED [TEXT the output must hold]
    local desc=$1 want_status=$2 want=$3 text=${4:-} got
    got=$(removed)
    if [ "$STATUS" = "$want_status" ] && [ "$got" = "$want" ] && grep -qF -- "$text" <<<"$OUT"; then pass "$desc"; else
        bad "$desc"; printf '        exit %s (want %s)\n        removed: %s\n        want:    %s\n        text:    %s\n' "$STATUS" "$want_status" "$got" "$want" "$text"
        show
    fi
}

# --- removing, and keeping the package lists first ------------------------------------------------------------------------------
run default -- --repo "$REPO" --except os-v0.1.108
expect "keeps the newest two betas and removes the rest, newest first" 0 "$EXPECTED_KEEP2"
if grep -qxF "api --paginate repos/$REPO/releases?per_page=100" "$LOG"; then pass "lists every page of the repository's releases"; else bad "lists every page of the repository's releases"; cat "$LOG"; fi
if awk -v repo="$REPO" '$1 == "release" && $2 == "delete" && $0 != "release delete " $3 " --repo " repo " --yes" { bad = 1 } END { exit bad }' "$LOG"; then
    pass "removes with exactly: gh release delete TAG --repo REPO --yes (no --cleanup-tag)"
else bad "removes with exactly: gh release delete TAG --repo REPO --yes (no --cleanup-tag)"; cat "$LOG"; fi
if ! grep -q -- '--cleanup-tag' "$LOG"; then pass "never removes a git tag"; else bad "never removes a git tag"; fi
if grep -qx 'removed os-v0.1.106 (the tag stays)' <<<"$OUT" && grep -qx 'keep    os-v0.1.108 (just published)' <<<"$OUT"; then
    pass "says what it keeps and what it removes"; else bad "says what it keeps and what it removes"; show; fi
check "keeps each removed build's package list and source offer in os-sources first" "$(archive)" "$EXPECTED_ARCHIVE"
check "the source offer kept for 0.1.106 is the one of os-v0.1.106" "$(cat "$STATE/archive/camera-bridge-os-0.1.106-SOURCE-OFFER.txt")" "os-v0.1.106 SOURCE-OFFER.txt"
check "the package list kept for 0.1.1 is the one of os-v0.1.1" "$(cat "$STATE/archive/camera-bridge-os-0.1.1-packages.txt")" "os-v0.1.1 camera-bridge-os-0.1.1-packages.txt"
if grep -qx 'keep    os-v0.1 (it has no package list to keep in os-sources)' <<<"$OUT" \
    && grep -qF 'warning: Still listed because they have no package list to keep: os-v0.1.' <<<"$OUT"; then
    pass "keeps a beta that has no package list, and says why"; else bad "keeps a beta that has no package list, and says why"; show; fi
create=$(awk '$1 == "release" && $2 == "create"' "$LOG")
if [ "$(calls create)" = 1 ] && [[ $create == "release create os-sources --repo $REPO --title "* ]] && [[ $create == *" --latest=false" ]]; then
    pass "makes os-sources once, never Latest"; else bad "makes os-sources once, never Latest"; cat "$LOG"; fi
# Every removal comes after its build's files went to os-sources, the release is made before any of that, and files are taken only
# from a release that is then removed and put only in os-sources.
if awk -v repo="$REPO" '
    $1 != "release" { next }
    $2 == "create" { made = 1; next }
    $2 == "download" { if (!made || $4 != "--repo" || $5 != repo || $6 != "--pattern") bad = 1; took[$3] = 1; next }
    $2 == "upload" { if (!made || $3 != "os-sources") bad = 1
                     for (i = 4; i <= NF && $i != "--repo"; i++) { n = $i; sub(/.*\//, "", n); up[n] = 1 }; next }
    $2 == "delete" { v = $3; sub(/^os-v/, "", v); if (!up["camera-bridge-os-" v "-packages.txt"]) bad = 1; gone[$3] = 1 }
    END { for (t in took) if (!gone[t]) bad = 1; exit bad }' "$LOG"; then
    pass "copies first, from the release it then removes, into os-sources only"; else bad "copies first, from the release it then removes, into os-sources only"; cat "$LOG"; fi
if ! awk '$1 == "release" && $3 == "os-sources" && $2 != "create" && $2 != "upload"' "$LOG" | grep -q .; then
    pass "never removes or downloads os-sources"; else bad "never removes or downloads os-sources"; cat "$LOG"; fi

run actions GITHUB_ACTIONS=true -- --repo "$REPO" --except os-v0.1.108
if grep -qF '::warning::Still listed because they have no package list to keep: os-v0.1.' <<<"$OUT"; then
    pass "in GitHub Actions the beta kept for its missing package list is a warning on the run"; else bad "in GitHub Actions the beta kept for its missing package list is a warning on the run"; show; fi

pages=$work/pages-archive.json seed=$work/seed
run seeded -- --repo "$REPO" --except os-v0.1.108
expect "with os-sources there, removes the beta whose package list was put there by hand too" 0 "$EXPECTED_KEEP2 os-v0.1"
check "with os-sources there, does not make it again" "$(calls create)" 0
check "copies only what os-sources does not have yet" \
    "$(awk '$1 == "release" && $2 == "download" && ($3 == "os-v0.1.106" || $3 == "os-v0.1.105" || $3 == "os-v0.1") { print $3, $7 }' "$LOG" | tr '\n' ';')" \
    "os-v0.1.105 SOURCE-OFFER.txt;"
check "os-sources then holds every removed build's files, the earlier ones untouched" \
    "$(archive)" "$(tr ' ' '\n' <<<"$EXPECTED_ARCHIVE camera-bridge-os-0.1-packages.txt" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
check "a file already in os-sources stays as it was" "$(cat "$STATE/archive/camera-bridge-os-0.1.106-packages.txt")" "seeded camera-bridge-os-0.1.106-packages.txt"
pages=$work/pages.json seed=""

run upload-fails FAKE_GH_FAIL_UPLOAD=0.1.104 -- --repo "$REPO" --except os-v0.1.108
expect "the files of one build cannot be uploaded: that beta stays, the others go, the exit status says so" 1 \
    "${EXPECTED_KEEP2/os-v0.1.104 /}" "could not keep the package list and source offer of os-v0.1.104 in os-sources; it stays listed"

run upload-lost FAKE_GH_LOSE_UPLOAD=0.1.103-packages -- --repo "$REPO" --except os-v0.1.108
expect "an upload that says yes but is not in os-sources: that beta stays" 1 \
    "${EXPECTED_KEEP2/os-v0.1.103 /}" "camera-bridge-os-0.1.103-packages.txt is not in os-sources as uploaded"

run download-fails FAKE_GH_FAIL_DOWNLOAD=os-v0.1.102 -- --repo "$REPO" --except os-v0.1.108
expect "the files of one build cannot be downloaded: that beta stays" 1 "${EXPECTED_KEEP2/os-v0.1.102 /}" "of os-v0.1.102 in os-sources; it stays listed"

run create-fails FAKE_GH_FAIL_CREATE=1 -- --repo "$REPO" --except os-v0.1.108
expect "os-sources cannot be made: removes nothing" 1 "" "could not make the release os-sources; removing nothing"
check "os-sources cannot be made: copies nothing" "$(calls upload) $(calls download)" "0 0"

# --- the options ----------------------------------------------------------------------------------------------------------------
run keep-env KEEP=2 -- --repo "$REPO" --except os-v0.1.108
expect "KEEP=2 from the environment (as the workflow runs it)" 0 "$EXPECTED_KEEP2"

run keep3 KEEP=3 -- --repo "$REPO"
expect "KEEP=3 keeps 0.1.106 too" 0 "${EXPECTED_KEEP2#os-v0.1.106 }"

run keep-flag KEEP=5 -- --repo "$REPO" --keep 1
expect "--keep wins over KEEP" 0 "os-v0.1.107 $EXPECTED_KEEP2"

run spare -- --repo "$REPO" --keep 1 --except os-v0.1.107
expect "never removes the release just published, even when it is not among the newest" 0 "$EXPECTED_KEEP2"

run repo-env GITHUB_REPOSITORY="$REPO" -- --except os-v0.1.108
expect "takes the repository from GITHUB_REPOSITORY" 0 "$EXPECTED_KEEP2"

run dry -- --repo "$REPO" --except os-v0.1.108 --dry-run
expect "--dry-run removes nothing" 0 "" "Dry run: nothing was removed."
check "--dry-run only reads the list: no release made, nothing copied" "$(calls create) $(calls upload) $(calls download) $(wc -l <"$LOG" | tr -d ' ')" "0 0 0 1"
if [ "$(grep -c '^would remove ' <<<"$OUT")" = 7 ] && grep -qx 'would remove os-v0.1.1 (the tag stays)' <<<"$OUT" \
    && grep -qx 'would make the release os-sources for the package lists and source offers' <<<"$OUT" \
    && grep -qx 'would keep camera-bridge-os-0.1.106-SOURCE-OFFER.txt in os-sources' <<<"$OUT" \
    && grep -qx 'keep    os-v0.1 (it has no package list to keep in os-sources)' <<<"$OUT"; then
    pass "--dry-run prints the same seven, what it would keep and what it leaves"; else bad "--dry-run prints the same seven, what it would keep and what it leaves"; show; fi

run file -- --repo "$REPO" --from-file "$work/merged.json" --except os-v0.1.108
expect "--from-file (one merged list) removes the same releases" 0 "$EXPECTED_KEEP2"
if ! grep -q '^api --paginate repos/[^/]*/[^/]*/releases?' "$LOG"; then pass "--from-file does not ask GitHub for the list"; else bad "--from-file does not ask GitHub for the list"; fi

run file-dry -- --from-file "$work/pages.json" --dry-run
expect "--from-file --dry-run needs no repository" 0 ""
if [ "$(grep -c '^would remove ' <<<"$OUT")" = 7 ] && [ ! -s "$LOG" ]; then pass "--from-file --dry-run reads pages and calls no gh"; else
    bad "--from-file --dry-run reads pages and calls no gh"; show; fi

run file-dry-archive -- --from-file "$work/pages-archive.json" --dry-run
if grep -qx 'would remove os-v0.1 (the tag stays)' <<<"$OUT" && ! grep -q 'would make the release' <<<"$OUT" \
    && ! grep -q 'would keep camera-bridge-os-0.1.106-' <<<"$OUT" && grep -qx 'would keep camera-bridge-os-0.1.105-SOURCE-OFFER.txt in os-sources' <<<"$OUT" \
    && [ ! -s "$LOG" ]; then
    pass "--dry-run with os-sources in the list: what is there already is not copied again"; else bad "--dry-run with os-sources in the list: what is there already is not copied again"; show; fi

run one-fails FAKE_GH_FAIL=os-v0.1.104 -- --repo "$REPO" --except os-v0.1.108
expect "a removal that fails: the others still go, and the exit status says so" 1 "$EXPECTED_KEEP2" "1 betas could not be removed"

run unknown-new -- --repo "$REPO" --except os-v0.1.110
expect "the release just published is not in the list: removes nothing" 1 "" "os-v0.1.110 is not among the betas listed"
check "the release just published is not in the list: makes and copies nothing" "$(calls create) $(calls upload)" "0 0"

run full-release -- --repo "$REPO" --except os-v1.0
expect "after a 1.0 release it still removes only 0.x betas" 0 "$EXPECTED_KEEP2"

for k in 0 -1 two ""; do
    run "keep-bad-$k" -- --repo "$REPO" --keep "$k"
    expect "refuses --keep '$k'" 1 "" "--keep must be a whole number"
done
run bad-repo -- --repo "not a repo"
expect "refuses a bad repository" 1 "" "--repo must be OWNER/NAME"
run no-repo -- --except os-v0.1.108
expect "refuses to run without a repository" 1 "" "--repo must be OWNER/NAME"
run bad-option -- --repo "$REPO" --cleanup-tag
expect "refuses an unknown option" 1 "" "unknown option: --cleanup-tag"

printf '{"message":"Bad credentials","status":"401"}\n' >"$work/error.json"
run error-body -- --repo "$REPO" --from-file "$work/error.json"
expect "an error instead of a list: removes nothing" 1 "" "the release list could not be read"
: >"$work/empty.json"
run empty-body -- --repo "$REPO" --from-file "$work/empty.json"
expect "an empty answer: removes nothing" 1 "" "the release list could not be read"
printf '[]\n' >"$work/none.json"
run no-releases -- --repo "$REPO" --from-file "$work/none.json"
expect "no releases at all: nothing to do" 0 "" "No OS betas found"
release_only_mac=$(page "v1.0.1 false false dmg" "v0.9 true false dmg" "os-v0.1.100 false false" "os-v0.1.109 true true")
printf '%s\n' "$release_only_mac" >"$work/no-betas.json"
run no-betas -- --repo "$REPO" --from-file "$work/no-betas.json"
expect "no betas among the releases: nothing to do" 0 "" "No OS betas found"
check "no betas: os-sources is not made" "$(calls create)" 0

# --- the release workflow -------------------------------------------------------------------------------------------------------
# The clean-up only lists until the owner turns it on, and a full OS release may become "Latest" (the Mac app is archived): only betas
# are pre-releases.
create_step=$(awk '/gh release create "\$TAG"/ { on = 1 } on { print } on && /"\$\{FILES\[@\]\}"/ { exit }' "$WORKFLOW")
# shellcheck disable=SC2016  # the literal text of the workflow is matched, not expanded
if ! grep -qF -- '--latest=false' <<<"$create_step" && grep -qF -- '"${PRERELEASE[@]}"' <<<"$create_step"; then
    pass "the workflow publishes betas as pre-releases and lets a full OS release become Latest"; else
    bad "the workflow publishes betas as pre-releases and lets a full OS release become Latest"; printf '%s\n' "$create_step"; fi
prune_step=$(awk '/- name: Remove older betas/ { on = 1; next } on && /- name: / { exit } on { print }' "$WORKFLOW")
# shellcheck disable=SC2016  # the workflow's text, $ and all
if grep -qF 'PRUNE_OS_BETAS: ${{ vars.PRUNE_OS_BETAS }}' <<<"$prune_step" && grep -qF 'mode=(--dry-run)' <<<"$prune_step" \
    && grep -qF 'if [ "$PRUNE_OS_BETAS" = on ]; then mode=(); else' <<<"$prune_step" && grep -qF -- '--except "$TAG" "${mode[@]}"' <<<"$prune_step"; then
    pass "the workflow's clean-up is a dry run unless the repository variable PRUNE_OS_BETAS is on"
else bad "the workflow's clean-up is a dry run unless the repository variable PRUNE_OS_BETAS is on"; printf '%s\n' "$prune_step"; fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
