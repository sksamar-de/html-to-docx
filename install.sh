#!/usr/bin/env bash
# Build (if needed) and install HTMLtoDOCX.app into /Applications.
#
# After installing, opening the app once and toggling "Launch at Login"
# registers it with macOS so it auto-starts on every boot.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="HTMLtoDOCX"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"

if [[ ! -d "$APP" ]]; then
    echo "▸ No build found, running build.sh first…"
    "$ROOT/build.sh"
fi

echo "▸ Installing to $TARGET…"
if [[ -d "$TARGET" ]]; then
    rm -rf "$TARGET"
fi
cp -R "$APP" "$TARGET"

echo "▸ Removing quarantine flag (so macOS doesn't block the local build)…"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

echo "✓ Installed."
echo
echo "  Launch:  open '$TARGET'"
echo "  Then in the app: turn on 'Launch at Login'."
