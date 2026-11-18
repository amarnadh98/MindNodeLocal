# AGENTS.md: guide for coding agents

Read **[SPEC.md](SPEC.md)** first. It is the source of truth. Build milestone by milestone (SPEC §16), and don't start a milestone until the previous one's exit criteria pass.

## Ground rules
- **Stack:** native macOS, Swift 6.4 in Swift 6 language mode with strict concurrency, Xcode 27, minimum **macOS 26**.
  - The app shell and canvas are AppKit, using Core Animation layers.
  - SwiftUI is allowed only where it is hosted, such as the inspector, settings, library and study UI.
  - **Do not** build the canvas with SwiftUI `Canvas`, one SwiftUI view per node, or Metal (SPEC §11).
- **Packages:** follow the module layout in SPEC §11.2.
  - `MapCore`, `MapLayout`, `MapStudy` and `MapIO` must not import AppKit, and must pass `swift test` from the command line.
- **Mutations:** every change to a map goes through a `MapCommand` with an inverse, registered with the document's `UndoManager`. Never mutate the model directly from views.
- **Rendering:** a single `TextMeasurer` and `NodeRenderer` is shared by the canvas, export and Quick Look.
- **File format:** the `.arbor` package (SPEC §8). Bump `formatVersion` and add a migration with fixtures whenever the schema changes.
- **Dependencies:** at most 8 runtime dependencies (SPEC §11.1). Write an ADR in `docs/decisions/` before adding any.
- **Don't copy MindNode:** no copying of MindNode assets, theme files, stickers, names or text. Behaviour and file-format interop are fine.
- **Privacy:** no telemetry, and no network calls except those SPEC §12 allows.
- **Definition of Done:** SPEC §14.1. That includes tests, undo, menus and keyboard, light and dark mode, VoiceOver, and performance budgets.

## Commands
```bash
swift test --package-path Packages/MapCore
xcodegen generate  # once after cloning, and after every project.yml edit
xcodebuild -scheme Arbor -destination 'platform=macOS' test
swift format lint --strict -r Packages App
```

## Process
- Work on branches named `feat/m<N>-<topic>` and use Conventional Commits. Open one PR per milestone slice, with the §14.1 checklist.
- Record any decision the spec doesn't cover as an ADR (`docs/decisions/NNNN-title.md`).
- Update `CHANGELOG.md` with each PR.
