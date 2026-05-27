#!/usr/bin/env bash
set -euo pipefail

# Builds a release .app bundle for MacWindowZone.
# Usage:
#   ./scripts/build-app.sh                   # host-arch release → build/MacWindowZone.app
#   ./scripts/build-app.sh debug             # host-arch debug
#   ./scripts/build-app.sh arm64             # Apple Silicon → build/MacWindowZone-arm64.app
#   ./scripts/build-app.sh x86_64            # Intel         → build/MacWindowZone-x86_64.app
#
# The result is a standalone .app you can drag into /Applications.

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MacWindowZone"
BUILD_DIR="$ROOT/build"

# Arch-suffixed bundle name for arm64 / x86_64 builds so both can coexist.
case "$CONFIG" in
    arm64|x86_64) APP_BUNDLE="$BUILD_DIR/${APP_NAME}-${CONFIG}.app" ;;
    *)            APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app" ;;
esac
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "▶ Compiling Swift package ($CONFIG)..."
cd "$ROOT"
case "$CONFIG" in
    debug)
        swift build
        PRODUCT_PATH="$(swift build --show-bin-path)/$APP_NAME"
        ;;
    arm64)
        swift build -c release --triple arm64-apple-macosx14.0
        PRODUCT_PATH="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/$APP_NAME"
        ;;
    x86_64)
        swift build -c release --triple x86_64-apple-macosx14.0
        PRODUCT_PATH="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/$APP_NAME"
        ;;
    release|*)
        swift build -c release
        PRODUCT_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
        ;;
esac

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
