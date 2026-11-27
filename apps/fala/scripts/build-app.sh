#!/usr/bin/env bash
# Builds Fala and wraps it in a signed .app bundle so macOS can grant it
# Microphone and Accessibility permissions. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Fala"

APP="build/Fala.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fala"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. Permissions are tied to the signature, so after a rebuild macOS
# may ask again; a stable Developer ID signature avoids that later.
codesign --force --sign - --entitlements Resources/Fala.entitlements "$APP"

echo "Built $PWD/$APP"
echo "Run it with: open $PWD/$APP"
