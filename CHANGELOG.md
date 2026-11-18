# Changelog

## Unreleased
### Added
- Product & technical specification (SPEC.md), research notes, ADR-0001.
- M0 foundation: 9 SPM packages under `Packages/` (Swift 6 strict concurrency, macOS 26 minimum).
- `MapCore`: `map.json` format v1 model covering the full SPEC §8.2 schema, deterministic sorted-key JSON coder, `.arbor` package reader/writer, structural validator with all SPEC §8.2 invariants, migration stub — 19 tests.
- `Arbor` app (XcodeGen-generated project per ADR-0002): AppKit `NSDocument` that reads and writes `.arbor` packages (autosave-in-place, sandbox on, exported UTI `com.arbor.map`), standard menus, minimal placeholder window — hosted round-trip tests prove open/save works.
- CI on GitHub Actions (`xcode-27` runners): per-package `swift test`, `xcodebuild test`, swift-format (strict) and SwiftLint.
- `Config.xcconfig` + `AppIdentity` centralize app identity (SPEC §11.9).

### Added (M1, in progress)
- MapRepairer (review follow-up on PR #1): conservative structural repair per SPEC §8.2 — validate, repair what can be repaired, log, and still open. Wired into document loading; repairs mark the document dirty so they persist on the next save.
- MapLayout engine: one-sided mind maps (right/left), balanced with pinned sides and greedy height partitioning, org charts (down/up); tidy non-layered sibling separation via contour bands (ADR-0003); golden frames, no-overlap/order/determinism invariants and a release-gated 5k-node budget test.

### Fixed (review on PR #1)
- Document creation/opening via `NSDocumentController`: `NSDocumentClass` is now declared in `CFBundleDocumentTypes`, and `MapDocument` no longer overrides `NSDocument.init(contentsOf:ofType:)`, so opened documents keep their `fileURL`, `fileType` and modification date. Tests now go through `NSDocumentController` instead of constructing the document directly.
- Saves reuse the package wrapper (`fileWrapper(ofType:)` / `read(from: FileWrapper, ofType:)`) and replace only `map.json`/`meta.json`, so foreign and future entries (`assets/`, `study/reviews.jsonl`, `QuickLook/`) survive saves (SPEC §11.1).
- Loading validates and reports violations but never refuses to open (SPEC §8.2); `formatVersion` mismatches route through `Migrations` instead of a hard throw.
- Date coding uses one shared Sendable `Date.ISO8601FormatStyle` instead of a per-date formatter allocation.
