# ADR-0002: XcodeGen generates the Xcode project

- **Status:** Accepted
- **Date:** 2026-11-18

## Context
The repo needs an Xcode project with an app target, four extension targets (Quick Look thumbnail/preview, Spotlight importer, Share) and a helper executable, wired to 9 local SPM packages (SPEC §11.2). A hand-written `.xcodeproj/pbxproj` is UUID-soup: merge-hostile, easy to corrupt, and slow for coding agents and CI to review or reproduce. Project membership needs to be inspectable in diffs when targets, entitlements or document types change.

## Decision
- `project.yml` (XcodeGen) is the source of truth for targets, settings, entitlements and document types, and is checked in.
- The generated `Arbor.xcodeproj` is **also committed**. Anyone who clones the repo gets a project that opens and builds in Xcode without installing extra tools, and the owner can always double-click the project. XcodeGen's output is deterministic, so pbxproj diffs stay reviewable.
- After any `project.yml` edit, the contributor runs `xcodegen generate` (once, via `brew install xcodegen`) and commits the regenerated project together with the yml change. This keeps the two in sync; a stale pbxproj is a bug.
- CI regenerates the project before `xcodebuild` anyway (`xcodegen generate` then `xcodebuild -scheme Arbor test`), which proves generation keeps working on a clean machine.
- XcodeGen is a **dev-time tool**, not a runtime dependency. SPEC §11.1's budget of at most 8 runtime dependencies applies to SPM packages linked into the app; a Homebrew-installed project generator does not count against it. (It is still recorded here as a decision the spec doesn't cover.)
- Shared build settings (app name, bundle ID, UTIs, versions, deployment target) live in `Config.xcconfig` (SPEC §11.9) and are consumed by `project.yml`, so identity changes stay a one-file edit.

## Alternatives rejected
- **Hand-written `.xcodeproj`.** Merge conflicts in pbxproj are effectively unresolvable for humans and agents; the file is not meant to be edited by hand.
- **Check in only `project.yml`, generate the project in CI.** Friendlier diffs, but a fresh clone has no project to open — bad for Xcode GUI users and for the owner's daily use. We accept a larger, mechanical diff file instead.
- **Tuist.** More powerful, but brings a manifest language, caching and plugin machinery this project doesn't need; XcodeGen is a single small binary.
- **SPM-only (no Xcode project).** SwiftPM alone cannot express an app bundle with entitlements, sandboxing, extensions and document-type registrations.

## Consequences
- Contributors and agents run `xcodegen generate` after editing `project.yml`, and must never hand-edit `Arbor.xcodeproj`.
- If a pbxproj conflict ever appears, resolve by taking either side and regenerating.
- CI takes a few extra seconds to install XcodeGen and regenerate; it also catches a forgotten regeneration.
