#!/bin/zsh
set -euo pipefail

APP_PATH="${1:-build/3FDragUnstuck.app}"
LOCAL_IDENTITY="${THREE_F_DRAG_LOCAL_SIGNING_IDENTITY:-3FDragUnstuck Local Development}"

echo "Available Code Signing identities:"
security find-identity -p codesigning

if security find-identity -p codesigning | grep -F -q "\"$LOCAL_IDENTITY\""; then
    echo "Stable local identity: available ($LOCAL_IDENTITY)"
else
    echo "Stable local identity: unavailable"
fi

if [[ ! -d "$APP_PATH" ]]; then
    exit 0
fi

echo "Application signature:"
codesign -dvvv "$APP_PATH" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|Signature)='
codesign -d -r- "$APP_PATH" 2>&1
