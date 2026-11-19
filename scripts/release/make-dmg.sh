#!/bin/bash
# SPEC §13 step 5: build the DMG with create-dmg (an /Applications drop
# link so the "drag to Applications" install works, per Sparkle's own
# distribution advice).
#
# usage: make-dmg.sh <path-to-Arbor.app> <output-dir>
# Writes <output-dir>/Arbor-<version>.dmg and prints its path.

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

APP_PATH="${1:?usage: make-dmg.sh <path-to-Arbor.app> <output-dir>}"
OUT_DIR="${2:?usage: make-dmg.sh <path-to-Arbor.app> <output-dir>}"

require_tool create-dmg
[ -d "$APP_PATH" ] || die "no app bundle at $APP_PATH"
mkdir -p "$OUT_DIR"

VERSION="$(app_version "$APP_PATH")"
DMG_PATH="$OUT_DIR/Arbor-$VERSION.dmg"

# Stage the app alone so the image holds exactly Arbor.app plus the
# Applications alias. ditto preserves the code signature.
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_PATH" "$STAGING_DIR/Arbor.app"

log "Creating Arbor-$VERSION.dmg"
rm -f "$DMG_PATH"

# The fancy window (icon positions, drop link on the right) needs
# Finder automation via AppleScript; that fails in non-GUI sessions
# ("AppleEvent timed out"). create-dmg's own escape hatch is
# --skip-jenkins: the same image, Applications drop link included,
# without the Finder-prettifying step. try_fancy=1 forces the plain
# path for sandboxes and CI.
DMG_ARGS=(
    --volname "Arbor"
    --window-size 560 320
    --icon-size 128
    --icon "Arbor.app" 150 160
    --app-drop-link 410 160
    --no-internet-enable
)
if [ "${CREATE_DMG_SKIP_PRETTIFY:-0}" = "1" ]; then
    # create-dmg logs to stdout: keep stdout for the result path only.
    create-dmg --skip-jenkins "${DMG_ARGS[@]}" "$DMG_PATH" "$STAGING_DIR" >&2
else
    if ! create-dmg "${DMG_ARGS[@]}" "$DMG_PATH" "$STAGING_DIR" >&2; then
        log "Fancy DMG layout failed (no Finder automation?); retrying without it"
        rm -f "$DMG_PATH"
        create-dmg --skip-jenkins "${DMG_ARGS[@]}" "$DMG_PATH" "$STAGING_DIR" >&2
    fi
fi

[ -f "$DMG_PATH" ] || die "create-dmg did not produce $DMG_PATH"
log "Verifying the disk image"
hdiutil verify "$DMG_PATH" >/dev/null
printf '%s\n' "$DMG_PATH"
