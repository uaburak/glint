#!/bin/bash
# Builds the test sender and puts it in ~/Applications. Run it again after changing main.swift.
set -euo pipefail

NAME="Glint Test Sender"
BUNDLE_ID="dev.burak.glint.testsender"
EXECUTABLE="GlintTestSender"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Without an explicit target swiftc stamps the binary with a macOS newer than the one running it, and
# LaunchServices then refuses to open the app (error -10825).
swiftc -parse-as-library -O -target "$(uname -m)-apple-macos15.0" "$SOURCE_DIR/main.swift" -o "$APP/Contents/MacOS/$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Notifications need a signed bundle with a stable identifier; signing it to run locally is enough.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "kuruldu: $APP"
