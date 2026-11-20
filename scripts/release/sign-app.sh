#!/bin/bash
# SPEC §13 step 3: sign the built app.
#
# Modes:
#   --adhoc        (Re)sign the top-level bundle ad-hoc — the SPEC §13
#                  path B default when no Developer ID secrets exist.
#   --verify-only  The export step already signed (Developer ID); just
#                  verify the signature.
#
# usage: sign-app.sh --adhoc|--verify-only <path-to-Arbor.app>
#
# No --deep on purpose: Sparkle's nested framework, XPC services and
# helpers carry their own signatures and must keep them (Sparkle
# sandboxing guide); the archive/export flow has already handled them.

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MODE="${1:---adhoc}"
case "$MODE" in
    --adhoc) MODE="adhoc" ;;
    --verify-only) MODE="verify-only" ;;
    *) die "usage: sign-app.sh --adhoc|--verify-only <path-to-Arbor.app>" ;;
esac
shift || true
APP_PATH="${1:?usage: sign-app.sh --adhoc|--verify-only <path-to-Arbor.app>}"

require_tool codesign
[ -d "$APP_PATH" ] || die "no app bundle at $APP_PATH"

if [ "$MODE" = "adhoc" ]; then
    log "Ad-hoc signing $(basename "$APP_PATH")"
    # No --options runtime: see build-app.sh — library validation
    # would refuse the ad-hoc Sparkle.framework at launch.
    codesign --force --sign - "$APP_PATH"
fi

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -2
codesign -dv "$APP_PATH" 2>&1 | grep --fixed-strings 'Authority=' || \
    codesign -dv "$APP_PATH" 2>&1 | grep --fixed-strings 'Signature='
log "Signature OK"
