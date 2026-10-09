#!/bin/bash
# Xcode build phase: puts the go2rtc helper into the app bundle (Contents/Helpers/go2rtc) and signs it. Skips with a note when the
# helper was not fetched (Tools/fetch-go2rtc.sh): the app then builds and runs without it, and cloud cameras say the helper is missing.
#
# Reads from Xcode's build settings; set CB_GO2RTC_BINARY to use a binary from elsewhere.
set -eu

SOURCE="${CB_GO2RTC_BINARY:-${SRCROOT:?}/build/helpers/go2rtc}"
DESTINATION_DIRECTORY="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}/Helpers"
DESTINATION="$DESTINATION_DIRECTORY/go2rtc"

if [ ! -f "$SOURCE" ]; then
  rm -f "$DESTINATION"
  echo "note: go2rtc helper not found at $SOURCE; building without it (run Tools/fetch-go2rtc.sh to include it)."
  exit 0
fi

mkdir -p "$DESTINATION_DIRECTORY"
cp -f "$SOURCE" "$DESTINATION"
chmod 755 "$DESTINATION"

# Nested code is signed before the app that contains it. Developer ID builds get the hardened runtime and a secure timestamp (what
# notarization needs); development builds are signed ad hoc.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier "com.coreysilvia.CameraBridge.go2rtc" "$DESTINATION"
else
  codesign --force --sign - --identifier "com.coreysilvia.CameraBridge.go2rtc" "$DESTINATION"
fi
echo "go2rtc helper embedded: $DESTINATION"
