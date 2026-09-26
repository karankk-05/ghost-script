#!/bin/bash
# Spike C — assemble spike-tcc-stub into a .app and sign it.
# Usage: ./assemble-stub.sh [SIGN_ID]   (default "-" = ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"

SIGN_ID="${1:--}"
BUILD_TAG="$(date +%s)"
APP="out/SpikeTCC.app"

swift build -c release --product spike-tcc-stub

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/spike-tcc-stub" "$APP/Contents/MacOS/SpikeTCC"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SpikeTCC</string>
    <key>CFBundleIdentifier</key><string>io.koerbaecher.ghostscreen.spike-tcc</string>
    <key>CFBundleName</key><string>SpikeTCC</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>SpikeBuildTag</key><string>${BUILD_TAG}</string>
</dict>
</plist>
EOF

# BUILD_TAG in the plist changes every assembly → different cdhash every time,
# exactly like a real rebuild would.
codesign --force --sign "$SIGN_ID" "$APP"
echo "assembled $APP (buildTag=$BUILD_TAG, sign=$SIGN_ID)"
codesign -dv "$APP" 2>&1 | grep -E 'Signature|TeamIdentifier|Authority' || true
