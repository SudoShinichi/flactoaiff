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
    Sources/*.swift \
    -framework AppKit -framework SwiftUI

# The plist claims macOS 12; make that claim self-enforcing.
# Capture first: awk exiting early would SIGPIPE otool and, under pipefail, end the build silently.
LOADCMDS="$(otool -l "$APP_STAGE/Contents/MacOS/FlacToAiff")"
MINOS="$(awk '/minos/{print $2; exit}' <<<"$LOADCMDS")"
[ "$MINOS" = "12.0" ] || { echo "FAIL: binary minos=$MINOS, plist claims 12.0"; exit 1; }

echo "Rendering icon…"
mkdir -p "$APP_STAGE/Contents/Resources"
swiftc -O -o "$STAGE/make-icon" scripts/make-icon.swift -framework AppKit
"$STAGE/make-icon" "$STAGE/AppIcon.iconset"
iconutil -c icns -o "$APP_STAGE/Contents/Resources/AppIcon.icns" "$STAGE/AppIcon.iconset"

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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>FLAC Audio</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>org.xiph.flac</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
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
