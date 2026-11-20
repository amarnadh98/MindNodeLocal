# ADR-0028: Per-node branch override semantics, the v4 style fields, and the inspector's app-level rows

- **Status:** Accepted
- **Date:** 2026-11-20

## Context

The M2 inspector slice (F-STY-2/3/6/8, F-LAY-4/12/14, SPEC §6.3) wires
per-node style overrides and the Layout/Theme/Canvas panes. Decisions
the spec does not pin down:

1. Which connector a node's **branch** overrides
   (`branchColor`, `branchWidth`, `branchTaper`, `branchLineStyle`) act
   on — the one drawn from the node to its parent, or the ones to its
   children?
2. Where the **rainbow-branches toggle** (F-STY-8, "toggle in the
   theme") persists, given built-in themes are immutable Swift literals
   (ADR-0009).
3. What "logic chart" geometry (F-LAY-4) is, given the tidy tree lets
   cousin subtrees interleave.
4. Where **spacing** (F-LAY-12: "presets, plus custom sibling gap and
   level gap **in the inspector**") lives — `map.json` has no spacing
   field.
5. Where the **contextual bar's** on/off lives (SPEC §6.3: "can be
   disabled in Settings").

## Decision

### 1. A node's branch overrides act on the connector INTO it

The connector drawn from a node's parent to the node carries that
node's branch overrides. Every non-root node owns exactly one incoming
connector (roots own none — the inspector disables the Branch section
for a root). This matches the palette-index precedent: a level-1
node's stored `paletteIndex` already colors the branch from the root
to it (ADR-0009), so the override reads as the same per-node knob.

`SceneBranch` carries `lineStyle` (§7.4 curved/tapered/straight/elbow/
none); `branchWidth` sets the start of a taper or the constant stroke;
`branchTaper` is the fall-off toward the child end, floored at §7.2's
2 pt leaf width.

### 2. The rainbow toggle (and the canvas color) persist as document-level theme overrides

`ThemePatch` — already the document's stored-overrides slot — gains
`rainbowBranches` and is the Canvas pane's canvas-color home. `nil`
means the theme's own value; the stored override wins. The
`setThemeOverrides` command applies it as one undo step, keeping other
stored overrides intact, and its exact-inverse route runs through a
wholesale `setThemeSelection` snapshot (the old id-only `setTheme`
inverse could not restore a cleared selection's stored overrides).
On a document with no stored selection, a patch pins the default
theme — the toggle must work on brand-new maps.

### 3. The logic chart is the one-sided placement at a uniform gap rhythm

A first attempt aligned every *level* at one shared left edge; the
stress suite rejected it — the non-layered tidy tree deliberately
interleaves cousin subtrees in y, so per-level columns collide. The
accepted reading of "children to the right, aligned at the left;
compact, like a horizontal outline": a parent's children already
share one left edge in the one-sided placement, and the structure's
own character is the **compact rhythm** — the level gap for every
parent→children step (including the root's) and the sibling gap
between children at every level, where the mind map widens level 1 to
the subtree and root gaps. Every tidy invariant (no overlaps, order,
determinism, incremental equality) carries over untouched.

### 4. Spacing is a user-level preference; the inspector is its editor

SPEC's `map.json` schema (§8.2) has no spacing field, and F-SET
already names a "default spacing" settings row — so spacing is
app-level (`DocumentPreferences`: preset + the two custom gaps), and
the inspector's Layout pane edits that preference, applying live to
the frontmost document. A custom level gap applies to every
parent→children step including the root's ("level gap" is what the
slider says). The scene cache is spacing-tagged, so a rhythm change is
a full rebuild per document.

### 5. The contextual bar's on/off is a preference the Canvas pane carries

The bar lives in the same UserDefaults surface as the minimap and tag
pills (`arbor.showsContextualBar`, default on). The inspector's Canvas
pane exposes the toggle now; a Settings ▸ Appearance row can join it
when that pane gains rows for canvas-level chrome.

## Along the way: formatVersion 4

Four optional fields join the schema — `NodeStylePatch.fontWeight`
(F-STY-2 text weight — the field the patch lacked),
`NodeStylePatch.fontItalic` (the §6.3 bar's I),
`NodeStylePatch.minWidth` (F-STY-2 width min) and
`ThemePatch.rainbowBranches`. All decode as `nil` from v3 files, so
`Migrations.v3ToV4` back-fills nothing — it only stamps the version
(fixture-tested like every step).
