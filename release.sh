#!/bin/bash
# One-time setup: xcrun notarytool store-credentials theej --key <AuthKey.p8> --key-id <id> --issuer <issuer-id>
set -e
cd "$(dirname "$0")"

NAME=TheeJ
ID="Developer ID Application: Zolfer Figueiredo (497V6MCDS8)"
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/deej-mac/main.swift)
DMG="dist/$NAME-$VERSION.dmg"

./build.sh
rm -rf dist
mkdir -p dist/dmg/.background
cp -R ".build/$NAME.app" dist/dmg/
# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$ID" "dist/dmg/$NAME.app"
ln -s /Applications dist/dmg/Applications

# The arrow from the app to Applications, and nothing else. Finder draws file names in black over a
# background picture, even in dark mode, so on black they vanish and the picture carries the labels.
# .AppleSystemUIFont is the only font name sips maps to SF.
cat > dist/background.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="600" height="440">
<rect width="600" height="440"/>
<g fill="none" stroke="#86868b" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
<path d="M236 166C266 124 330 120 362 152"/><path d="M349 151.5h13.5v-13.5"/>
</g>
<g font-family=".AppleSystemUIFont" font-size="16" fill="#f5f5f7" fill-opacity=".85" text-anchor="middle">
<text x="170" y="250">$NAME.app</text><text x="430" y="250">Applications</text>
</g>
</svg>
EOF
for s in 1 2; do sips -s format png -z $((440 * s)) $((600 * s)) dist/background.svg --out "dist/bg$s.png" >/dev/null; done
tiffutil -cathidpicheck dist/bg1.png dist/bg2.png -out dist/dmg/.background/background.tiff
rm dist/background.svg dist/bg1.png dist/bg2.png

# Finder addresses the volume by name, so a mounted older copy would get the layout instead.
[ ! -e "/Volumes/$NAME" ] || { echo "Eject /Volumes/$NAME first." >&2; exit 1; }
hdiutil create -volname "$NAME" -srcfolder dist/dmg -format UDRW dist/rw.dmg >/dev/null
hdiutil attach -noverify -noautoopen dist/rw.dmg >/dev/null
osascript <<EOF
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 552}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 100
    set text size of opts to 10
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" to {170, 160}
    set position of item "Applications" to {430, 160}
    close
  end tell
end tell
EOF
until [ -f "/Volumes/$NAME/.DS_Store" ]; do sleep 1; done
hdiutil detach "/Volumes/$NAME" >/dev/null
hdiutil convert dist/rw.dmg -format UDZO -o "$DMG" >/dev/null
rm -r dist/rw.dmg dist/dmg

codesign --timestamp --sign "$ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile theej --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "Release ready: $DMG"
