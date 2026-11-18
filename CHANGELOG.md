# Changelog

## Unreleased
### Added
- Product & technical specification (SPEC.md), research notes, ADR-0001.
- M0 foundation: 9 SPM packages under `Packages/` (Swift 6 strict concurrency, macOS 26 minimum).
- `MapCore`: `map.json` format v1 model covering the full SPEC §8.2 schema, deterministic sorted-key JSON coder, `.arbor` package reader/writer, structural validator with all SPEC §8.2 invariants, migration stub — 19 tests.
- `Arbor` app (XcodeGen-generated project per ADR-0002): AppKit `NSDocument` that reads and writes `.arbor` packages (autosave-in-place, sandbox on, exported UTI `com.arbor.map`), standard menus, minimal placeholder window — hosted round-trip tests prove open/save works.
- CI on GitHub Actions (`xcode-27` runners): per-package `swift test`, `xcodebuild test`, swift-format (strict) and SwiftLint.
- `Config.xcconfig` + `AppIdentity` centralize app identity (SPEC §11.9).
