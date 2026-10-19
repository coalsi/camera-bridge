#!/bin/bash
# Builds a Camera Bridge release outside the App Store: Developer ID signed, notarized, stapled, as a DMG, with a Sparkle
# update signature and an appcast entry. Run it on the Mac that holds the Developer ID certificate.
#
#   Tools/release.sh                 full release
#   Tools/release.sh --local-check   prove the pipeline without secrets: archives Release with whatever development identity
#                                    is installed, checks hardened runtime and entitlements, builds the DMG and the appcast.
#                                    No Developer ID, no notarization, no Sparkle key in the Keychain needed. NEVER ship it.
#   Tools/release.sh --skip-notarize  Developer ID build and DMG, without notarizing (a test of signing only; not shippable)
#
# Steps
#   1. preflight: tools, Developer ID Application certificate for team XL4RAH5J96, notarytool profile, Sparkle key
#   2. archive Release (hardened runtime, Developer ID, secure timestamp)
#   3. export with the developer-id method
#   4. notarize the app (xcrun notarytool submit --keychain-profile camera-bridge-notary --wait), staple it
#   5. build the DMG, sign it, notarize it, staple it
#   6. sign the DMG for Sparkle (sign_update; the private key is in your Keychain, never printed)
#   7. write or append appcast.xml
#   8. print what to upload to the GitHub Release and to the website
#
# One-time setup (docs/distribution.md):
#   - Developer ID Application certificate in your login keychain (Xcode > Settings > Accounts > Manage Certificates, or developer.apple.com)
#   - xcrun notarytool store-credentials camera-bridge-notary --apple-id YOU@EXAMPLE.COM --team-id XL4RAH5J96
#       (it asks for an app-specific password from appleid.apple.com; the profile is kept in your Keychain)
#   - Tools/sparkle-generate-keys.sh   (creates the update signing key, puts the public key in project.yml)
#
# Environment (all optional)
#   TEAM_ID=XL4RAH5J96  NOTARY_PROFILE=camera-bridge-notary  SIGN_IDENTITY="Developer ID Application"
#   GITHUB_REPO=coalsi/camera-bridge  APPCAST_URL=https://www.camera-bridge.app/appcast.xml
#   APPCAST_IN=path/to/current/appcast.xml   (default: downloads APPCAST_URL; none yet is fine)
#   OUT_DIR=build/release   SPARKLE_BIN=...   SPARKLE_ED_KEY_FILE=...  (a private key file instead of the Keychain; CI only)
#   KEEP_BUILD=1 keeps OUT_DIR/dd (derived data) and the package checkout between runs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib/sparkle.sh
. "$REPO_ROOT/Tools/lib/sparkle.sh"

TEAM_ID="${TEAM_ID:-XL4RAH5J96}"
NOTARY_PROFILE="${NOTARY_PROFILE:-camera-bridge-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
GITHUB_REPO="${GITHUB_REPO:-coalsi/camera-bridge}"
APPCAST_URL="${APPCAST_URL:-https://www.camera-bridge.app/appcast.xml}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/release}"
SCHEME="CameraBridge"
APP_FILE="CameraBridge.app"
VOLUME_NAME="Camera Bridge"

LOCAL_CHECK=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --local-check) LOCAL_CHECK=1; SKIP_NOTARIZE=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }
# xcodebuild's output, reduced to what matters (xcbeautify when installed). The full log is OUT_DIR/xcodebuild.log.
build_log() {
  mkdir -p "$OUT_DIR"
  tee -a "$OUT_DIR/xcodebuild.log" | { grep -E "error:|warning: .*\.(swift|plist|yml)|\*\* [A-Z]+ |CodeSign " || true; }
}

# ---------------------------------------------------------------------------------------------------------- 1. preflight
step "1/8 Preflight"
for tool in xcodebuild xcodegen codesign hdiutil python3 security ditto shasum; do
  command -v "$tool" >/dev/null || fail "$tool is not installed or not on PATH"
done
xcrun --find stapler >/dev/null 2>&1 || fail "xcrun stapler is not available (install Xcode's command line tools)"
xcrun --find notarytool >/dev/null 2>&1 || fail "xcrun notarytool is not available (needs Xcode 13 or later)"

if [ "$LOCAL_CHECK" = 1 ]; then
  # Any code-signing identity that is installed; development ones are fine. A hash avoids ambiguity between several.
  DEV_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
  [ -n "$DEV_IDENTITY" ] || fail "--local-check needs an 'Apple Development' identity in the keychain"
  ARCHIVE_IDENTITY="$DEV_IDENTITY"
  echo "Local check: signing with '$DEV_IDENTITY' (not distributable). Skipping Developer ID, notarization and the Keychain key."
else
  # Exact certificate name, so a stale or duplicate one is visible. 'Developer ID Application' must belong to the team.
  CERT_LINE="$(security find-identity -v -p codesigning | grep "\"Developer ID Application: .*($TEAM_ID)\"" | head -1 || true)"
  if [ -z "$CERT_LINE" ]; then
    echo "error: no 'Developer ID Application' certificate for team $TEAM_ID is installed in your keychains." >&2
    echo "       Create it in Xcode (Settings > Accounts > your team > Manage Certificates > + > Developer ID Application)" >&2
    echo "       or at developer.apple.com > Certificates, then run this again. Installed identities:" >&2
    security find-identity -v -p codesigning >&2 || true
    exit 1
  fi
  ARCHIVE_IDENTITY="$SIGN_IDENTITY"
  echo "Certificate: $(echo "$CERT_LINE" | sed 's/^ *[0-9]*) [0-9A-F]* //')"
  if [ "$SKIP_NOTARIZE" = 0 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
      echo "error: the notarytool profile '$NOTARY_PROFILE' is missing or invalid. Create it once with:" >&2
      echo "       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOU@EXAMPLE.COM --team-id $TEAM_ID" >&2
      exit 1
    }
  fi
fi

find_sparkle_bin
KEY_ARGS=()
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE"); fi

step "Project"
xcodegen generate >/dev/null
mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/CameraBridge.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
PACKAGES="${SPARKLE_PACKAGES_DIR:-$REPO_ROOT/build/SourcePackages}"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$OUT_DIR/app.zip" "$OUT_DIR/dmg-staging" "$OUT_DIR/xcodebuild.log"

# ------------------------------------------------------------------------------------------------------------- 2. archive
step "2/8 Archive (Release, hardened runtime, $([ "$LOCAL_CHECK" = 1 ] && echo "$ARCHIVE_IDENTITY" || echo "Developer ID"))"
# Manual signing with the named identity and no provisioning profile: the app uses no capability that needs one.
# OTHER_CODE_SIGN_FLAGS asks for a secure timestamp, which notarization requires for Developer ID signatures.
xcodebuild archive \
  -project CameraBridge.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT_DIR/dd" -clonedSourcePackagesDirPath "$PACKAGES" \
  CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$ARCHIVE_IDENTITY" "DEVELOPMENT_TEAM=$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp" \
  | build_log
ARCHIVED_APP="$ARCHIVE/Products/Applications/$APP_FILE"
[ -d "$ARCHIVED_APP" ] || fail "the archive has no $APP_FILE (see the build output above)"

# ------------------------------------------------------------------------------------------------------------- 3. export
step "3/8 Export"
if [ "$LOCAL_CHECK" = 1 ]; then
  # A development-signed archive cannot be exported with the developer-id method; the archived app is what gets checked.
  mkdir -p "$EXPORT_DIR"
  ditto "$ARCHIVED_APP" "$EXPORT_DIR/$APP_FILE"
else
  cat >"$OUT_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>destination</key><string>export</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$OUT_DIR/ExportOptions.plist" \
    | build_log
fi
APP="$EXPORT_DIR/$APP_FILE"
[ -d "$APP" ] || fail "export produced no $APP_FILE"

# Verify what will be shipped: signature intact, hardened runtime on every executable, no sandbox/debug entitlements,
# the update key present, the right bundle.
step "Checking the signed app"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -3
codesign -d --entitlements :- "$APP" 2>/dev/null >"$OUT_DIR/entitlements.plist" || true
ENT_KEYS="$(python3 - "$OUT_DIR/entitlements.plist" <<'PY'
import plistlib, sys
try:
    data = plistlib.load(open(sys.argv[1], "rb"))
except Exception:
    data = {}
print(" ".join(sorted(data)))
PY
)"
echo "Entitlements: ${ENT_KEYS:-none}"
case " $ENT_KEYS " in
  *" com.apple.security.app-sandbox "*) fail "the app is sandboxed; the Developer ID build must not be (ENABLE_APP_SANDBOX)" ;;
  *" com.apple.security.get-task-allow "*) fail "the app carries get-task-allow (a debuggable build); notarization would refuse it" ;;
esac
NOT_HARDENED=0
while IFS= read -r -d '' file; do
  # Every Mach-O in the bundle (the app, Sparkle's helpers and XPC services, the framework binary).
  if [[ "$(file "$file")" == *Mach-O* ]]; then
    flags="$(codesign -dv "$file" 2>&1 | sed -n 's/^CodeDirectory.*flags=\(0x[0-9a-f]*\).*/\1/p' | head -1)"
    if [ -z "$flags" ] || [ $(( flags & 0x10000 )) -eq 0 ]; then
      echo "  not hardened: ${file#"$APP"/} (flags ${flags:-none})"; NOT_HARDENED=1
    fi
  fi
done < <(find "$APP" -type f -perm -u+x -print0)
[ "$NOT_HARDENED" = 0 ] || fail "some executables lack the hardened runtime flag, see above"
echo "Hardened runtime: on for every executable in the bundle"
if [ "$LOCAL_CHECK" = 0 ]; then
  # Captured first: under pipefail, `codesign | grep -q` fails when grep stops reading at the first match.
  SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
  grep -q "Authority=Developer ID Application" <<<"$SIGNATURE_INFO" || fail "the app is not signed with Developer ID Application"
  grep -q "Timestamp=" <<<"$SIGNATURE_INFO" || fail "the app has no secure timestamp"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
echo "Version $VERSION (build $BUILD), feed $FEED"
[ "$FEED" = "$APPCAST_URL" ] || echo "warning: the app's SUFeedURL ($FEED) is not APPCAST_URL ($APPCAST_URL)"
if [ "$LOCAL_CHECK" = 0 ]; then
  [ -n "$APP_KEY" ] || fail "SUPublicEDKey is empty in the app: run Tools/sparkle-generate-keys.sh first"
  if [ ${#KEY_ARGS[@]} -eq 0 ]; then
    KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]' || true)"
    [ "$KEYCHAIN_KEY" = "$APP_KEY" ] || fail "the update key in your Keychain does not match SUPublicEDKey in the app; installed copies would reject this update"
  fi
elif [ -z "$APP_KEY" ]; then
  echo "note: SUPublicEDKey is empty (Tools/sparkle-generate-keys.sh has not been run); fine for a local check"
fi

FILE_STEM="CameraBridge-$VERSION"
DMG="$OUT_DIR/$FILE_STEM.dmg"
rm -f "$DMG"

# --------------------------------------------------------------------------------------------- 4. notarize + staple the app
notarize() {  # notarize FILE: submits, waits, fails with Apple's log when it is not accepted
  local file="$1" output id status
  output="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || {
    echo "$output" >&2
    id="$(echo "$output" | sed -n 's/^ *id: *//p' | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization of $(basename "$file") failed"
  }
  echo "$output" | tail -6
  status="$(echo "$output" | sed -n 's/^ *status: *//p' | tail -1)"
  if [ "$status" != "Accepted" ]; then
    id="$(echo "$output" | sed -n 's/^ *id: *//p' | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "notarization of $(basename "$file") ended with status '${status:-unknown}'"
  fi
}

if [ "$SKIP_NOTARIZE" = 1 ]; then
  step "4/8 Notarize app: skipped ($([ "$LOCAL_CHECK" = 1 ] && echo "--local-check" || echo "--skip-notarize")); the result is NOT shippable"
else
  step "4/8 Notarize and staple the app"
  ditto -c -k --keepParent "$APP" "$OUT_DIR/app.zip"
  notarize "$OUT_DIR/app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$OUT_DIR/app.zip"
fi

# ------------------------------------------------------------------------------------------------------------ 5. DMG
step "5/8 DMG"
STAGING="$OUT_DIR/dmg-staging"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/$APP_FILE"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
if [ "$LOCAL_CHECK" = 0 ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  codesign --verify --verbose=1 "$DMG" 2>&1 | tail -2
  if [ "$SKIP_NOTARIZE" = 0 ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | tail -2 || true
    spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tail -2 || true
  fi
fi
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"

# ----------------------------------------------------------------------------------------------- 6. Sparkle signature
step "6/8 Sparkle signature"
SIGNATURE=""
if [ "$LOCAL_CHECK" = 1 ] && [ ${#KEY_ARGS[@]} -eq 0 ]; then
  echo "Local check without SPARKLE_ED_KEY_FILE: not signing the update (the real key is only used for real releases)."
  SIGNATURE="LOCAL-CHECK-UNSIGNED"
else
  # sign_update -p prints only the signature. The private key is read from the Keychain (or SPARKLE_ED_KEY_FILE) and not shown.
  SIGNATURE="$("$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} -p "$DMG")"
  [ -n "$SIGNATURE" ] || fail "sign_update returned no signature"
  echo "edSignature: $SIGNATURE"
fi
LENGTH="$(stat -f %z "$DMG")"

# ----------------------------------------------------------------------------------------------------------- 7. appcast
step "7/8 appcast.xml"
APPCAST_OLD="$OUT_DIR/appcast.previous.xml"
APPCAST_NEW="$OUT_DIR/appcast.xml"
rm -f "$APPCAST_OLD"
if [ -n "${APPCAST_IN:-}" ]; then
  cp "$APPCAST_IN" "$APPCAST_OLD"
  echo "Appending to $APPCAST_IN"
elif [ "$LOCAL_CHECK" = 0 ] && curl -fsS --max-time 20 -o "$APPCAST_OLD" "$APPCAST_URL" 2>/dev/null; then
  echo "Appending to the live $APPCAST_URL"
else
  rm -f "$APPCAST_OLD"
  echo "No existing appcast: starting a new one"
fi
DMG_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$FILE_STEM.dmg"
EXISTING_ARGS=()
if [ -f "$APPCAST_OLD" ]; then EXISTING_ARGS=(--existing "$APPCAST_OLD"); fi
python3 "$REPO_ROOT/Tools/update_appcast.py" --out "$APPCAST_NEW" ${EXISTING_ARGS[@]+"${EXISTING_ARGS[@]}"} \
  --title "Camera Bridge $VERSION" --short-version "$VERSION" --build "$BUILD" \
  --url "$DMG_URL" --signature "$SIGNATURE" --length "$LENGTH" \
  --min-os "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")" \
  --notes-url "https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"

# -------------------------------------------------------------------------------------------------------------- 8. report
step "8/8 Done"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if [ "$LOCAL_CHECK" = 1 ]; then
  echo "LOCAL CHECK ONLY: nothing below is shippable (development signature, not notarized, update not signed)."
fi
cat <<EOF

Version $VERSION (build $BUILD)
  DMG      $DMG
  sha256   $SHA
  appcast  $APPCAST_NEW

Upload:
  1. GitHub Release  v$VERSION  on $GITHUB_REPO  ->  attach the DMG
       gh release create v$VERSION "$DMG" --repo $GITHUB_REPO --title "Camera Bridge $VERSION" --notes-file RELEASE_NOTES.md
     (the appcast points at $DMG_URL)
  2. The website  ->  publish appcast.xml at $APPCAST_URL
       cp "$APPCAST_NEW" <website repo>/public/appcast.xml   (then deploy)
     Publish the appcast AFTER the release is public, or running copies will see an update they cannot download yet.
  3. Keep appcast.xml: the next release appends to it (APPCAST_IN=... or the live copy).
EOF
if [ "${KEEP_BUILD:-0}" != 1 ]; then
  rm -rf "$OUT_DIR/dd" "$ARCHIVE"
fi
