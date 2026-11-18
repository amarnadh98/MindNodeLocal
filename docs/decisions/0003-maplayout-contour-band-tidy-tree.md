# ADR-0003: MapLayout contour-band tidy tree

- **Status:** Accepted
- **Date:** 2026-11-18

## Context
SPEC §9 mandates the non-layered tidy tree algorithm (A. van der Ploeg, 2014) as the layout primitive: linear time, variable node sizes, "struct arrays, no class graph". It also sets hard budgets: full layout of 5,000 nodes under 10 ms, an incremental keystroke relayout under 2 ms.

## Decision
The M1 layout engine (`Packages/MapLayout/TreeLayout.swift`) implements tidy-tree *contour separation* with an explicit band representation instead of the paper's thread/ancestor pointer structure:

- Each subtree carries `top`/`bottom` contours as arrays of `Band { lo, hi, value }` intervals along the separation axis.
- Consecutive siblings are separated by a two-pointer walk of the accumulated outer contour against the new subtree's inner contour. Contour merging is a linear two-pointer sweep over the two sorted, internally non-overlapping band lists — an invariant the merge maintains for its outputs — with no sorting and no intermediate allocations.
- Balanced structure (F-LAY-1) partitions root children by pinned side, then greedily by predicted subtree height, preserving order; both sides are laid out with the one-sided engine and centered on the root.
- Org up/down are transposes of the one-sided engine; left is its x-mirror.

## How this differs from van der Ploeg (deliberate product choice)
Each sibling's candidate position starts at `cursor` — the previous subtree's bottom extent — and only moves *down* (`dy ≥ 0`). A later sibling's own node can therefore never slide up beside an earlier sibling's deep descendants; only the later sibling's *upward-extending descendants* (a subtree centered on tall children reaches back above its parent) interleave into the earlier subtree's open columns. The paper's algorithm is slightly more compact in these cases; we accept the extra whitespace because siblings staying in reading order below each other arguably reads better for mind maps.

One consequence of the band form: a trimming optimization that drops accumulated bands below `cursor − gap` is **unsound** with centered subtrees (their negative `minY` reaches back into dropped columns) and produced overlaps in randomized stress tests; it was removed and replaced by a permanent seeded stress test (300 trees × all structures) so the class of bug cannot return.

## Measured result
Release build, Apple Silicon (MacBook Air M-series): 1,000 nodes ≈ 1 ms, 5,000 nodes ≈ 4.6 ms for a full balanced layout (steady state, best of 3); the GitHub `xcode-27` shared runner measures ≈ 1.8× slower, still inside the SPEC §11.8 10 ms budget. CI enforces it in the `perf` job via `swift test -c release` (debug builds only check a generous bound because unoptimized Swift is ~8× slower).

## Alternatives rejected
- **A literal port of the paper's thread/ancestor machinery.** It is the strictly-linear form, but the pointer-linked contour reconstruction is the most bug-prone part to write blind, and the band form already meets the measured budget with clear, testable invariants (no-overlap stress + goldens).
- **Bounding-box stacking (no contours).** Rejected: it loses the descendant interleave that keeps mind maps compact, and SPEC §9 explicitly asks for tidy trees.

## Consequences
- The engine's observable behavior is golden-tested per structure; any future swap to a strictly-linear thread-based engine must reproduce those goldens.
- Known follow-ups, tracked for later slices (from the PR #2 review):
  1. `place()` is recursive: a single chain of ~150–200 nodes overflows the stack in debug (release: ~500–1,000). An imported deeply nested outline could crash on open. Fix: iterative post-order traversal.
  2. Cost grows with the square of depth (every level re-offsets all descendant frames). A 501-node chain costs about as much as the 5,000-node balanced tree. Fix: relative offsets per node resolved in one final pass (the standard "mod accumulation"), which also makes layout strictly linear.
  3. The SPEC §9 *incremental* relayout (dirty-marking, 2 ms keystroke budget) remains open as its own slice.
- If profiling on the M1-base CI runner ever exceeds the 10 ms budget (slower hardware), the thread-based port becomes the pre-agreed fallback plan.
