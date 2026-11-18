# ADR-0003: MapLayout contour-band tidy tree

- **Status:** Accepted
- **Date:** 2026-11-18

## Context
SPEC §9 mandates the non-layered tidy tree algorithm (A. van der Ploeg, 2014) as the layout primitive: linear time, variable node sizes, "struct arrays, no class graph". It also sets hard budgets: full layout of 5,000 nodes under 10 ms, an incremental keystroke relayout under 2 ms.

## Decision
The M1 layout engine (`Packages/MapLayout/TreeLayout.swift`) implements the same *tidy-tree contour semantics* as van der Ploeg, but with an explicit band representation instead of the paper's thread/ancestor pointer structure:

- Each subtree carries `top`/`bottom` contours as arrays of `Band { lo, hi, value }` intervals along the separation axis.
- Consecutive siblings are separated by a two-pointer walk of the accumulated outer contour against the new subtree's inner contour — the same "slide until clear" semantics as the paper, including the non-layered interleave (a later, wider sibling can slide up beside a narrower, deeper one when their x-bands do not overlap).
- Contour merging uses an event sweep over band edges; after each sibling is placed, accumulated bands that can no longer constrain any future sibling (`value ≤ cursor − gap`) are dropped, which is the band-array analogue of the paper's processed-contour trimming.
- Balanced structure (F-LAY-1) partitions root children by pinned side, then greedily by predicted subtree height, preserving order; both sides are laid out with the one-sided engine and centered on the root.
- Org up/down are transposes of the one-sided engine; left is its x-mirror.

## Measured result
Release build, Apple Silicon (MacBook Air M-series): 1,000 nodes ≈ 2 ms, 5,000 nodes ≈ 7 ms for a full balanced layout — inside the SPEC §11.8 budget. The release-conditional assertion in `performanceSmoke` enforces this in CI (`swift test -c release`); debug builds only check a generous bound because unoptimized Swift is ~8× slower.

## Alternatives rejected
- **A literal port of the paper's thread/ancestor machinery.** It is the strictly-linear form, but the pointer-linked contour reconstruction is the most bug-prone part to write blind, and the band form already meets the measured budget with clear, testable invariants (no-overlap, order preservation, determinism, golden frames).
- **Bounding-box stacking (no contours).** Rejected: it loses the tidy interleave that makes mind maps compact, and SPEC §9 explicitly asks for tidy trees.

## Consequences
- The engine's observable behavior is golden-tested per structure; any future swap to a strictly-linear thread-based engine must reproduce those goldens.
- The SPEC §9 *incremental* relayout (dirty-marking, 2 ms keystroke budget) is still open and is planned as its own slice; full-layout speed is not a substitute for it.
- If profiling on the M1-base CI runner ever exceeds the 10 ms budget (slower hardware), the thread-based port becomes the pre-agreed fallback plan.
