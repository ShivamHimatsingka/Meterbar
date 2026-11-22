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
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Shivam Himatsingka. MIT License.</string>
  <key>NotchOverflowOpensAtAnchor</key><true/>
  <key>NotchOverflowSendsItemImages</key><true/>
</dict></plist>
PLIST
# Universal binary (Apple Silicon + Intel), deployable back to macOS 13 to match LSMinimumSystemVersion.
TMP=$(mktemp -d)
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -wmo -swift-version 5 -target "$ARCH-apple-macos13.0" main.swift -o "$TMP/Meterbar-$ARCH" \
    -framework Cocoa -framework IOKit -framework SystemConfiguration -framework ServiceManagement
done
lipo -create "$TMP/Meterbar-arm64" "$TMP/Meterbar-x86_64" -output "$APP/Contents/MacOS/Meterbar"
rm -rf "$TMP"
codesign --force -s - "$APP"
echo "Built $(pwd)/$APP"
