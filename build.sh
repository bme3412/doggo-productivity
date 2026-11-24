#!/bin/bash
# Builds Doggo and wraps it in a macOS app bundle at ./Doggo.app.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building (release)…"
swift build -c release

APP_NAME="Doggo"
APP="$APP_NAME.app"
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS remembers the permissions you grant (Automation, etc.)
codesign --force --deep --sign - "$APP" >/dev/null

echo ""
echo "Done: $(pwd)/$APP"
echo "Run it with:  open $APP"
echo "Optional: move it to /Applications so it survives rebuilds of this folder."
