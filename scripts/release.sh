#!/usr/bin/env bash
set -euo pipefail

# Builds the .app for both Apple Silicon and Intel, zips each with ditto,
# tags + creates a GitHub release with both archives attached.
#
# Usage:
#   ./scripts/release.sh v0.1.0
#   ./scripts/release.sh v0.1.0 --notes-file CHANGELOG.md
#   ./scripts/release.sh v0.1.0 --no-push          # build + zip only, skip gh release

if [ $# -lt 1 ]; then
    echo "Usage: $0 <tag> [--no-push] [--notes-file <path>]"
    echo "Example: $0 v0.1.0"
    exit 1
fi

TAG="$1"
shift
PUSH=true
NOTES_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-push)   PUSH=false; shift ;;
        --notes-file) NOTES_FILE="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ Building arm64 (Apple Silicon)"
./scripts/build-app.sh arm64

echo
echo "▶ Building x86_64 (Intel)"
./scripts/build-app.sh x86_64

echo
echo "▶ Verifying both binaries are correct architecture"
lipo -info "build/MacWindowZone-arm64.app/Contents/MacOS/MacWindowZone"
lipo -info "build/MacWindowZone-x86_64.app/Contents/MacOS/MacWindowZone"

echo
echo "▶ Packaging zips"
ARM_ZIP="build/MacWindowZone-${TAG}-arm64.zip"
INTEL_ZIP="build/MacWindowZone-${TAG}-x86_64.zip"
rm -f "$ARM_ZIP" "$INTEL_ZIP"

# Pre-rename bundles inside zip so unzipping always gives MacWindowZone.app.
TMP_ARM="$ROOT/.build/release-arm/MacWindowZone.app"
TMP_X86="$ROOT/.build/release-x86/MacWindowZone.app"
rm -rf "$(dirname "$TMP_ARM")" "$(dirname "$TMP_X86")"
mkdir -p "$(dirname "$TMP_ARM")" "$(dirname "$TMP_X86")"
cp -R "build/MacWindowZone-arm64.app"  "$TMP_ARM"
cp -R "build/MacWindowZone-x86_64.app" "$TMP_X86"
ditto -c -k --sequesterRsrc --keepParent "$TMP_ARM" "$ARM_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$TMP_X86" "$INTEL_ZIP"

echo
echo "▶ Sizes & checksums"
for z in "$ARM_ZIP" "$INTEL_ZIP"; do
    s=$(ls -l "$z" | awk '{print $5}')
    h=$(shasum -a 256 "$z" | awk '{print $1}')
    printf "  %s\n    size:   %d bytes (%.2f MB)\n    sha256: %s\n" "$z" "$s" "$(echo "scale=2; $s/1048576" | bc)" "$h"
done

if [ "$PUSH" = false ]; then
    echo
    echo "✓ Builds ready (skipping gh release as requested)."
    exit 0
fi

ARM_SHA=$(shasum -a 256 "$ARM_ZIP" | awk '{print $1}')
INTEL_SHA=$(shasum -a 256 "$INTEL_ZIP" | awk '{print $1}')

echo
echo "▶ Tag & push"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "  tag $TAG already exists locally, skipping creation"
else
    git tag -a "$TAG" -m "$TAG"
fi
git push origin "$TAG"

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    NOTES_ARG=(--notes-file "$NOTES_FILE")
else
    cat > "$ROOT/.build/release-notes.md" <<EOF
MacWindowZone $TAG.

Two architecture-specific builds:

| File | Architecture | macOS |
|---|---|---|
| \`MacWindowZone-${TAG}-arm64.zip\` | Apple Silicon (M1/M2/M3/...) | 14+ |
| \`MacWindowZone-${TAG}-x86_64.zip\` | Intel | 14+ |

Pick the one matching your Mac. To check: \`uname -m\` (\`arm64\` → Apple Silicon, \`x86_64\` → Intel).

## Install
1. Download the appropriate \`.zip\`, unzip.
2. Drag \`MacWindowZone.app\` into \`/Applications\`.
3. Grant Accessibility access in *System Settings → Privacy & Security → Accessibility* the first time you launch.

## SHA-256
\`\`\`
$ARM_SHA   MacWindowZone-${TAG}-arm64.zip
$INTEL_SHA   MacWindowZone-${TAG}-x86_64.zip
\`\`\`

See the [README](https://github.com/yfet/MacWindowZone/blob/main/README.md) for the full feature list and build instructions.
EOF
    NOTES_ARG=(--notes-file "$ROOT/.build/release-notes.md")
fi

echo
echo "▶ Creating GitHub release"
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "  release $TAG already exists — uploading assets with --clobber"
    gh release upload "$TAG" "$ARM_ZIP" "$INTEL_ZIP" --clobber
else
    gh release create "$TAG" \
        --title "MacWindowZone $TAG" \
        "${NOTES_ARG[@]}" \
        "$ARM_ZIP" \
        "$INTEL_ZIP"
fi

echo
echo "✓ Released $TAG"
gh release view "$TAG" --web 2>/dev/null || true