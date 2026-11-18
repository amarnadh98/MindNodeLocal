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
- MapCore command layer (SPEC §11.1/§11.3): `MapCommand` with `apply`/`inverse` for the M1 editing operations — add child/sibling/parent/root, delete subtree / delete-with-promotion, edit text, move/reorder/promote/demote/detach, duplicate, insert-subtrees, plus `group` for compound steps and `continuesEdit` for undo coalescing. Property tests: apply∘inverse identity, undo∘redo identity, fuzzed sequences fully restored, invariants preserved after every apply.
- MapRepairer (review follow-up on PR #1): conservative structural repair per SPEC §8.2 — validate, repair what can be repaired, log, and still open. Wired into document loading; repairs mark the document dirty so they persist on the next save.
- MapLayout engine: one-sided mind maps (right/left), balanced with pinned sides and greedy height partitioning, org charts (down/up); tidy non-layered sibling separation via contour bands (ADR-0003); golden frames, no-overlap/order/determinism invariants and a release-gated 5k-node budget test.

### Fixed (review on PR #2)
- Layout: removed the unsound contour trim — a later sibling whose subtree is centered on tall descendants has a negative `minY` and reaches back into trimmed columns, overlapping nodes. Added a permanent seeded stress test (300 random trees × all structures) that would have caught it.
- Repair: unreachable cycles are now broken (lowest-ID member promoted to a root, then resync) instead of being left unreachable; repair order is deterministic (creation time, then ID) so the same broken file always repairs identically; duplicate `children` entries are detected, reported, and de-duplicated.
- CI: new `perf` job runs MapLayout tests in release, enforcing the SPEC §11.8 10 ms budget.

### Fixed (review on PR #1)
- Document creation/opening via `NSDocumentController`: `NSDocumentClass` is now declared in `CFBundleDocumentTypes`, and `MapDocument` no longer overrides `NSDocument.init(contentsOf:ofType:)`, so opened documents keep their `fileURL`, `fileType` and modification date. Tests now go through `NSDocumentController` instead of constructing the document directly.
- Saves reuse the package wrapper (`fileWrapper(ofType:)` / `read(from: FileWrapper, ofType:)`) and replace only `map.json`/`meta.json`, so foreign and future entries (`assets/`, `study/reviews.jsonl`, `QuickLook/`) survive saves (SPEC §11.1).
- Loading validates and reports violations but never refuses to open (SPEC §8.2); `formatVersion` mismatches route through `Migrations` instead of a hard throw.
- Date coding uses one shared Sendable `Date.ISO8601FormatStyle` instead of a per-date formatter allocation.
