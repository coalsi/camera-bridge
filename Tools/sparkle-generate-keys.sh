#!/bin/bash
# One-time setup of the key that signs Camera Bridge updates (Sparkle 2, EdDSA). The OWNER runs this, once, on the Mac that
# builds releases.
#
#   Tools/sparkle-generate-keys.sh                  make the key (or reuse the one already in the Keychain) and put its
#                                                   PUBLIC half in project.yml (SPARKLE_PUBLIC_ED_KEY -> Info.plist SUPublicEDKey)
#   Tools/sparkle-generate-keys.sh --set-public-key BASE64
#                                                   only write a public key you already have (e.g. from another Mac) into project.yml
#   Tools/sparkle-generate-keys.sh --dry-run        find the tools and show what would happen; touches no key
#
# The private key is created by Sparkle's own generate_keys and stored in your login Keychain (item "https://sparkle-project.org",
# account "ed25519"). This script never reads it, never prints it and never writes it to a file. Only the public key is printed.
#
# BACK UP THE PRIVATE KEY. If it is lost, installed copies of Camera Bridge can never be updated again by Sparkle (they only
# accept updates signed by this key) and everyone must download the app by hand. To make a backup file, run, yourself:
#     <Sparkle bin>/generate_keys -x ~/Desktop/camera-bridge-sparkle-private-key
# and put that file in a password manager or encrypted storage, never in this repository.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="${PROJECT_YML:-$REPO_ROOT/project.yml}"
# shellcheck source=lib/sparkle.sh
. "$REPO_ROOT/Tools/lib/sparkle.sh"

mode="generate"
given_key=""
case "${1:-}" in
  "") ;;
  --dry-run) mode="dry-run" ;;
  --set-public-key) mode="set"; given_key="${2:-}"; [ -n "$given_key" ] || { echo "usage: $0 --set-public-key BASE64" >&2; exit 2; } ;;
  -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

write_public_key() {
  local key="$1"
  is_valid_ed_public_key "$key" || { echo "error: '$key' is not a Sparkle EdDSA public key (32 bytes, base64)." >&2; exit 1; }
  grep -q '^        SPARKLE_PUBLIC_ED_KEY:' "$PROJECT_YML" || { echo "error: no SPARKLE_PUBLIC_ED_KEY line in $PROJECT_YML" >&2; exit 1; }
  # base64 contains / + = but never |, so | is a safe sed delimiter.
  sed -i '' "s|^        SPARKLE_PUBLIC_ED_KEY:.*|        SPARKLE_PUBLIC_ED_KEY: \"$key\"   # public key of the update signatures; the private half is in the maintainer's Keychain|" "$PROJECT_YML"
  echo "Wrote the public key to $PROJECT_YML (SPARKLE_PUBLIC_ED_KEY)."
}

regenerate_project() {
  if [ "$PROJECT_YML" = "$REPO_ROOT/project.yml" ]; then
    (cd "$REPO_ROOT" && xcodegen generate)
    echo "Regenerated CameraBridge.xcodeproj and App/Info.plist: SUPublicEDKey is now set. Commit project.yml, CameraBridge.xcodeproj and App/Info.plist."
  fi
}

if [ "$mode" = "set" ]; then
  write_public_key "$given_key"
  regenerate_project
  exit 0
fi

find_sparkle_bin
echo "Sparkle tools: $SPARKLE_BIN"

if [ "$mode" = "dry-run" ]; then
  echo "Dry run: would run '$SPARKLE_BIN/generate_keys' (creates the key in your Keychain only if none exists), read the public key"
  echo "with '-p', write it to $PROJECT_YML and run xcodegen. Nothing was changed."
  exit 0
fi

# generate_keys keeps an existing key and only prints its public half; with none it creates one. Its normal output holds
# the public key and Info.plist instructions, not the private key, but it is discarded anyway: the public key is read with -p.
existing="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]' || true)"
if is_valid_ed_public_key "$existing"; then
  echo "A Sparkle signing key already exists in your Keychain; reusing it."
else
  echo "Creating the Sparkle signing key. The Keychain may ask you to allow access: choose Allow."
  "$SPARKLE_BIN/generate_keys" >/dev/null
fi

public_key="$("$SPARKLE_BIN/generate_keys" -p | tr -d '[:space:]')"
is_valid_ed_public_key "$public_key" || { echo "error: generate_keys -p did not return a valid public key." >&2; exit 1; }
echo "Public key (safe to share, it goes into Info.plist): $public_key"
write_public_key "$public_key"
regenerate_project
cat <<'EOF'

Next:
  1. Back up the private key (see the top of this script) before shipping anything.
  2. Create the notarization profile once (docs/distribution.md):
       xcrun notarytool store-credentials camera-bridge-notary --apple-id YOU@EXAMPLE.COM --team-id XL4RAH5J96
  3. Tools/release.sh
EOF
