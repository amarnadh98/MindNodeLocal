# Release checklist (M9 — SPEC §13, §16)

The pipeline in [`.github/workflows/release.yml`](../.github/workflows/release.yml)
runs on a pushed `v*.*.*` tag and does the SPEC §13 steps: test →
archive → sign (Developer ID if secrets present, else ad-hoc) →
notarize + staple (Developer ID only) → DMG with Applications alias →
Sparkle `generate_appcast` (EdDSA) → GitHub Release → appcast.xml on
GitHub Pages. The reusable logic is in `scripts/release/*.sh`.

Run through this list before tagging, and again as the M9 exit audit.

## 0. One-time setup

- [ ] **EdDSA update keys (Sparkle):** run Sparkle's `generate_keys`
      (from the SPM checkout: `DerivedData/…/SourcePackages/checkouts/Sparkle/bin/generate_keys`,
      or `generate_keys -x sparkle-private.pem` to export the private
      key). Paste the printed `SUPublicEDKey` into `SPARKLE_PUBLIC_ED_KEY`
      in `Config.xcconfig`. The private key lives in your keychain —
      never in the repo.
- [ ] **CI secrets** (Settings ▸ Secrets ▸ Actions), all optional —
      the workflow degrades to ad-hoc without them:
      - `SPARKLE_EDDSA_PRIVATE_KEY` — base64 of the exported
        `sparkle-private.pem` (`base64 -i sparkle-private.pem`).
        Enables appcast generation + Pages publishing.
      - `APPLE_CERTIFICATE_BASE64` / `APPLE_CERTIFICATE_PASSWORD` —
        Developer ID Application `.p12`. Enables Developer ID signing.
      - `APPLE_SIGNING_IDENTITY` — e.g.
        `Developer ID Application: Name (TEAMID)`.
      - `APPLE_ID` / `APPLE_APP_PASSWORD` (app-specific) /
        `APPLE_TEAM_ID` — notarization credentials.
- [ ] **GitHub Pages:** Settings ▸ Pages ▸ *Deploy from a branch*,
      branch `gh-pages`, folder `/(root)`. `SUFeedURL` in the app
      points at `https://amarnadh98.github.io/MindNodeLocal/appcast.xml`,
      which the workflow publishes.
- [ ] **Bundle identity:** `BUNDLE_ID_PREFIX` in `Config.xcconfig` is
      still the `com.example` placeholder — set the real prefix before
      a public release (SPEC §11.9).

## 1. Every release

- [ ] **Version:** bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
      in `Config.xcconfig` (Sparkle orders versions by
      `CFBundleVersion`, so it must increase).
- [ ] **CHANGELOG.md:** fold the release section into `## <version>`.
- [ ] **Tag:** `git tag -a vX.Y.Z && git push origin vX.Y.Z`.
- [ ] **Watch the workflow:** all steps green; the DMG lands on the
      GitHub Release and `appcast.xml` on Pages.
- [ ] **Smoke the update path:** launch the *previous* version and run
      Arbor ▸ *Check for Updates…* — it should find, download and
      install the new DMG (needs the real `SUPublicEDKey` from step 0).

## 2. M9 exit criteria (SPEC §16)

- [ ] **Fresh-Mac install test by a friend succeeds:** on a Mac that
      has never built Arbor, download the release DMG, drag to
      /Applications, open, create and save a map (SPEC §16 M9:
      "Fresh-Mac install test by a friend succeeds"). Record which
      signing path the build used and whether the *Open Anyway* step
      (SPEC §13 B) was needed.
- [ ] **Zero P0 bugs open.**
- [ ] **Accessibility audit:** run
      [`docs/accessibility/voiceover-script.md`](accessibility/voiceover-script.md)
      — VoiceOver can create, navigate, edit and fold a 20-node map
      (§14, §11.6). Extra pass for the release: Accessibility
      Inspector audit on the app menu's updater items (labels:
      "Check for Updates…", state of "Automatically Check for
      Updates"), Reduce Motion and Increase Contrast across the main
      flows.
- [ ] **Performance pass:** the §11.8 budgets on a 5,000-node map —
      open-to-first-paint < 300 ms, keystroke→relayout→paint < 8 ms,
      pan/zoom at 120 fps with no drops. The CI perf job prints the
      numbers on shared runners; enforce on local M1-class hardware.
- [ ] **README ship check:** screenshots from
      [`docs/design/screenshots.md`](design/screenshots.md) captured
      and embedded; install instructions match the signed path that
      the release actually used.

## 3. Local ad-hoc DMG (no tag needed)

```sh
scripts/release/build-dmg-local.sh   # → dist/local/Arbor-<version>.dmg
```

The script mounts the DMG before declaring victory: `Arbor.app` and
the `/Applications` drop link must be present. Recipients follow the
README's *Open Anyway* instructions.
