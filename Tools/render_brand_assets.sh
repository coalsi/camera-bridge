#!/bin/sh
# Renders every CameraBridge brand asset from the primary logo, App/Resources/Brand/CameraBridgeOutline.svg (amber house
# outline, white camera, 100 x 100 viewBox). The older filled artwork, CameraBridgeMark.svg, stays in the repo but is no
# longer used for any icon.
#
#   1. App icon (AppIcon.appiconset, 16...1024 @1x/@2x): a macOS-style tile (824 pt squircle in a 1024 canvas, dark
#      #2A2A2D to #1C1C1E, inner highlight and soft shadow) with the outline mark at about 62% of the tile. Each size is
#      rendered at its own pixel size by headless Chrome, with a heavier stroke at 64 px and below.
#   2. Menu bar template mark (MenuBarIcon.imageset, 18 pt @1x/@2x/@3x): black house outline + filled camera, alpha only.
#   3. In-app vector mark (BrandMark.imageset/BrandMark.pdf): the logo as authored, for the sidebar, onboarding, About.
#
# The HTML compositions come from Tools/compose_brand_assets.py. Needs Google Chrome, python3 and sips. Run from anywhere.
# The website's copies (../CameraBridge-web) are not touched here.
set -eu
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
BRAND=App/Resources/Brand
ASSETS=App/Resources/Assets.xcassets
ICONS="$ASSETS/AppIcon.appiconset"
MENUBAR="$ASSETS/MenuBarIcon.imageset"
BRANDMARK="$ASSETS/BrandMark.imageset"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 Tools/compose_brand_assets.py "$BRAND" "$TMP"

render() { # html pixels out.png
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size="$2,$2" --screenshot="$3" "file://$TMP/$1" >/dev/null 2>&1
}

# App icon: one render per pixel size.
for px in 16 32 64 128 256 512 1024; do render "icon_$px.html" "$px" "$TMP/icon_$px.png"; done
cp "$TMP/icon_16.png"   "$ICONS/icon_16x16.png"
cp "$TMP/icon_32.png"   "$ICONS/icon_16x16@2x.png"
cp "$TMP/icon_32.png"   "$ICONS/icon_32x32.png"
cp "$TMP/icon_64.png"   "$ICONS/icon_32x32@2x.png"
cp "$TMP/icon_128.png"  "$ICONS/icon_128x128.png"
cp "$TMP/icon_256.png"  "$ICONS/icon_128x128@2x.png"
cp "$TMP/icon_256.png"  "$ICONS/icon_256x256.png"
cp "$TMP/icon_512.png"  "$ICONS/icon_256x256@2x.png"
cp "$TMP/icon_512.png"  "$ICONS/icon_512x512.png"
cp "$TMP/icon_1024.png" "$ICONS/icon_512x512@2x.png"

# Menu bar template mark.
render menubar_18.html 18 "$MENUBAR/MenuBarIcon.png"
render menubar_36.html 36 "$MENUBAR/MenuBarIcon@2x.png"
render menubar_54.html 54 "$MENUBAR/MenuBarIcon@3x.png"
render menubar_216.html 216 "$TMP/menubar_216.png"

# In-app vector mark (a one-page 100 x 100 PDF; Chrome's print-to-pdf keeps the paths as vectors).
mkdir -p "$BRANDMARK"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$BRANDMARK/BrandMark.pdf" \
  "file://$TMP/brandmark.html" >/dev/null 2>&1

# Previews for the docs.
mkdir -p docs/screenshots
cp "$TMP/icon_1024.png" docs/screenshots/app_icon_1024.png
cp "$TMP/menubar_216.png" docs/screenshots/menubar_icon_2x_zoomed.png
echo "Brand assets rendered."
