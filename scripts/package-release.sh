#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/TapDrag.app"
DIST_DIR="$ROOT_DIR/dist"
INFO_PLIST="$ROOT_DIR/TapDrag/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST")"
ZIP_NAME="TapDrag-v${VERSION}-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SOURCE_NAME="TapDrag-v${VERSION}-source.tar.gz"
SOURCE_PATH="$DIST_DIR/$SOURCE_NAME"

# The corresponding source archive must match the files used to build the app.
if ! git -C "$ROOT_DIR" diff --quiet HEAD --; then
    echo "Commit tracked changes before packaging a release." >&2
    exit 2
fi

# A local self-signed development identity is intentionally never inherited by
# release packaging. Set this to a Developer ID identity when preparing an
# independently distributed build.
TAPDRAG_BUILD_CONFIGURATION=Release \
TAPDRAG_CODESIGN_IDENTITY="${TAPDRAG_RELEASE_CODESIGN_IDENTITY:--}" \
    "$ROOT_DIR/TapDrag/build.sh" >/dev/null

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
git -C "$ROOT_DIR" archive --format=tar.gz --prefix="TapDrag-v${VERSION}/" HEAD > "$SOURCE_PATH"

(
    cd "$DIST_DIR"
    shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
    shasum -a 256 "$SOURCE_NAME" > "$SOURCE_NAME.sha256"
)

echo "$ZIP_PATH"
echo "$SOURCE_PATH"
cat "$ZIP_PATH.sha256"
cat "$SOURCE_PATH.sha256"
