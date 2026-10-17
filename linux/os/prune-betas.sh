#!/bin/bash
# Removes older Camera Bridge OS betas from the repository's GitHub Releases and keeps the newest few. The release workflow
# (.github/workflows/os-image.yml) runs it after it has published a beta and checked the published files and their signature:
# as a dry run until the repository variable PRUNE_OS_BETAS is "on".
#
#   linux/os/prune-betas.sh --repo OWNER/NAME [--keep N] [--except TAG] [--dry-run]
#   linux/os/prune-betas.sh --from-file releases.json [--repo OWNER/NAME] [--keep N] [--except TAG] [--dry-run]
#
#   --repo       the repository (default: $GITHUB_REPOSITORY); not needed for --from-file with --dry-run
#   --keep       how many of the newest betas stay (default: $KEEP, else 2; at least 1)
#   --except     a tag that is never removed, whatever its place (the workflow passes the release it just published)
#   --dry-run    print what would be copied and removed; change nothing
#   --from-file  read the release list from a file (what the releases API returns; pages may follow each other) instead of GitHub
#
# A beta is a release whose tag is os-v0.<numbers>, marked pre-release and not a draft. Nothing else is touched: not the Mac app's
# releases (tags v*), not a full release, not a draft, not 1.0 or later. Only the release goes; its git tag stays (gh release delete
# without --cleanup-tag), so every build can still be found and rebuilt. Needs jq, and gh with GH_TOKEN unless it only reads a file.
#
# The package list and the source offer of a build are kept before its release goes: every image's SOURCE-OFFER.txt promises the
# GPL and LGPL source of that version for three years, and its packages.txt is the record of which package versions that is. Both
# are copied to the release os-sources (made here the first time, never "Latest"), as camera-bridge-os-<version>-packages.txt and
# camera-bridge-os-<version>-SOURCE-OFFER.txt, and checked there. A beta whose package list cannot be kept stays listed.
#
# Why: until 1.0 the OS is one product, "Camera Bridge OS beta", with a new build most days. A box only ever takes the newest beta
# (cb-update-fetch), so old betas help no one. Two stay so a box that is downloading the previous build when a new one comes out
# can finish.
set -euo pipefail

# The release that keeps the package lists and source offers. Its tag matches neither the boxes' os-v<version>, nor the site's, nor
# the betas removed here.
ARCHIVE=os-sources
ARCHIVE_TITLE="Camera Bridge OS: package lists and source offers"
ARCHIVE_NOTES="The exact package list and the written source offer of each Camera Bridge OS build that is no longer listed as its own release: camera-bridge-os-<version>-packages.txt and camera-bridge-os-<version>-SOURCE-OFFER.txt. Each build keeps its git tag.

This is not a download of Camera Bridge OS. To ask for the source code of a version, write to legal@camera-bridge.app and name it."

repo=${GITHUB_REPOSITORY:-} keep=${KEEP:-2} except="" dry_run=0 from_file=""
die() { echo "prune-betas: $*" >&2; exit 1; }
value() { [ "$2" -ge 2 ] || die "$1 needs a value"; }   # value OPTION ARGS_LEFT
# A warning the Actions run shows on its summary page; a plain line anywhere else.
warn() { if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::warning::$*"; else echo "warning: $*"; fi; }

while [ $# -gt 0 ]; do
    case $1 in
        --repo) value "$1" $#; repo=$2; shift ;;
        --keep) value "$1" $#; keep=$2; shift ;;
        --except) value "$1" $#; except=$2; shift ;;
        --from-file) value "$1" $#; from_file=$2; shift ;;
        --dry-run) dry_run=1 ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

case $keep in ''|*[!0-9]*) die "--keep must be a whole number, at least 1" ;; esac
keep=$((10#$keep))
[ "$keep" -ge 1 ] || die "--keep must be a whole number, at least 1"
if [ -n "$repo" ] || [ -z "$from_file" ] || [ "$dry_run" -eq 0 ]; then
    [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo must be OWNER/NAME (got '$repo')"
fi
command -v jq >/dev/null || die "jq is required"

if [ -n "$from_file" ]; then
    raw=$(cat -- "$from_file") || die "cannot read $from_file"
else
    command -v gh >/dev/null || die "gh is required"
    raw=$(gh api --paginate "repos/$repo/releases?per_page=100") || die "could not list the releases of $repo"
fi

# One line per beta, newest first: "keep TAG", "spare TAG" (the --except tag) or "remove TAG", then 1 or 0 for whether the release
# has its package list and its source offer. The pages are slurped and added, so both a merged list and pages that follow each
# other work. Anything that is not a list of releases stops here.
plan=$(jq -r -s --argjson keep "$keep" --arg except "$except" '
  if length > 0 and all(.[]; type == "array") then add else error("not a list of releases") end
  | [ .[] | select(type == "object" and .draft == false and .prerelease == true
                   and ((.tag_name // "") | type == "string" and test("^os-v0(\\.[0-9]+)+$"))) ]
  | sort_by(.tag_name | ltrimstr("os-v") | split(".") | map(tonumber)) | reverse
  | to_entries[]
  | .value.tag_name as $tag
  | [ (.value.assets // [])[] | objects | .name | strings ] as $names
  | def has($n): if $names | any(. == $n) then 1 else 0 end;
    (if .key < $keep then "keep" elif $tag == $except then "spare" else "remove" end)
    + " \($tag) \(has("camera-bridge-os-\($tag | ltrimstr("os-v"))-packages.txt")) \(has("SOURCE-OFFER.txt"))"' <<<"$raw") \
    || die "the release list could not be read"

if [ -z "$plan" ]; then echo "No OS betas found; nothing to remove."; exit 0; fi

# The release just published must be in the list. If it is not, the list is not what it should be, so nothing is removed.
if [[ $except =~ ^os-v0(\.[0-9]+)+$ ]] && ! awk -v t="$except" '($1 == "keep" || $1 == "spare") && $2 == t { f = 1 } END { exit !f }' <<<"$plan"; then
    die "$except is not among the betas listed; removing nothing"
fi

# The archive release as the list shows it: its id, and its files as "NAME SIZE" lines.
archive_id=$(jq -r -s --arg tag "$ARCHIVE" \
    '[ add | .[] | objects | select(.tag_name == $tag and .draft == false) ] | first | .id // empty' <<<"$raw")
archived=$(jq -r -s --arg tag "$ARCHIVE" \
    '[ add | .[] | objects | select(.tag_name == $tag and .draft == false) ] | first | (.assets // [])[] | objects | "\(.name) \(.size)"' <<<"$raw")
# The archive's files as GitHub has them now, every page of them (a real run never trusts the list for this).
list_archive() {
    gh api --paginate "repos/$repo/releases/$archive_id/assets?per_page=100" </dev/null | jq -r -s 'add | .[] | "\(.name) \(.size)"'
}
in_archive() { awk -v n="$1" '$1 == n { found = 1 } END { exit !found }' <<<"$archived"; }
archived_size() { awk -v n="$1" '$1 == n { print $2; exit }' <<<"$archived"; }

if grep -q '^remove ' <<<"$plan"; then
    if [ "$dry_run" -eq 1 ]; then
        [ -n "$archive_id" ] || echo "would make the release $ARCHIVE for the package lists and source offers"
    else
        if [ -z "$archive_id" ]; then
            gh release create "$ARCHIVE" --repo "$repo" --title "$ARCHIVE_TITLE" --notes "$ARCHIVE_NOTES" --latest=false </dev/null >/dev/null \
                || die "could not make the release $ARCHIVE; removing nothing"
            archive_id=$(gh api "repos/$repo/releases/tags/$ARCHIVE" </dev/null | jq -r '.id // empty') || archive_id=""
            [ -n "$archive_id" ] || die "the release $ARCHIVE was made but cannot be read; removing nothing"
            echo "made the release $ARCHIVE for the package lists and source offers"
        fi
        archived=$(list_archive) || die "could not list the files of $ARCHIVE; removing nothing"
    fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# keep_files TAG FROM=TO...: copies those files of the release TAG to the archive under the new names, then checks that each is
# there with its size.
keep_files() {
    local tag=$1 pair from to files=() dir=$work/$1 size
    shift
    mkdir -p "$dir/in"
    for pair in "$@"; do
        from=${pair%%=*} to=${pair#*=}
        gh release download "$tag" --repo "$repo" --pattern "$from" --dir "$dir/in" </dev/null >/dev/null || return 1
        [ -s "$dir/in/$from" ] || return 1
        mv -- "$dir/in/$from" "$dir/$to"
        files+=("$dir/$to")
    done
    gh release upload "$ARCHIVE" "${files[@]}" --repo "$repo" </dev/null >/dev/null || return 1
    archived=$(list_archive) || return 1
    for pair in "$@"; do
        to=${pair#*=}
        size=$(wc -c <"$dir/$to" | tr -d ' ')
        [ "$(archived_size "$to")" = "$size" ] || { echo "$to is not in $ARCHIVE as uploaded" >&2; return 1; }
        echo "kept    $to in $ARCHIVE"
    done
}

removed=0 failed=0 held=""
while read -r action tag has_packages has_offer; do
    case $action in
        keep|spare) if [ "$tag" = "$except" ]; then echo "keep    $tag (just published)"; else echo "keep    $tag"; fi ;;
        remove)
            # The filter above chose only betas; check again right before anything is removed.
            [[ $tag =~ ^os-v0(\.[0-9]+)+$ ]] || die "refusing to remove $tag"
            version=${tag#os-v}
            packages=camera-bridge-os-$version-packages.txt offer=camera-bridge-os-$version-SOURCE-OFFER.txt
            copy=()
            if in_archive "$packages"; then :
            elif [ "$has_packages" = 1 ]; then copy+=("$packages=$packages")
            else
                echo "keep    $tag (it has no package list to keep in $ARCHIVE)"; held="$held $tag"; continue
            fi
            if ! in_archive "$offer" && [ "$has_offer" = 1 ]; then copy+=("SOURCE-OFFER.txt=$offer"); fi
            if [ "$dry_run" -eq 1 ]; then
                for pair in ${copy[@]+"${copy[@]}"}; do echo "would keep ${pair#*=} in $ARCHIVE"; done
                echo "would remove $tag (the tag stays)"
                continue
            fi
            if [ "${#copy[@]}" -gt 0 ] && ! keep_files "$tag" "${copy[@]}"; then
                echo "could not keep the package list and source offer of $tag in $ARCHIVE; it stays listed" >&2
                failed=$((failed + 1)); continue
            fi
            if gh release delete "$tag" --repo "$repo" --yes </dev/null; then
                echo "removed $tag (the tag stays)"; removed=$((removed + 1))
            else
                echo "could not remove $tag" >&2; failed=$((failed + 1))
            fi
            ;;
    esac
done <<<"$plan"

if [ -n "$held" ]; then
    warn "Still listed because they have no package list to keep:$held. Their image is the only record of their packages." \
         "To let one go, put its camera-bridge-os-<version>-packages.txt in the release $ARCHIVE by hand."
fi
if [ "$dry_run" -eq 1 ]; then echo "Dry run: nothing was removed."; else echo "Older betas removed: $removed."; fi
[ "$failed" -eq 0 ] || die "$failed betas could not be removed"
