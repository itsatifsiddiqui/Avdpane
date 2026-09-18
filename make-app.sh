#!/bin/bash
# Builds Avdpane in release mode and packs it into build/Avdpane.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP="$ROOT/build/Avdpane.app"
VERSION="${VERSION:-0.0.1}"

swift build -c release

# Regenerate the icon only when it is missing, the committed one is fine otherwise.
if [ ! -f Resources/AppIcon.icns ]; then
  ./Resources/make-icns.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Avdpane "$APP/Contents/MacOS/Avdpane"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Avdpane</string>
  <key>CFBundleDisplayName</key>
  <string>Avdpane</string>
  <key>CFBundleIdentifier</key>
  <string>com.arsync.avdpane</string>
  <key>CFBundleExecutable</key>
  <string>Avdpane</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Avdpane talks to Android emulators running on this Mac.</string>
</dict>
</plist>
PLIST

# Ad hoc signature, enough for local use. No Developer ID needed.
codesign --force --deep --sign - "$APP"

echo "$APP"
