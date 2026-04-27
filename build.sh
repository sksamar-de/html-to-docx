#!/usr/bin/env bash
# Build a release .app bundle from the SwiftPM executable.
#
# Usage:   ./build.sh
# Output:  dist/HTMLtoDOCX.app
#
# Requires: macOS 13+, Xcode command line tools (`xcode-select --install`).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="HTMLtoDOCX"
BUNDLE_ID="com.htmltodocx.app"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "▸ Cleaning previous build…"
rm -rf "$APP"
mkdir -p "$DIST"

echo "▸ Building release binary…"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "✖ Build did not produce $BIN" >&2
    exit 1
fi

echo "▸ Assembling .app bundle…"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# PkgInfo is optional but Finder still likes seeing it.
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Ad-hoc code signing (required for SMAppService)…"
codesign --force --deep \
    --sign - \
    --entitlements "$ROOT/Resources/HTMLtoDOCX.entitlements" \
    --options runtime \
    "$APP"

echo "✓ Built: $APP"
echo
echo "  Run it:      open '$APP'"
echo "  Install it:  ./install.sh"
