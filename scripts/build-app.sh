#!/bin/bash
# Builds dist/Pith.app from the release binary and signs it. It uses the "Pith Local Development"
# identity when the keychain has one, else an ad-hoc signature; CODESIGN_IDENTITY overrides both
# ("-" is ad-hoc). See docs/BUILDING.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT/dist/Pith.app"
BUILD_ROOT="$ROOT/.build"
mkdir -p "$BUILD_ROOT"
STAGING_ROOT="$(mktemp -d "$BUILD_ROOT/pith-app.XXXXXX")"
STAGING_APP="$STAGING_ROOT/Pith.app"
LOCAL_SIGNING_IDENTITY="Pith Local Development"
if [[ -n "${CODESIGN_IDENTITY+x}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "\"$LOCAL_SIGNING_IDENTITY\"" >/dev/null; then
    IDENTITY="$LOCAL_SIGNING_IDENTITY"
else
    IDENTITY="-"
fi

cleanup() {
    if [[ -d "$STAGING_ROOT" ]]; then
        find "$STAGING_ROOT" -depth -delete
    fi
}
trap cleanup EXIT

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "error: Pith requires an Apple Silicon Mac." >&2
    exit 1
fi

cd "$ROOT"
swift build -c release --arch arm64
BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)"

# guide.json goes in Contents/Resources, where the app reads it (Guide.bundled(in:)). SwiftPM's
# Pith_PithCore.bundle would have to sit at the app's root, which code signing rejects.
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
install -m 0755 "$BIN_PATH/Pith" "$STAGING_APP/Contents/MacOS/Pith"
install -m 0644 "$ROOT/Resources/Info.plist" "$STAGING_APP/Contents/Info.plist"
install -m 0644 "$ROOT/Resources/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"
install -m 0644 "$BIN_PATH/Pith_PithCore.bundle/guide.json" \
    "$STAGING_APP/Contents/Resources/guide.json"
install -m 0644 "$ROOT/LICENSE" "$STAGING_APP/Contents/Resources/LICENSE.txt"
install -m 0644 \
    "$ROOT/THIRD_PARTY_NOTICES.md" \
    "$STAGING_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

codesign --force --sign "$IDENTITY" --options runtime "$STAGING_APP"
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"
plutil -lint "$STAGING_APP/Contents/Info.plist"

mkdir -p "$ROOT/dist"
if [[ -e "$APP_PATH" ]]; then
    find "$APP_PATH" -depth -delete
fi
mv "$STAGING_APP" "$APP_PATH"

echo "$APP_PATH"
