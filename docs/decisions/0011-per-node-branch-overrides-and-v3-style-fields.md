# ADR-0011: Per-node branch override semantics and the v3 style fields

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

M2 slice 3 (F-STY-2/F-STY-3) wires the inspector into per-node style
overrides. Three decisions the spec does not pin down:

1. Which connector a node's **branch** overrides (`branchColor`,
   `branchWidth`, `branchTaper`, `branchLineStyle`) act on — the one
   drawn from the node to its parent, or the ones to its children?
2. Where the **rainbow-branches toggle** (F-STY-8, "toggle in the
   theme") persists, given built-in themes are immutable Swift literals
   (ADR-0009).
3. What happens when the inspector edits a document that has **no
   stored theme selection** (fresh documents run the default theme with
   `theme == nil`).

## Decision

### 1. A node's branch overrides act on the connector INTO it

The connector drawn from a node's parent to the node carries that
node's branch overrides. Rationale:

- Every non-root node owns exactly **one** incoming connector; roots
  own none (the inspector disables the Branch section for a selection
  that includes a root). Outgoing ownership would be zero-to-many and
  leave leaf styling dead.
- It matches the palette-index precedent: a level-1 node's stored
  `paletteIndex` already colors the branch from the root to it
  (ADR-0009) — the override reads as the same knob, per node.
- It reads correctly in the inspector: select a leaf, change the branch
  color, and the line above the selection changes.

`SceneBranch` gains `lineStyle` (§7.4 curved/tapered/straight/elbow/
none); `tapered` is derived. `branchWidth` sets the start of a taper or
the constant stroke; `branchTaper` is the fall-off toward the child
end, floored at §7.2's 2 pt leaf width.

### 2. The rainbow toggle persists as a document-level theme override

`ThemePatch` (already the document's stored-overrides slot) gains
`rainbowBranches: Bool?`. `nil` = the theme's own value; the stored
override wins. The new `setThemeOverrides` command (with its wholesale
snapshot sibling `setThemeSelection` for exact inverses) applies it as
one undo step, keeping any other stored overrides (canvas color,
palette) intact.

### 3. Theme commands pin the default theme when a patch arrives on a
   selection-less document

`setThemeOverrides` on `theme == nil` creates a selection for the
default theme (`ThemeSelection`'s default id) carrying the patch, so
the rainbow toggle works on brand-new maps. The inverse restores "no
selection at all" exactly — which is why the theme commands' inverses
route through a full-selection snapshot command (`setThemeSelection`)
instead of the old id-only snapshot: clearing a theme (or undoing a
created selection) could otherwise lose stored overrides.

### Along the way: formatVersion 3

Three optional fields join the schema: `NodeStylePatch.fontWeight`
(F-STY-2 text weight — the field the v2 patch lacked), 
`NodeStylePatch.minWidth` (width min) and `ThemePatch.rainbowBranches`.
All decode as `nil` from v2 files, so `Migrations.v2ToV3` back-fills
nothing — it only stamps the version (fixture-tested like every step).
No writer or reader outside `MapCore` changes.
