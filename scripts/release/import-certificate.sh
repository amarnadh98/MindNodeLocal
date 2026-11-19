#!/bin/bash
# Imports a Developer ID Application certificate (base64-encoded .p12 in
# APPLE_CERTIFICATE_BASE64, its password in APPLE_CERTIFICATE_PASSWORD)
# into a fresh keychain so the export step can sign with it (SPEC §13
# step 3: "Developer ID if secrets present"). The keychain exists only
# for this release run; re-running the script replaces it.

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${APPLE_CERTIFICATE_BASE64:?APPLE_CERTIFICATE_BASE64 (base64 .p12) is required}"
: "${APPLE_CERTIFICATE_PASSWORD:=}"

KEYCHAIN_PATH="$HOME/Library/Keychains/arbor-release.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"

# Replace any keychain left by an earlier run.
security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 900 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

cert_p12="$(mktemp -t arbor-dev-id).p12"
trap 'rm -f "$cert_p12"' EXIT
printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode >"$cert_p12"
security import "$cert_p12" -k "$KEYCHAIN_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/xcrun

# Put the release keychain first in the search list and let the signing
# tools use the identity without a UI prompt.
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
security set-key-partition-list -S apple-tool:,apple: \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

log "Developer ID certificate imported into $(basename "$KEYCHAIN_PATH")"
