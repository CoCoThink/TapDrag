#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/../build"
APP_DIR="$BUILD_DIR/TapDrag.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_CONFIGURATION="${TAPDRAG_BUILD_CONFIGURATION:-Release}"
case "$BUILD_CONFIGURATION" in
  Release)
    COMPILER_FLAGS=(-O2 -DNDEBUG)
    ;;
  Debug)
    COMPILER_FLAGS=(-O0 -g -DDEBUG=1)
    ;;
  *)
    echo "Unknown build configuration: $BUILD_CONFIGURATION (expected Release or Debug)" >&2
    exit 2
    ;;
esac
# Keep the established certificate as the default so the renamed app retains
# the same designated requirement and existing macOS privacy grants.
DEFAULT_LOCAL_SIGNING_IDENTITY="${TAPDRAG_LOCAL_SIGNING_IDENTITY:-3FDragUnstuck Local Development}"
SIGNING_IDENTITY="${TAPDRAG_CODESIGN_IDENTITY:-$DEFAULT_LOCAL_SIGNING_IDENTITY}"

if [[ "$SIGNING_IDENTITY" != "-" ]] && ! security find-identity -p codesigning | grep -F -q "\"$SIGNING_IDENTITY\""; then
  echo "The requested Code Signing identity is unavailable: $SIGNING_IDENTITY" >&2
  echo "For this machine, run 'make setup-local-signing' once." >&2
  echo "For an Apple-issued identity, set TAPDRAG_CODESIGN_IDENTITY explicitly." >&2
  echo "For a temporary ad-hoc build only, use TAPDRAG_CODESIGN_IDENTITY=- make build." >&2
  exit 2
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

clang \
  -arch arm64 \
  -fobjc-arc \
  -mmacosx-version-min=13.0 \
  "${COMPILER_FLAGS[@]}" \
  "$ROOT_DIR/Sources/main.m" \
  -o "$MACOS_DIR/TapDrag" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework IOKit \
  -framework ServiceManagement \
  -framework UniformTypeIdentifiers

cp -X "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -insert TapDragBuildConfiguration -string "$BUILD_CONFIGURATION" "$CONTENTS_DIR/Info.plist"
cp -X "$ROOT_DIR/Resources/AppIcon.png" "$RESOURCES_DIR/AppIcon.png"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

xattr -cr "$APP_DIR"
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=4 "$APP_DIR"

SIGNATURE_SUMMARY="$(codesign -dvv "$APP_DIR" 2>&1)"
if [[ "$SIGNING_IDENTITY" != "-" ]] && print -r -- "$SIGNATURE_SUMMARY" | grep -q '^Signature=adhoc$'; then
  echo "The application was unexpectedly ad-hoc signed." >&2
  exit 1
fi
print -r -- "$SIGNATURE_SUMMARY" | grep -E '^(Identifier|TeamIdentifier|Authority|Signature)='
codesign -d -r- "$APP_DIR" 2>&1

echo "$BUILD_CONFIGURATION build: $APP_DIR"
