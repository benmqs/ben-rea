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

# Sign with a stable identity when one exists, so macOS keeps the Microphone and
# Accessibility permissions across rebuilds. Override with FALA_SIGN_IDENTITY; falls back to
# an ad-hoc signature, which makes macOS ask again after every rebuild.
IDENTITY="${FALA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
codesign --force --sign "${IDENTITY:--}" --entitlements Resources/Fala.entitlements "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc signature}"

echo "Built $PWD/$APP"
echo "Run it with: open $PWD/$APP"
