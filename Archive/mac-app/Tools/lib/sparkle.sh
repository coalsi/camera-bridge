# Sourced by Tools/release.sh and Tools/sparkle-generate-keys.sh. Not run on its own.
#
# find_sparkle_bin: sets SPARKLE_BIN to the folder holding Sparkle's command-line tools (generate_keys, sign_update,
# generate_appcast). They ship inside the Sparkle package (an SPM binary artifact), so they are the same version as the
# framework in the app. Order: $SPARKLE_BIN, then the package checkout of this repo (build/SourcePackages), resolved on demand.

find_sparkle_bin() {
  if [ -n "${SPARKLE_BIN:-}" ]; then
    [ -x "$SPARKLE_BIN/sign_update" ] || { echo "error: SPARKLE_BIN=$SPARKLE_BIN has no sign_update" >&2; return 1; }
    return 0
  fi
  local packages="${SPARKLE_PACKAGES_DIR:-$REPO_ROOT/build/SourcePackages}"
  local candidate="$packages/artifacts/sparkle/Sparkle/bin"
  if [ ! -x "$candidate/sign_update" ]; then
    echo "Resolving the Sparkle package (this downloads it once)..." >&2
    (cd "$REPO_ROOT" && xcodebuild -resolvePackageDependencies -project CameraBridge.xcodeproj -scheme CameraBridge \
      -clonedSourcePackagesDirPath "$packages" >/dev/null) || true
  fi
  if [ -x "$candidate/sign_update" ]; then
    SPARKLE_BIN="$candidate"
    return 0
  fi
  echo "error: Sparkle's tools were not found. Set SPARKLE_BIN to the folder with generate_keys and sign_update" >&2
  echo "       (from a Sparkle release download: https://github.com/sparkle-project/Sparkle/releases)." >&2
  return 1
}

# is_valid_ed_public_key KEY: an EdDSA public key is 32 bytes, base64 (44 characters).
is_valid_ed_public_key() {
  local key="$1" bytes
  bytes="$(printf '%s' "$key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" || return 1
  [ "$bytes" = "32" ]
}
