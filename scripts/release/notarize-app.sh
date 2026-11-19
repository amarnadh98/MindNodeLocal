#!/bin/bash
# SPEC §13 step 4: notarize and staple — Developer ID builds only.
#
# Credentials (App Store Connect Apple ID):
#   APPLE_ID            the developer Apple ID
#   APPLE_APP_PASSWORD  an app-specific password (appleid.apple.com)
#   APPLE_TEAM_ID       the membership team id
#
# usage: notarize-app.sh <path-to-Arbor.app>

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

APP_PATH="${1:?usage: notarize-app.sh <path-to-Arbor.app>}"
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD (app-specific) is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

[ -d "$APP_PATH" ] || die "no app bundle at $APP_PATH"

log "Submitting to Apple's notary service (this waits for approval)"
xcrun notarytool submit "$APP_PATH" \
    --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait

log "Stapling the notarization ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

log "Gatekeeper assessment"
spctl --assess --type execute -vv "$APP_PATH"
log "Notarized and stapled"
