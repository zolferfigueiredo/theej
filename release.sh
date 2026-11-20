#!/bin/bash
# Set appVersion in Sources/TheeJ/Version.swift first. Builds dist/TheeJ-<version>.dmg, signs and notarizes it with Developer ID,
# then publishes it as a GitHub release of the current commit, which must be pushed.
# .github/workflows/release.yml runs it in two halves on every push to main:
#   ./release.sh build  the tests and the unsigned dist/dmg/TheeJ.app, on GitHub's Mac
#   ./release.sh sign   Developer ID, the DMG, notarization and the release, on the self-hosted runner on z's Mac
# With neither it does both, by hand. Both stop early when this version is already released.
# One-time setup, shared with ClaudioStat:
# xcrun notarytool store-credentials bihan --key <AuthKey.p8> --key-id <id> --issuer <issuer-id>
set -e
cd "$(dirname "$0")"
MODE=all
case "${1:-}" in build | sign) MODE=$1; shift ;; esac

NAME=TheeJ
ID="Developer ID Application: Zolfer Figueiredo (497V6MCDS8)"
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/TheeJ/Version.swift)
DMG="dist/$NAME-$VERSION.dmg"
if gh release view "v$VERSION" -R zolferfigueiredo/theej >/dev/null 2>&1; then
  echo "v$VERSION is already released."
  exit 0
fi
# A version with a "-", 2.7.0-dac-beta.1, is a beta: a pre-release, which GitHub never calls latest, so neither the
# apps' update check nor the website or the cask offer it. A beta branch publishes betas only.
PRERELEASE=()
case $VERSION in *-*) PRERELEASE=(--prerelease) ;; esac
case "${GITHUB_REF_NAME:-}" in *-beta)
  [ ${#PRERELEASE[@]} -gt 0 ] || { echo "$GITHUB_REF_NAME publishes betas only, and $VERSION isn't one."; exit 0; } ;;
esac

# The build half.
if [ "$MODE" != sign ]; then
./build.sh
rm -rf dist
mkdir -p dist/dmg
cp -R ".build/$NAME.app" dist/dmg/

# The DMG window's background lives inside the app, before codesign so the signature covers it, and the DMG shows
# nothing but the app and Applications.
swift Icon/make-dmg-background.swift dist/bg
tiffutil -cathidpicheck dist/bg/background.png dist/bg/background@2x.png -out "dist/dmg/$NAME.app/Contents/Resources/dmg-background.tiff"
rm -r dist/bg
fi

# The sign half.
[ "$MODE" != build ] || exit 0
[ -d "dist/dmg/$NAME.app" ] || { echo "dist/dmg/$NAME.app is missing: run ./release.sh build first." >&2; exit 1; }
# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$ID" "dist/dmg/$NAME.app"
ln -sfn /Applications dist/dmg/Applications

# The window's layout (background, icon spots) as Finder saved it, so no Finder window opens while a release builds.
# dmg/layout.sh makes it again when the background or the icon spots change.
cp dmg/layout.DS_Store dist/dmg/.DS_Store
hdiutil create -quiet -volname "$NAME" -srcfolder dist/dmg -format UDZO "$DMG"
rm -r dist/dmg

codesign --timestamp --sign "$ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile bihan --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
echo "Release ready: $DMG"
[ "${1:-}" != --url ] || {
  loc=$(curl -fsS -o /dev/null -w '%{redirect_url}' --data-urlencode "url=https://theej.zolfer.com/$NAME-$VERSION.dmg" https://url.zolfer.com/dmg)
  echo "Download link: https://url.zolfer.com/${loc##*c=}"
}
# The apps learn the newest version from releases/latest/download/latest.json, the same file the website serves.
printf '{"version": "%s"}\n' "$VERSION" > dist/latest.json
gh release create "v$VERSION" "$DMG" dist/latest.json -R zolferfigueiredo/theej --target "$(git rev-parse HEAD)" --title "$NAME $VERSION" --generate-notes "${PRERELEASE[@]}"
