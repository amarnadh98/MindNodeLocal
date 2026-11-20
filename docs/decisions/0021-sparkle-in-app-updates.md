# ADR-0021: Sparkle 2 for in-app updates, checks strictly opt-in

- **Status:** Accepted
- **Date:** 2026-11-19
- **Satisfies:** SPEC §13 (Distribution: "In-app updates: Sparkle 2, via Check for Updates… in the app menu"), §12 (Privacy), §11.1 (dependencies ≤ 8)

## Context

M9 (SPEC §16) ships the distribution pipeline: a tagged release builds a DMG and publishes a Sparkle appcast to GitHub Pages, and the app needs an in-app update path so friends running the ad-hoc build (SPEC §13 path B) can pull the next version without re-downloading by hand.

SPEC §11.1 caps runtime dependencies at **8** and requires an ADR for each. Before this decision Arbor had **zero** external runtime dependencies (every `Packages/*` target depends only on sibling packages), so Sparkle is dependency **1 of 8** — well inside the budget, and it was already the named choice in SPEC §11.1's SPM list and §13.

SPEC §12 is stricter than Sparkle's defaults:

> Network is used only for: 1. Sparkle update checks (can be disabled). …

Sparkle 2 ships with `automaticallyChecksForUpdates` **on** by default and would check the feed ~24 h after first launch — a network call the user never asked for. That violates §12 unless the user opts in.

## Decision

1. **Add Sparkle 2** (SPM, `https://github.com/sparkle-project/Sparkle`, `from: "2.10.1"`) linked into the `Arbor` app target only. No package (`Packages/*`) links it; the core stays dependency-free.
2. **Feed:** `SUFeedURL` = `https://amarnadh98.github.io/MindNodeLocal/appcast.xml` (the GitHub Pages site the release workflow publishes to, SPEC §13 step 8).
3. **EdDSA verification:** `SUPublicEDKey` is read from the `SPARKLE_PUBLIC_ED_KEY` build setting (`Config.xcconfig`). It is **intentionally a placeholder (empty) until the EdDSA key pair is generated**: run `Sparkle/bin/generate_keys` (see `docs/release-checklist.md`), paste the printed public key into `Config.xcconfig`, and keep the private key in the owner's keychain / the `SPARKLE_EDDSA_PRIVATE_KEY` CI secret — never in the repo. An empty key means Sparkle logs a warning and skips archive-signature verification; that is acceptable for local builds, but a shipped DMG must have it set (checklist step).
4. **Privacy-first checks (SPEC §12):**
   - `AppUpdater.registerPrivacyDefaults()` runs at launch, before anything can construct the updater, registering `SUEnableAutomaticChecksKey = false`. The registration domain only applies when the key is absent, so a user who opts in keeps their choice across relaunches.
   - The `SPUStandardUpdaterController` is created **lazily** — only when the user clicks *Check for Updates…* or flips *Automatically Check for Updates*. Building the menu never loads Sparkle, so a plain launch performs **zero** update-related network calls.
   - `SUEnableSystemProfiling = false` in the Info.plist: Sparkle never sends a system profile (§12 bans telemetry).
5. **Sandbox stays on (SPEC §11.1):** per Sparkle's sandboxing guide, the app gains the `com.apple.security.network.client` entitlement (already planned in §11.1 for "AI/updates only"), `SUEnableInstallerLauncherService = true`, and the documented `mach-lookup` temporary-exception entitlements (`…-spks`, `…-spki`) so Sparkle's bundled Installer XPC service can run. The Downloader XPC service is **not** enabled: with the network-client entitlement it is unnecessary.
6. **Menu wiring lives outside `AppDelegate`** (`AppDelegate+Updater.swift` + `AppUpdater.swift`): *Check for Updates…* sits in the app menu (after About), with *Automatically Check for Updates* below it as a stateful toggle. Both actions ride the responder chain; keeping the wiring in an extension also keeps `AppDelegate` under swiftlint's `type_body_length`.

## Consequences

- The app makes no network request at first launch, satisfying §12's "can be disabled" in the strongest sense: it is disabled until the user enables it.
- Update archives are EdDSA-signed by the release workflow (Sparkle `generate_appcast` with the private key from the `SPARKLE_EDDSA_PRIVATE_KEY` secret); once the real `SUPublicEDKey` is committed, ad-hoc or tampered DMGs are rejected by the client.
- Sparkle's helpers (`Sparkle.framework`, its XPC services) are embedded via SPM and signed by Xcode's embed-and-sign / archive-export flow; the release scripts re-sign ad-hoc on the free path (SPEC §13 B).
- Hardened Runtime + library validation: an ad-hoc signature has no Team ID, so library validation refuses the embedded Sparkle.framework and an ad-hoc build with the runtime on aborts at launch ("Library missing"). The ad-hoc release path (`build-app.sh --adhoc`, `sign-app.sh --adhoc`) therefore builds and signs without the Hardened Runtime; it can't be notarized anyway. Developer ID export keeps the runtime and re-signs the nested services, which is the supported distribution path.
- Dependency budget after this ADR: 1 of 8 (`swift-markdown`, `SwiftMath`, `ZIPFoundation`, `GRDB`, `KeyboardShortcuts` from SPEC §11.1 remain future slots).
