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

# Sign with the local identity from scripts/create-signing-cert.sh when it
# exists: the designated requirement is then "identifier + certificate", so
# the Accessibility permission survives rebuilds. Otherwise fall back to an
# ad-hoc signature, which macOS identifies by binary hash — Accessibility
# then has to be re-granted after every rebuild.
SIGN_IDENTITY="${MWZ_SIGN_IDENTITY:-MacWindowZone Local Signing}"
SIGN_KEYCHAIN="${MWZ_SIGN_KEYCHAIN:-$HOME/Library/Keychains/macwindowzone-signing.keychain-db}"
SIGN_ARGS=(--sign -)
if [ -f "$SIGN_KEYCHAIN" ] && security find-certificate -c "$SIGN_IDENTITY" "$SIGN_KEYCHAIN" >/dev/null 2>&1; then
    security unlock-keychain -p "" "$SIGN_KEYCHAIN"
    # By SHA-1: a self-signed cert isn't "valid" for lookup by name.
    SIGN_HASH="$(security find-certificate -c "$SIGN_IDENTITY" -Z "$SIGN_KEYCHAIN" | awk '/SHA-1/ {print $NF; exit}')"
    SIGN_ARGS=(--sign "$SIGN_HASH")
    echo "▶ Signing with local identity '$SIGN_IDENTITY'..."
else
    echo "▶ Signing (ad-hoc, stable identifier)..."
    echo "  tip: run ./scripts/create-signing-cert.sh once so Accessibility survives rebuilds"
fi
codesign --force --deep "${SIGN_ARGS[@]}" \
    --identifier "dev.tefy.MacWindowZone" \
    --preserve-metadata=entitlements,flags \
    "$APP_BUNDLE" 2>/dev/null \
  || codesign --force --deep "${SIGN_ARGS[@]}" \
        --identifier "dev.tefy.MacWindowZone" \
        "$APP_BUNDLE"

echo "✓ Built $APP_BUNDLE"
echo
echo "Next steps:"
echo "  open '$APP_BUNDLE'"
echo "  Grant Accessibility in System Settings ▸ Privacy & Security ▸ Accessibility."
