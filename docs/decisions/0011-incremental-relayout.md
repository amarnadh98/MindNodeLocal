# ADR-0011: Bit-exact incremental relayout through cached subtree placements

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

The §11.8 keystroke→relayout→paint budget is 8 ms on a 5,000-node map. PR #14's slice 7b measured the path at ~10.8 ms locally (release): ≈8 ms `SceneGeometry.build` (≈4 ms of it `TreeLayout`'s whole-tree pass, the rest measuring 5k titles), ≈0.4 ms spatial-grid rebuild, ≈2 ms layer diff apply. SPEC §11.3 names the fix — `Layout.update(dirty:)` — and SPEC §9 requires the incremental pass to produce the *same* layout as a full one, because every snapshot test, export and Quick Look rendering depends on frames not moving when nothing changed.

## Decision

The incremental pass is defined by one hard rule: **it must be bit-exact with `TreeLayout.layout`, not merely equivalent.** Concretely:

- The one-sided stacking core (`TidyTree.place`) is the *only* implementation; the full layout and the incremental engine both call it, with a `resolve` hook that either recurses (full) or consults the cache (incremental). A reused entry carries exactly the values the recursion would have produced for the same inputs, and every subsequent transform (contour shift/merge, per-level `offsetBy`, centering, mirroring, transposition) is shared code operating on identical floats in the same order. Golden frames pin the full path; a seeded property test (100 random trees × 5 structures × random dirty edits, plus over-marked dirty supersets) pins incremental == full.
- The reusable cache unit is a subtree's `Placed`: frames *relative to the subtree root*, contour bands, extents, and the balanced partition's predicted height — valid under any ancestor position. Entries live in a per-root `LayoutState`, keyed by subtree root id, with the previous tree's parent links kept alongside. Stale links of deleted/moved ids are a feature: they are how a `deleteSubtrees` dirty id, gone from the model, still marks the parent whose child list changed.
- Reuse is validated per node (same measured size, same child ids, same depth-class, same orientation, spacing unchanged), and the caller's dirty set must name every node whose own layout inputs changed; ancestors are closed through the cached parent links. Over-marking is safe, under-marking is a contract violation — `SceneGeometry.dirtyIDs(for:in:)` derives the set from each `MapCommand` kind and returns nil (→ full rebuild) for anything it does not know.
- Nodes are served to the engine **on demand** (`LayoutSourceNode` by id): a keystroke materializes the chain plus its boundary siblings, never the whole tree. `SceneGeometry` keeps per-document caches (measured sizes keyed by id + title + level + variant + width; the per-root layout states), so a title edit re-measures one node through the shared `TextMeasurer`.
- The scene itself (styles, connectors, the multi-root stack) and the `SceneDiffer`/layer apply stay whole-scene passes — they are O(n) but cheap (~1.5 ms combined for 5k, style-resolution is memoized and the layer diff re-rasters nothing unchanged). The expensive whole-scene work — measuring and contour layout — is what goes incremental. The spatial grid, by contrast, updates only the cells of the diff's added/removed/moved nodes, driven by the same `SceneDiff` the layer tree applies (computed once per scene change).

## Measured result

Release, Apple Silicon (M-series): incremental relayout of a 5k-node balanced map after a one-node title edit ≈ **0.7 ms** (full pass ≈ 4.6 ms, unchanged — `TreeLayout.layout` itself is untouched); keystroke→relayout→paint ≈ **2.9–3.3 ms** against the 8 ms budget (was 10.6–11.0). The CanvasKit perf test now enforces the 8 ms budget locally (release, `CI` unset) and prints the numbers on CI.

## Consequences

- Memory: the layout state holds one `Placed` per node — O(n · depth) frames (≈1–2 MB for the 5k stress map). Bounded, and dropped wholesale with the cache on theme change.
- The dirty-set contract is caller-visible: any future `MapCommand` kind must add a `dirtyIDs` case or it silently falls back to a full rebuild (the safe direction). The scene-level property test (random command fuzz comparing `update` against a full rebuild) fails loudly if a mapping under-marks.
- A root's structure change is handled by the full-rebuild path (no command sets structure in M1); a future structure command must dirty the whole root or reset its state.
- SPEC §11.5's background-actor path for > 2k dirty nodes is a documented follow-up: the host currently falls back to a full inline rebuild above 2,000 dirty ids, which stays within the interaction budgets observed so far.
