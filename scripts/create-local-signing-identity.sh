#!/bin/zsh
set -euo pipefail

IDENTITY_NAME="${THREE_F_DRAG_LOCAL_SIGNING_IDENTITY:-3FDragUnstuck Local Development}"
KEYCHAIN="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')"

if [[ -z "$KEYCHAIN" || ! -f "$KEYCHAIN" ]]; then
    echo "Unable to locate the current user's login keychain." >&2
    exit 1
fi

if security find-identity -p codesigning | grep -F -q "\"$IDENTITY_NAME\""; then
    echo "Stable local signing identity is already available: $IDENTITY_NAME"
    exit 0
fi

# A certificate with this name but no matching private key cannot preserve the
# existing designated requirement. Do not silently replace it: doing so would
# force macOS to treat the rebuilt app as a newly authorized client.
if security find-certificate -a -c "$IDENTITY_NAME" -Z "$KEYCHAIN" | \
    grep -q "SHA-1 hash:"; then
    echo "A certificate named '$IDENTITY_NAME' exists, but its private key is unavailable." >&2
    echo "Restore the original private key, or remove the certificate only if you accept one new macOS authorization." >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR%/}/3FDragUnstuck-signing.XXXXXX")"
cleanup() {
    if [[ -d "$TEMP_DIR" && "$TEMP_DIR" == "${TMPDIR%/}/3FDragUnstuck-signing."* ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

CERTIFICATE_PATH="$TEMP_DIR/certificate.pem"
PRIVATE_KEY_PATH="$TEMP_DIR/private-key.pem"
IDENTITY_PATH="$TEMP_DIR/identity.p12"
IDENTITY_PASSWORD="$(openssl rand -hex 32)"

# The identity is local-only: its private key stays in the login keychain and
# only /usr/bin/codesign is granted non-interactive access to it.
openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
    -keyout "$PRIVATE_KEY_PATH" \
    -out "$CERTIFICATE_PATH" \
    -days 3650 \
    -subj "/CN=$IDENTITY_NAME" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    >/dev/null 2>&1

openssl pkcs12 -export \
    -inkey "$PRIVATE_KEY_PATH" \
    -in "$CERTIFICATE_PATH" \
    -name "$IDENTITY_NAME" \
    -out "$IDENTITY_PATH" \
    -passout "pass:$IDENTITY_PASSWORD" \
    >/dev/null 2>&1

security import "$IDENTITY_PATH" \
    -k "$KEYCHAIN" \
    -f pkcs12 \
    -P "$IDENTITY_PASSWORD" \
    -T /usr/bin/codesign \
    >/dev/null

if ! security find-identity -p codesigning | grep -F -q "\"$IDENTITY_NAME\""; then
    echo "The identity was imported but is not usable for code signing." >&2
    echo "Open Keychain Access, trust '$IDENTITY_NAME' for Code Signing, then rerun this command." >&2
    exit 1
fi

echo "Created stable local signing identity: $IDENTITY_NAME"
echo "It is for local development only and must not be used to publish releases."
