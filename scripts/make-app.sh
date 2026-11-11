#!/usr/bin/env bash
# Build a runnable .app bundle from the SwiftPM executable. SwiftPM does not
# produce bundles, but global hotkeys, the status item and Accessibility
# permission all behave more predictably from a real signed app.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build -c release --product PasteApp --show-bin-path)"

if [ ! -f AppIcon.icns ]; then
  echo "AppIcon.icns is missing at the repository root" >&2
  exit 1
fi

APP="dist/Paste.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PasteApp" "$APP/Contents/MacOS/Paste"
cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.pasteclone.app</string>
  <key>CFBundleName</key>
  <string>Paste</string>
  <key>CFBundleDisplayName</key>
  <string>Paste</string>
  <key>CFBundleExecutable</key>
  <string>Paste</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.8.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.pasteclone.app "$APP"
codesign --verify --verbose=1 "$APP"
echo "built: $PWD/$APP"
echo "run:   open \"$PWD/$APP\""
echo "check: \"$APP/Contents/MacOS/Paste\" --self-check"
