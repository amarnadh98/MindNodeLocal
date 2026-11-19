#!/bin/bash
# Shared helpers for the SPEC §13 release pipeline scripts (M9).
# Sourced by the other scripts — do not execute directly.

set -euo pipefail

# Repo root: scripts/release/common.sh → ../../
# Exported for the sourcing scripts (hence the export, not a local).
ARBOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ARBOR_ROOT

# Progress logs go to STDERR: release steps capture stdout
# ($(make-dmg.sh …) etc.) and must receive only the result path.
log() { printf '==> %s\n' "$*" >&2; }

die() { printf 'release-scripts: %s\n' "$*" >&2; exit 1; }

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "missing tool '$1' (try: brew install $1)"
}

# The app's marketing version, read from a built .app bundle.
app_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$1/Contents/Info.plist" >/dev/null 2>&1 \
        || die "cannot read CFBundleShortVersionString from $1"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$1/Contents/Info.plist"
}
