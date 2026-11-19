#!/bin/bash
# Owner-facing local release build (SPEC §13 path B): an ad-hoc signed
# DMG you can hand to friends, without any Apple Developer Program
# membership. After building it mounts the image to prove it is
# installable: Arbor.app present, Applications alias present.
#
# usage: build-dmg-local.sh [output-dir]   (default: dist/local)
#
# Recipients will need to bypass Gatekeeper the first time (see
# README.md "Ad-hoc builds"), unless the DMG is notarized instead —
# that path runs in the release workflow with Developer ID secrets.

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUT_DIR="${1:-dist/local}"
mkdir -p "$OUT_DIR"

"$(dirname "${BASH_SOURCE[0]}")/build-app.sh" --adhoc "$OUT_DIR"
"$(dirname "${BASH_SOURCE[0]}")/sign-app.sh" --adhoc "$OUT_DIR/Arbor.app"
DMG_PATH="$("$(dirname "${BASH_SOURCE[0]}")/make-dmg.sh" "$OUT_DIR/Arbor.app" "$OUT_DIR")"

# Prove the DMG mounts and carries the app plus the drop link.
log "Mount-checking $(basename "$DMG_PATH")"
# A short mount point: a long $TMPDIR makes hdiutil fail with
# "File name too long".
MOUNT_POINT="$(mktemp -d /tmp/arbor-dmg.XXXXXX)"
trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT
# Retried: hdiutil attach can transiently fail right after create-dmg
# has cleaned up its own scratch images.
mounted=0
for attempt in 1 2 3 4 5; do
    if hdiutil attach -nobrowse -readonly "$DMG_PATH" \
        -mountpoint "$MOUNT_POINT" >/dev/null; then
        mounted=1
        break
    fi
    log "mount attempt $attempt failed; retrying"
    sleep 3
done
[ "$mounted" = "1" ] || die "the DMG does not mount"
[ -d "$MOUNT_POINT/Arbor.app" ] || die "mounted DMG has no Arbor.app"
[ -e "$MOUNT_POINT/Applications" ] || die "mounted DMG has no Applications drop link"
hdiutil detach "$MOUNT_POINT" >/dev/null
log "DMG OK: $DMG_PATH"
printf '%s\n' "$DMG_PATH"
