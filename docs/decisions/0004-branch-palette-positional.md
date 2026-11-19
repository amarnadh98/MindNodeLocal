# ADR-0004: Branch palette colors are positional

- **Status:** Superseded by ADR-0009 (persistent index implemented, 2026-11-19)
- **Date:** 2026-11-19

## Context
F-STY-8 (SPEC §5.8) says level-1 branches take palette colors and descendants inherit them, and lists a "Recolor Branches" action. Two designs fit:

1. **Positional** (current): the palette index is the level-1 child's position among its siblings.
2. **Persistent**: the palette index is chosen on creation and stored on the level-1 node; only the explicit "Recolor Branches" action reshuffles.

The PR #5 review flagged the choice as a decision to settle before the editing slice lands reorder/insert/delete, since positional coloring recolors whole branches when level-1 siblings move.

## Decision
Keep **positional** coloring for now (M1's canvas slice), and switch to **persistent** before the editing slice lands reorder/insert/delete of level-1 siblings.

Rationale:
- Positional keeps `map.json` unchanged (no new stored field) and guarantees stable, non-repeating colors on screen at all times — good for the read-only canvas milestone.
- The switch is small and localized when the editing slice needs it: add an optional `paletteIndex` to the level-1 `Node`'s style patch (or a dedicated field, which would bump `formatVersion`), default it to the current position on load (a non-destructive migration in the repairer), and have `SceneGeometry` prefer the stored index. "Recolor Branches" then rotates indices.

## Consequences
- Until the persistent field lands, reordering level-1 siblings recolors the branches after the moved one. The editing slice (F-EDT-5, F-EDT-6) must not ship reorder of level-1 siblings without resolving this.
- Inserting a new first level-1 branch shifts every subsequent branch's color — visible, but harmless in the current read-only canvas.
- This ADR is the tracking record; the follow-up work item is "persistent palette index with `Recolor Branches`".

## Resolution (2026-11-19)
ADR-0009 implemented the persistent index (`Node.paletteIndex`, formatVersion 2,
migration v1→v2 back-filling today's positional values, `recolorBranches`
command) before the editing slice shipped reorder, so this decision's window
closed as planned.
