#!/bin/bash
set -e
cd "$(dirname "$0")"

# A real .app, so macOS has an icon to show in System Settings, Activity Monitor and Finder.
APP=.build/DeJota.app
VERSION=$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' Sources/deej-mac/main.swift)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/DeJota" Sources/deej-mac/main.swift
"$APP/Contents/MacOS/DeJota" --iconset .build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" .build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DeJota</string>
    <key>CFBundleIdentifier</key><string>com.zolfer.dejota</string>
    <key>CFBundleExecutable</key><string>DeJota</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

echo "Built: $APP"
