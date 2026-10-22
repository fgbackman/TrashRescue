#!/bin/bash
# Builds TrashRescue.app (with Dock + menu-bar icons) next to this script, then opens it.
set -euo pipefail
cd "$(dirname "$0")"

APP="TrashRescue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -parse-as-library -O TrashRescue.swift -o "$APP/Contents/MacOS/TrashRescue"

cp AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Trash Rescue</string>
    <key>CFBundleDisplayName</key><string>Trash Rescue</string>
    <key>CFBundleIdentifier</key><string>com.fred.TrashRescue</string>
    <key>CFBundleExecutable</key><string>TrashRescue</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
touch "$APP"   # nudge Finder/Dock to pick up the new icon
echo "Built $(pwd)/$APP"
open "$APP"
