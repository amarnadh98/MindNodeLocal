#!/bin/bash
# SPEC §13 step 6: run Sparkle's generate_appcast to produce appcast.xml
# with an EdDSA signature over the update archive.
#
# usage: appcast.sh <path-to-Arbor-*.dmg> <output-dir> \
#            --download-url-prefix <release-download-url>
#
# The EdDSA private key (ed25519 .pem, produced by Sparkle's
# `generate_keys -x key.pem` and kept OUT of the repo) comes from
# either:
#   SPARKLE_EDDSA_PRIVATE_KEY       base64 of the .pem file (CI secret)
#   SPARKLE_EDDSA_PRIVATE_KEY_FILE  a local file path
#
# Prints <output-dir>/appcast.xml.

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DMG_PATH="${1:?usage: appcast.sh <dmg> <output-dir> --download-url-prefix <url>}"
OUT_DIR="${2:?usage: appcast.sh <dmg> <output-dir> --download-url-prefix <url>}"
shift 2 || die "usage: appcast.sh <dmg> <output-dir> --download-url-prefix <url>"

DOWNLOAD_URL_PREFIX=""
while [ $# -gt 0 ]; do
    case "$1" in
        --download-url-prefix)
            DOWNLOAD_URL_PREFIX="${2:?--download-url-prefix needs a value}"
            shift 2
            ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -n "$DOWNLOAD_URL_PREFIX" ] || die "--download-url-prefix is required"
[ -f "$DMG_PATH" ] || die "no dmg at $DMG_PATH"
mkdir -p "$OUT_DIR"

# Locate Sparkle's generate_appcast, which ships inside the SPM
# checkout (SPM resolves Sparkle for the app target). Check the
# release build's own DerivedData first (build-app.sh), then the
# default one for local runs.
GEN="${GENERATE_APPCAST_BIN:-}"
if [ -z "$GEN" ]; then
    GEN="$(find "$OUT_DIR" -maxdepth 7 -type f -name generate_appcast \
        -path '*Sparkle/bin/*' -print -quit 2>/dev/null || true)"
fi
if [ -z "$GEN" ]; then
    GEN="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f \
        -name generate_appcast -path '*Sparkle/bin/*' -print -quit 2>/dev/null || true)"
fi
[ -n "$GEN" ] && [ -x "$GEN" ] || die "generate_appcast not found (set GENERATE_APPCAST_BIN)"

# Materialize the private key without leaving it in the tree.
STAGING_DIR="$(mktemp -d)"
TEMP_KEY=""
cleanup() {
    # Only the temp copy we decoded is removed; a user-provided key
    # file (SPARKLE_EDDSA_PRIVATE_KEY_FILE) stays where it is.
    rm -f "$TEMP_KEY"
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

if [ -n "${SPARKLE_EDDSA_PRIVATE_KEY_FILE:-}" ]; then
    KEY_FILE="$SPARKLE_EDDSA_PRIVATE_KEY_FILE"
    [ -f "$KEY_FILE" ] || die "no key file at $KEY_FILE"
elif [ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]; then
    TEMP_KEY="$(mktemp -t arbor-eddsa).pem"
    KEY_FILE="$TEMP_KEY"
    printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" | base64 --decode >"$KEY_FILE"
else
    die "set SPARKLE_EDDSA_PRIVATE_KEY (base64 .pem) or SPARKLE_EDDSA_PRIVATE_KEY_FILE"
fi

# generate_appcast writes appcast.xml into the folder holding the
# archives, so run it over a staging copy.
ditto "$DMG_PATH" "$STAGING_DIR"

log "Generating appcast.xml (EdDSA-signed)"
# generate_appcast logs to stdout: stdout stays reserved for the
# appcast path this script prints.
"$GEN" --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$STAGING_DIR" >&2

[ -f "$STAGING_DIR/appcast.xml" ] || die "generate_appcast produced no appcast.xml"
mv "$STAGING_DIR/appcast.xml" "$OUT_DIR/appcast.xml"
log "Wrote $OUT_DIR/appcast.xml"
printf '%s\n' "$OUT_DIR/appcast.xml"
