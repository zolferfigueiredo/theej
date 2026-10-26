#!/bin/bash
set -e
cd "$(dirname "$0")"

# A real .app, so macOS has an icon to show in System Settings, Activity Monitor and Finder.
APP=.build/TheeJ.app
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/TheeJ/Version.swift)

# --fast, for run.sh: a debug build for this Mac only, without the tests. Otherwise one universal binary, so the
# same app runs on Apple Silicon and Intel. Package.swift sets macOS 14 as the oldest.
if [ "$1" = "--fast" ]; then
    FLAGS=()
else
    swift test
    FLAGS=(-c release --arch arm64 --arch x86_64)
fi
swift build "${FLAGS[@]}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# A new file rather than cp over the old one: macOS remembers the old binary's signature for that
# file, and kills the new one the moment it runs (Killed: 9, when making the icons just below).
rm -f "$APP/Contents/MacOS/TheeJ"
# SwiftPM records the oldest macOS as the SDK too, and macOS 26 and later draw an app built with an older SDK in
# their old look: lighter buttons, and Settings' tabs darker than the page. The SDK it is really built with goes
# in instead, and the oldest macOS stays. Signed again ad hoc at once: the icons below run it.
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/TheeJ"
OLDEST=$(vtool -show-build "$BIN" | awk '/minos/ { print $2; exit }')
vtool -set-build-version macos "$OLDEST" "$(xcrun --sdk macosx --show-sdk-version)" -replace -output "$APP/Contents/MacOS/TheeJ" "$BIN"
codesign --force --sign - "$APP/Contents/MacOS/TheeJ"
# iconutil packs every file in the folder, so sizes left over from older builds would ride along.
rm -rf .build/AppIcon.iconset
"$APP/Contents/MacOS/TheeJ" --iconset .build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" .build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TheeJ</string>
    <key>CFBundleIdentifier</key><string>com.zolfer.theej</string>
    <key>CFBundleExecutable</key><string>TheeJ</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>TheeJ sets the volume of the apps you give a knob. macOS counts that as recording their audio.</string>
</dict>
</plist>
EOF

# A certificate rather than ad hoc gives TheeJ a Team ID, which Login Items needs to show its name
# and icon instead of "unidentified developer".
if ! codesign --force --sign "Apple Development" "$APP" 2>/dev/null; then
    codesign --force --sign - "$APP"
    echo "No Apple Development certificate found, so signed ad hoc."
fi

echo "Built: $APP"
