#!/bin/zsh
# Builds dist/Voice Mac.app (menu-bar only) that runs the engine from this repo.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="dist/Voice Mac.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp .build/release/VoiceMac "$APP/Contents/MacOS/VoiceMac"
cp .build/release/axd "$APP/Contents/MacOS/axd" # accessibility helper; runs under the app's Accessibility grant
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.voicemac.app</string>
  <key>CFBundleName</key><string>Voice Mac</string>
  <key>CFBundleExecutable</key><string>VoiceMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Voice Mac listens while you hold Option-Space so you can tell your Mac what to do.</string>
  <key>VoiceMacDir</key><string>$(cd .. && pwd)</string>
  <key>VoiceMacNode</key><string>$(command -v node)</string>
</dict></plist>
PLIST
# A stable identity keeps macOS permissions (Accessibility, Microphone) across rebuilds; ad-hoc signing
# changes identity every build. Uses SIGN_IDENTITY, else the first "Apple Development" certificate.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
perl -e 'alarm 60; exec @ARGV' codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/axd"
perl -e 'alarm 60; exec @ARGV' codesign --force --sign "$IDENTITY" "$APP"
echo "Signed with: $IDENTITY"
echo "Built $APP"
