#!/usr/bin/env bash
set -euo pipefail

# Builds a release .app bundle for MacWindowZone.
# Usage:
#   ./scripts/build-app.sh           # builds release .app into ./build/MacWindowZone.app
#   ./scripts/build-app.sh debug     # builds debug .app
#
# The result is a standalone .app you can drag into /Applications.

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacWindowZone"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "▶ Compiling Swift package ($CONFIG)..."
cd "$ROOT"
if [ "$CONFIG" = "debug" ]; then
    swift build
    PRODUCT_PATH="$(swift build --show-bin-path)/$APP_NAME"
else
    swift build -c release
    PRODUCT_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
fi

if [ ! -f "$PRODUCT_PATH" ]; then
    echo "✗ Build did not produce executable at $PRODUCT_PATH"
    exit 1
fi

echo "▶ Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PRODUCT_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/AppResources/Info.plist" "$CONTENTS/Info.plist"

# Regenerate the icon if missing, then bundle it.
if [ ! -f "$ROOT/AppResources/AppIcon.icns" ]; then
    echo "▶ Generating AppIcon.icns (one-time)..."
    (cd "$ROOT" && swift scripts/generate-icon.swift)
fi
if [ -f "$ROOT/AppResources/AppIcon.icns" ]; then
    cp "$ROOT/AppResources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Copy any extra resources bundled by SPM (e.g. MacWindowZone_MacWindowZone.bundle)
SPM_RESOURCE_BUNDLE_DIR="$(dirname "$PRODUCT_PATH")"
if compgen -G "$SPM_RESOURCE_BUNDLE_DIR"/*.bundle > /dev/null; then
    cp -R "$SPM_RESOURCE_BUNDLE_DIR"/*.bundle "$RESOURCES_DIR/"
fi

# Ad-hoc sign with a stable identifier so macOS treats this as the same app
# across rebuilds — minimises the number of times Accessibility access has
# to be re-granted. (You may still need to toggle it off/on once after the
# very first rebuild because the binary hash changes.)
echo "▶ Signing (ad-hoc, stable identifier)..."
codesign --force --deep --sign - \
    --identifier "dev.tefy.MacWindowZone" \
    --preserve-metadata=entitlements,flags \
    "$APP_BUNDLE" 2>/dev/null \
  || codesign --force --deep --sign - \
        --identifier "dev.tefy.MacWindowZone" \
        "$APP_BUNDLE"

echo "✓ Built $APP_BUNDLE"
echo
echo "Next steps:"
echo "  open '$APP_BUNDLE'"
echo "  Grant Accessibility in System Settings ▸ Privacy & Security ▸ Accessibility."
