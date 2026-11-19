#!/bin/bash
# SPEC §13 step 2: build + archive Arbor and export a signed .app.
#
# Modes:
#   --developer-id  Export with the Developer ID certificate named by
#                  APPLE_SIGNING_IDENTITY (must already be in the
#                  keychain; see import-certificate.sh).
#   --adhoc         Ad-hoc signature (SPEC §13 path B — no Apple
#                  Developer Program membership needed). Default.
#
# usage: build-app.sh --adhoc|--developer-id <output-dir>
# Leaves <output-dir>/Arbor.app and prints the app version.

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MODE="${1:---adhoc}"
case "$MODE" in
    --adhoc) MODE="adhoc" ;;
    --developer-id) MODE="developer-id" ;;
    *) die "usage: build-app.sh --adhoc|--developer-id <output-dir>" ;;
esac
shift || true
OUT_DIR="${1:?usage: build-app.sh --adhoc|--developer-id <output-dir>}"
mkdir -p "$OUT_DIR"

require_tool xcodebuild
require_tool xcodegen

# Regenerate the project so a stale checked-in project can't drift
# from project.yml.
log "Generating Xcode project"
(cd "$ARBOR_ROOT" && xcodegen generate >/dev/null)

ARCHIVE_PATH="$OUT_DIR/Arbor.xcarchive"
DERIVED_DIR="${DERIVED_DATA_DIR:-$OUT_DIR/DerivedData}"

if [ "$MODE" = "developer-id" ]; then
    : "${APPLE_SIGNING_IDENTITY:?developer-id mode needs APPLE_SIGNING_IDENTITY, e.g. 'Developer ID Application: Name (TEAMID)'}"
    SIGN_ARGS=("CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=$APPLE_SIGNING_IDENTITY")
else
    # The ad-hoc identity '-' works on any machine, certificates or
    # not, and still enables the Hardened Runtime flag on the bundle.
    SIGN_ARGS=("CODE_SIGN_IDENTITY=-")
fi

log "Archiving Arbor ($MODE)"
xcodebuild -project "$ARBOR_ROOT/Arbor.xcodeproj" -scheme Arbor \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DIR" \
    -archivePath "$ARCHIVE_PATH" "${SIGN_ARGS[@]}" archive -quiet

APP_IN_ARCHIVE="$(find "$ARCHIVE_PATH/Products/Applications" \
    -maxdepth 1 -name '*.app' -print -quit)"
[ -n "$APP_IN_ARCHIVE" ] || die "no .app found inside the archive"

if [ "$MODE" = "developer-id" ]; then
    # The archive-and-export flow is the one Sparkle documents for
    # distribution: export re-signs the app and Sparkle's nested
    # helpers with the Developer ID certificate.
    export_plist="$OUT_DIR/export-options.plist"
    cat >"$export_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${APPLE_SIGNING_IDENTITY}</string>
</dict>
</plist>
PLIST
    log "Exporting with Developer ID"
    xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$export_plist" -exportPath "$OUT_DIR" -quiet
    rm -f "$export_plist"
else
    log "Copying ad-hoc signed app out of the archive"
    rm -rf "$OUT_DIR/Arbor.app"
    ditto "$APP_IN_ARCHIVE" "$OUT_DIR/Arbor.app"
fi

log "Built $(app_version "$OUT_DIR/Arbor.app") → $OUT_DIR/Arbor.app"
