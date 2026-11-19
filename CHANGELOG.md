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
- Spatial navigation & view state (slice 5b): `SpatialNavigator` — pure functions over a `CanvasScene` implementing F-CAN-4's arrow-key semantics (→/← dive into the subtree on the pressed side and climb back, mirrored on the left side of a balanced map; org charts mirror vertically with ↓/↑ and sibling ←/→ steps; ↑/↓ prefer the nearest sibling then fall back to nearest-by-geometry with an angular cone penalty), plus `extendSelection` (⇧-arrows), `nextRoot`/`previousRoot` (⌃⌥N/⌃⌥P) and `scrollIntoView` (F-CAN-7's minimal camera move with a 40 pt margin, leaving already-visible frames untouched); folded children are never targets. `CanvasViewState` + `ViewStateStore` — per-document zoom, camera, selection and active view persisted as a JSON sidecar under Application Support keyed by `docID` (ADR-0005: panning never dirties the document; corrupt/missing files read as nil; selection sanitized against the scene on restore). Wiring into `CanvasView`/`MapDocument` comes with the next slice.
- Editing store (slice 5a): `MapStore` — the single editing gateway per SPEC §11.3 — owns the model and an injected `UndoManager`, computes each `MapCommand`'s exact inverse before applying all-or-nothing, registers undo/redo so undo∘redo is exact, coalesces consecutive `editText`s on one node via `continuesEdit`, stamps authorship (`modified`/`modifiedBy`) on touched nodes, and reports every change (perform/undo/redo) to the host. `MapDocument` now routes all mutations and saving through the store (forward performs mark the document dirty; undo/redo ride NSDocument's undo-manager integration). Editing keys and menus per SPEC §6.1: ⇥ child, ⏎/⌥⏎ sibling below/above, ⌥⇥ parent, ⇧⏎ root, ⌫/⌦ and ⌥⌫ deletes, ⌘D duplicate, ⇧⌘D detach, ⌘↑/⌘↓ reorder, ⌘←/⌘→ side-aware promote/demote, ⌥. fold, ⌘A/⌥⌘A/⌘R select, ⎋ deselect — as first-responder actions that rebuild the scene (camera preserved) and repair the selection (new node after adds, parent/nearest sibling after deletes). 21 store tests, including a seeded 200-command fuzz that fully undoes back to the original model.
- Canvas (slice 4a): `SceneGeometry` turns a `MapModel` into a renderable `CanvasScene` (measured nodes via the shared `TextMeasurer`, laid out by `TreeLayout` per root with multi-root stacking, Paper-theme style resolution by level and branch index, §7.4 tapered branch connectors, folded subtrees skipped); `SpatialGrid` — the 512 pt uniform-grid index behind hit-testing and culling; `SceneRenderer` — one drawing path (branches, nodes, selection rings) for canvas and future export/Quick Look; `CanvasView` — a flipped, layer-backed NSView with camera pan/pinch-zoom (⌘+/−/⌘0/⌘9, zoom-to-fit), click and ⌘-click selection, rubber-band multi-select. The document window now shows the actual map, fitted to the viewport.
- MapRender (slice 3): `TextMeasurer` — the single CoreText-based source of truth for node text sizes (SPEC §9), with run attributes (bold/italic/code/underline/color), 1.25 line height, auto-width-then-wrap measurement and a size cache; `NodeRenderer` — the one CGContext renderer for all shapes (rounded rect, pill, rectangle, circle, square, diamond, hexagon, octagon, cloud, underline, none) with fills, borders, shadows and optically centered titles; `BranchPath` — curved/tapered/straight/elbow connectors per SPEC §7.4 (tapered as a 16-sample offset polygon with round caps); Paper theme resolution — light/dark level styles, palette-indexed branch colors, tapered widths.
- MapCore command layer (SPEC §11.1/§11.3): `MapCommand` with `apply`/`inverse` for the M1 editing operations — add child/sibling/parent/root, delete subtree / delete-with-promotion, edit text, move/reorder/promote/demote/detach, duplicate, insert-subtrees, plus `group` for compound steps and `continuesEdit` for undo coalescing. Property tests: apply∘inverse identity, undo∘redo identity, fuzzed sequences fully restored, invariants preserved after every apply.
- MapRepairer (review follow-up on PR #1): conservative structural repair per SPEC §8.2 — validate, repair what can be repaired, log, and still open. Wired into document loading; repairs mark the document dirty so they persist on the next save.
- MapLayout engine: one-sided mind maps (right/left), balanced with pinned sides and greedy height partitioning, org charts (down/up); tidy non-layered sibling separation via contour bands (ADR-0003); golden frames, no-overlap/order/determinism invariants and a release-gated 5k-node budget test.

### Fixed (review on PR #3)
- Multi-id delete undo: anchors are deduplicated (an id listed twice restored twice) and sorted by `(parent, slot)` so selection order no longer corrupts sibling order; ids covered by an ancestor in the same selection restore inside the ancestor's snapshot instead of double-inserting.
- `group` applies are all-or-nothing (working copy, assign on success), so a failed compound command can't leave a half-applied, un-undoable change.
- Deletes and cross-parent moves now purge connections, boundaries and stale summaries that reference removed or moved nodes, and their inverses restore the pre-command lists via new `setConnections`/`setBoundaries`/`setSummaries` commands — no more silent data loss on save+reopen.
- Leaf-creating commands normalize their payload (`children` cleared, stale `side` dropped on `addRoot`); `duplicate` stamps fresh timestamps and clears inherited FSRS review state.
- Tests are fully seeded (reproducible from the failure's seed) and now generate connections, boundaries, summaries and multi-id deletes; the invariants property test asserts the full validator with no error-kind filter.

### Fixed (review on PR #2)
- Layout: removed the unsound contour trim — a later sibling whose subtree is centered on tall descendants has a negative `minY` and reaches back into trimmed columns, overlapping nodes. Added a permanent seeded stress test (300 random trees × all structures) that would have caught it.
- Repair: unreachable cycles are now broken (lowest-ID member promoted to a root, then resync) instead of being left unreachable; repair order is deterministic (creation time, then ID) so the same broken file always repairs identically; duplicate `children` entries are detected, reported, and de-duplicated.
- CI: new `perf` job runs MapLayout tests in release, enforcing the SPEC §11.8 10 ms budget.

### Fixed (re-review on PR #5)
- Opened documents showed an empty canvas: the scene build had moved to `windowDidLoad`, which never fires for programmatically-constructed window controllers. The first build now runs in `showWindow(_:)` (document wired, window at its real size), with the initial zoom-to-fit.
- Root cause found along the way: assigning `windowController.document` before `addWindowController(_:)` makes AppKit's insertion a no-op, leaving the document with zero window controllers — the assignment is removed (with a comment) and `addWindowController` owns it.
- New hosted app test opens a `.arbor` package, shows the window, and asserts the canvas scene, the initial fit, and >500 drawn pixels.
- View menu: hidden alternate Zoom In item with the `=` key equivalent, so ⌘= works even when a text field has focus.

### Fixed (review on PR #5)
- Canvas actually renders: dropped the custom `CALayer` assignment (a layer-hosting view's delegate-less layer never draws); the view now draws into its standard backing layer.
- Multi-root stacking by the tree's full extent — balanced subtrees extend above the root, so stacking by the root's own `minY` overlapped trees (regression-tested with a wide-root scenario).
- Natural-scroll pan direction fixed (camera origin subtracts the delta, like `NSClipView`); mouse-wheel deltas scaled by a line height.
- `.auto` appearance follows the view's effective appearance and re-renders on system appearance change; the document's explicit light/dark override still wins.
- Zoom: F-CAN-2 step list (25–400%) with `=` matched as ⌘+, ⌘* fit and ⌥⌘0 zoom-to-selection added, all exposed as View menu items (first-responder actions), so they work before the canvas is clicked.
- Renderer culls nodes and branches to the visible rect (draw cost now follows the viewport); the measurer is injectable.
- Branch taper is continuous root-to-leaf (w(level) → w(level+1)) instead of restarting at each node.
- ADR-0004 records the positional branch-palette decision and the plan to make the index persistent before reorder/insert land.

### Fixed (review on PR #1)
- Document creation/opening via `NSDocumentController`: `NSDocumentClass` is now declared in `CFBundleDocumentTypes`, and `MapDocument` no longer overrides `NSDocument.init(contentsOf:ofType:)`, so opened documents keep their `fileURL`, `fileType` and modification date. Tests now go through `NSDocumentController` instead of constructing the document directly.
- Saves reuse the package wrapper (`fileWrapper(ofType:)` / `read(from: FileWrapper, ofType:)`) and replace only `map.json`/`meta.json`, so foreign and future entries (`assets/`, `study/reviews.jsonl`, `QuickLook/`) survive saves (SPEC §11.1).
- Loading validates and reports violations but never refuses to open (SPEC §8.2); `formatVersion` mismatches route through `Migrations` instead of a hard throw.
- Date coding uses one shared Sendable `Date.ISO8601FormatStyle` instead of a per-date formatter allocation.
