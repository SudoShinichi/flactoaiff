#!/bin/bash
# Build FlacToAiff.app with swiftc (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FlacToAiff.app"
TARGET="arm64-apple-macos12.0"

# Assemble in a staging dir and move on success, so a failed compile never
# leaves a half-built bundle at the advertised path.
mkdir -p build
STAGE="$(mktemp -d build/.stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
APP_STAGE="$STAGE/FlacToAiff.app"
mkdir -p "$APP_STAGE/Contents/MacOS"

echo "Compiling…"
swiftc -O \
    -target "$TARGET" \
    -o "$APP_STAGE/Contents/MacOS/FlacToAiff" \
    Sources/Converter.swift Sources/main.swift \
    -framework AppKit -framework SwiftUI

# The plist claims macOS 12; make that claim self-enforcing.
MINOS="$(otool -l "$APP_STAGE/Contents/MacOS/FlacToAiff" | awk '/minos/{print $2; exit}')"
[ "$MINOS" = "12.0" ] || { echo "FAIL: binary minos=$MINOS, plist claims 12.0"; exit 1; }

cat > "$APP_STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FlacToAiff</string>
    <key>CFBundleDisplayName</key><string>FLAC → AIFF</string>
    <key>CFBundleIdentifier</key><string>local.flactoaiff</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>FlacToAiff</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign the *bundle* (not the bare binary) with a stable identifier so Info.plist
# is bound into the code seal and the code identity stops changing on every rebuild.
echo "Signing (ad-hoc, stable identifier)…"
codesign --force --sign - --identifier local.flactoaiff "$APP_STAGE"
codesign --verify --strict "$APP_STAGE"

rm -rf "$APP"
mv "$APP_STAGE" "$APP"
echo "Built $APP"
