#!/bin/bash
set -e
cd "$(dirname "$0")"

# A real .app, so macOS has an icon to show in System Settings, Activity Monitor and Finder.
APP=.build/TheeJ.app
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' src/main.swift)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# macOS 14 is the oldest the code builds for. A plain swiftc build targets the running macOS.
# One universal binary, so the same app runs on Apple Silicon and Intel.
for arch in arm64 x86_64; do
    swiftc -O -target $arch-apple-macos14 -o .build/TheeJ-$arch src/main.swift
done
lipo -create -output "$APP/Contents/MacOS/TheeJ" .build/TheeJ-arm64 .build/TheeJ-x86_64
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
