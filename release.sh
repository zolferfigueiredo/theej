#!/bin/bash
# One-time setup, shared with BiHan Brightness:
# xcrun notarytool store-credentials bihan --key <AuthKey.p8> --key-id <id> --issuer <issuer-id>
set -e
cd "$(dirname "$0")"

NAME=TheeJ
ID="Developer ID Application: Zolfer Figueiredo (497V6MCDS8)"
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' src/main.swift)
DMG="dist/$NAME-$VERSION.dmg"

./build.sh
rm -rf dist
mkdir -p dist/dmg
cp -R ".build/$NAME.app" dist/dmg/

# The DMG window's arrow from the app to Applications. It lives inside the app, before codesign so the signature
# covers it, and the DMG shows nothing but the app and Applications. The cream enamel gradient is the website's.
cat > dist/background.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="600" height="440">
<defs><linearGradient id="enamel" x2="0" y2="1"><stop offset="0" stop-color="#f3eee5"/><stop offset="1" stop-color="#ddd5c6"/></linearGradient></defs>
<rect width="600" height="440" fill="url(#enamel)"/>
<g fill="none" stroke="#86868b" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
<path d="M236 166C266 124 330 120 362 152"/><path d="M349 151.5h13.5v-13.5"/>
</g>
</svg>
EOF
for s in 1 2; do sips -s format png -z $((440 * s)) $((600 * s)) dist/background.svg --out "dist/bg$s.png" >/dev/null; done
tiffutil -cathidpicheck dist/bg1.png dist/bg2.png -out "dist/dmg/$NAME.app/Contents/Resources/dmg-background.tiff"
rm dist/background.svg dist/bg1.png dist/bg2.png

# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$ID" "dist/dmg/$NAME.app"
ln -s /Applications dist/dmg/Applications

# Finder lays out a temporary read-write copy (background, icon spots) and saves it in the volume's .DS_Store.
# Icon positions must match the arrow. Finder finds the volume by name, so no other TheeJ volume may be mounted.
! mount | grep -qi " on /Volumes/$NAME" || { echo "Eject every mounted $NAME volume first." >&2; exit 1; }
trap '[ -z "${MNT:-}" ] || hdiutil detach -quiet -force "$MNT"' EXIT
hdiutil create -quiet -volname "$NAME" -srcfolder dist/dmg -format UDRW dist/rw.dmg
hdiutil attach -quiet -readwrite -noverify -noautoopen dist/rw.dmg
MNT="/Volumes/$NAME"
osascript <<EOF
tell application "Finder" to tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 552}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 100
    set background picture of opts to file "$NAME.app:Contents:Resources:dmg-background.tiff"
    set position of item "$NAME.app" to {170, 160}
    set position of item "Applications" to {430, 160}
    update without registering applications
    close
end tell
EOF
until [ -f "$MNT/.DS_Store" ]; do sleep 1; done
rm -rf "$MNT/.fseventsd" "$MNT/.Trashes"
sync
hdiutil detach -quiet "$MNT"
MNT=
hdiutil convert -quiet dist/rw.dmg -format UDZO -o "$DMG"
rm -r dist/rw.dmg dist/dmg

codesign --timestamp --sign "$ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile bihan --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "Release ready: $DMG"
[ "${1:-}" != --url ] || {
  loc=$(curl -fsS -o /dev/null -w '%{redirect_url}' --data-urlencode "url=https://theej.zolfer.com/$NAME-$VERSION.dmg" https://url.zolfer.com/dmg)
  echo "Download link: https://url.zolfer.com/${loc##*c=}"
}
