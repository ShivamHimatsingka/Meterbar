#!/bin/zsh
# Builds Meterbar.app next to this script.
set -e
cd "$(dirname "$0")"
APP=Meterbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Meterbar</string>
  <key>CFBundleIdentifier</key><string>local.meterbar</string>
  <key>CFBundleExecutable</key><string>Meterbar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NotchOverflowOpensAtAnchor</key><true/>
  <key>NotchOverflowSendsItemImages</key><true/>
</dict></plist>
PLIST
xcrun swiftc -O -wmo -swift-version 5 main.swift -o "$APP/Contents/MacOS/Meterbar" \
  -framework Cocoa -framework IOKit -framework SystemConfiguration -framework ServiceManagement
codesign --force -s - "$APP"
echo "Built $(pwd)/$APP"
