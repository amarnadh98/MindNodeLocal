#!/bin/bash
# SPEC §13 step 8: publish appcast.xml to GitHub Pages.
#
# The site serves the gh-pages branch (Settings ▸ Pages ▸ "Deploy from
# a branch: gh-pages / (root)"), which is where SUFeedURL points:
# https://<owner>.github.io/<repo>/appcast.xml
#
# usage: publish-appcast.sh <appcast.xml> [<extra-file>...]
# env:   GH_TOKEN           a token with repo (contents) write access
#       GITHUB_REPOSITORY   owner/name — set by GitHub Actions

# shellcheck source=scripts/release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ $# -ge 1 ] || die "usage: publish-appcast.sh <appcast.xml> [<extra-file>...]"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY (owner/name) is required}"

require_tool git
for f in "$@"; do
    [ -f "$f" ] || die "no such file: $f"
done

REPO_URL="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
SITE_DIR="$(mktemp -d)"
trap 'rm -rf "$SITE_DIR"' EXIT

if git ls-remote --exit-code --heads "$REPO_URL" gh-pages >/dev/null 2>&1; then
    log "Cloning gh-pages"
    git clone --quiet --branch gh-pages "$REPO_URL" "$SITE_DIR"
else
    log "Creating gh-pages (orphan branch)"
    git clone --quiet "$REPO_URL" "$SITE_DIR"
    git -C "$SITE_DIR" checkout --quiet --orphan gh-pages
    git -C "$SITE_DIR" rm -r --cached . >/dev/null 2>&1 || true
    find "$SITE_DIR" -mindepth 1 -not -path '*/.git/*' -not -name .git -delete
fi

for f in "$@"; do
    cp "$f" "$SITE_DIR/"
done

git -C "$SITE_DIR" config user.name "Arbor release workflow"
git -C "$SITE_DIR" config user.email "actions@github.com"
if git -C "$SITE_DIR" diff --quiet && [ -z "$(git -C "$SITE_DIR" status --porcelain)" ]; then
    log "gh-pages is already up to date; nothing to publish"
    exit 0
fi
git -C "$SITE_DIR" add -A
git -C "$SITE_DIR" commit --quiet -m "Publish appcast for $(basename "$1")"
git -C "$SITE_DIR" push --quiet "$REPO_URL" gh-pages
log "Published appcast.xml to GitHub Pages"
