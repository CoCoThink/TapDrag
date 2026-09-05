#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/TapDrag.app"
DIST_DIR="$ROOT_DIR/dist"
INFO_PLIST="$ROOT_DIR/TapDrag/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST")"
ZIP_NAME="TapDrag-v${VERSION}-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

# A local self-signed development identity is intentionally never inherited by
# release packaging. Set this to a Developer ID identity when preparing an
# independently distributed build.
TAPDRAG_BUILD_CONFIGURATION=Release \
TAPDRAG_CODESIGN_IDENTITY="${TAPDRAG_RELEASE_CODESIGN_IDENTITY:--}" \
    "$ROOT_DIR/TapDrag/build.sh" >/dev/null

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo "$ZIP_PATH"
cat "$ZIP_PATH.sha256"
