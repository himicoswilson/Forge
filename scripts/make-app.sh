#!/usr/bin/env bash
# Wraps the release binary in a minimal Forge.app bundle (menu-bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

BINARY=".build/release/Forge"
APP="Forge.app"

[[ -x "$BINARY" ]] || { echo "error: $BINARY not found — run 'swift build -c release' first" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BINARY" "$APP/Contents/MacOS/Forge"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Forge</string>
    <key>CFBundleIdentifier</key>
    <string>dev.himicos.forge</string>
    <key>CFBundleName</key>
    <string>Forge</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
