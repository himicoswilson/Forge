#!/usr/bin/env bash
# Wraps the release binary in a minimal Forge.app bundle (menu-bar app, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

BINARY=".build/release/Forge"
RESOURCE_BUNDLE=".build/release/Forge_ForgeApp.bundle"
APP="Forge.app"

[[ -x "$BINARY" ]] || { echo "error: $BINARY not found — run 'swift build -c release' first" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/Forge"

# Copy the SwiftPM resource bundle so Bundle.module resolves at runtime
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

# Build Forge.icns from the app icon PNGs in the resource bundle
ASSET_DIR="$RESOURCE_BUNDLE/Assets.xcassets/AppIcon.appiconset"
if [[ -d "$ASSET_DIR" ]]; then
    ICONSET=$(mktemp -d)/Forge.iconset
    mkdir -p "$ICONSET"
    cp "$ASSET_DIR/16.png"   "$ICONSET/icon_16x16.png"
    cp "$ASSET_DIR/32.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$ASSET_DIR/32.png"   "$ICONSET/icon_32x32.png"
    cp "$ASSET_DIR/64.png"   "$ICONSET/icon_32x32@2x.png"
    cp "$ASSET_DIR/128.png"  "$ICONSET/icon_128x128.png"
    cp "$ASSET_DIR/256.png"  "$ICONSET/icon_128x128@2x.png"
    cp "$ASSET_DIR/256.png"  "$ICONSET/icon_256x256.png"
    cp "$ASSET_DIR/512.png"  "$ICONSET/icon_256x256@2x.png"
    cp "$ASSET_DIR/512.png"  "$ICONSET/icon_512x512.png"
    cp "$ASSET_DIR/1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Forge.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Forge</string>
    <key>CFBundleIconFile</key>
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
