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
# covers it, and the DMG shows nothing but the app and Applications. Transparent, so it suits light and dark.
cat > dist/background.svg <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="600" height="440">
<g fill="none" stroke="#86868b" stroke-width="3" stroke-linecap="round" stroke-linejoin="round">
<path d="M236 166C266 124 330 120 362 152"/><path d="M349 151.5h13.5v-13.5"/>
</g>
</svg>
EOF
for s in 1 2; do sips -s format png -z $((440 * s)) $((600 * s)) dist/background.svg --out "dist/bg$s.png" >/dev/null; done
tiffutil -cathidpicheck dist/bg1.png dist/bg2.png -out "dist/dmg/$NAME.app/Contents/Resources/dmg-background.tiff" >/dev/null
rm dist/background.svg dist/bg1.png dist/bg2.png

# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$ID" "dist/dmg/$NAME.app"
ln -s /Applications dist/dmg/Applications
# The window layout Finder saved once: icon positions (matching the arrow), size, no toolbar, and the background
# at TheeJ.app/Contents/Resources/dmg-background.tiff. Copying it in means the DMG is never mounted here.
cp dmg.DS_Store dist/dmg/.DS_Store

hdiutil create -volname "$NAME" -srcfolder dist/dmg -format UDZO "$DMG" >/dev/null
rm -r dist/dmg

codesign --timestamp --sign "$ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile bihan --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "Release ready: $DMG"
