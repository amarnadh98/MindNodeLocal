# ADR-0009: Data-driven theme model with a persistent palette index

- **Status:** Accepted
- **Date:** 2026-11-19
- **Supersedes:** ADR-0004

## Context

M2 slice 1 introduces the theme engine (SPEC §5.8 F-STY-3/4/6/8, §7). Three
decisions fell outside the spec's detail:

1. How the twelve built-in themes are shipped.
2. How Paper, until now hand-rolled in `PaperTheme`/`ThemeResolution`, becomes
   the first data theme without changing a pixel of the M1 canvas.
3. Where the persistent branch palette index (ADR-0004's follow-up) lives and
   who assigns it.

## Decision

### The theme model

`MapRender.Theme` is a pure `Codable`, `Sendable` value: id, name, a light and
a dark `ThemeScheme` (canvas color, 8–12 palette colors, level styles for
root/1/2/3+), branch style (line style, start/end width), a rainbow-branches
toggle, and connection/boundary style placeholders. Colors are `#RRGGBB`
strings; alpha lives in the referencing field (`ThemeFill.palette(alpha:)`,
`ThemeShadowLayer.alpha`), never inside the string. The same `Codable` schema
is the `.arbortheme` JSON contract (F-STY-5 import/export); fills and paints
encode as friendly JSON: `"none"`, `"#RRGGBB"`, `{"palette": 0.16}`,
`"palette"`.

Resolution (F-STY-3) is `Theme.resolvedStyle(level:level1Index:variant:)`:
theme → level style → branch color from the level-1 ancestor's palette index.
Per-node overrides are a documented seam (`applyingOverrides(_:to:)`, the
`overrides:` parameter) that the inspector slice will fill in; today it is an
identity so resolution stays honest about being theme-only.

### Built-ins as Swift literals, not JSON resources

The twelve themes ship as Swift literals in `BuiltInThemes` (compile-time
type-checked, zero I/O at first paint, no bundle resource plumbing), **not** as
JSON resources. The JSON path is still proven by round-trip tests over every
built-in plus a hand-written `.arbortheme` file, because the theme editor
(F-STY-5) will read and write the exact same schema.

### Paper stays pixel-identical

`PaperTheme` (the reference implementation) is untouched, and its existing
tests keep guarding it. The data Paper theme carries the same values, with two
precomputations:

- The dark palette stores the §7.2 "+8% lightness" hues as literal hexes
  (computed once from the runtime HSL boost), so no theme needs a special
  dark-adjustment code path.
- Shadow alphas stay exact floats via `ThemeShadowLayer.alpha`.

`PaperThemeEquivalenceTests` asserts the data theme and the reference resolve
identically for levels 0–4, palette indices 0–15, both variants, field by
field.

### Persistent palette index (formatVersion 2)

ADR-0004's positional coloring is **superseded**: level-1 nodes store
`Node.paletteIndex`; `formatVersion` bumps to 2 and `Migrations.v1ToV2`
back-fills each root child's **current position**, so v1 files render with
exactly the colors they had. Deeper nodes store nothing; they inherit their
level-1 ancestor's index at render time. `nil` (legacy, or a node promoted
into level 1 without an index) falls back to the node's position.

Creation commands (`addChild`, `addSibling`, `insertParent`) assign the
**next unused** index among the target's new siblings when the fresh node
carries none, so new branches never steal a sibling's color; payloads that
already carry an index (duplication, paste) keep it. This lives in
`MapCommand.apply` — the same place parent/children are stamped — so every
creation path (canvas, editor, automation) gets it without per-call-site
wiring. The delete-promote inverse restores via `insertSubtrees` (the
wholesale path) rather than `addChild`, so a restore never counts as a
creation.

`recolorBranches(assignments:)` (F-STY-8) sets indices explicitly; its
inverse is a snapshot of the pre-state, exact even across `nil` indices.
`MapCommand.recolorBranches(rootID:in:)` builds the user-facing action as a
sibling rotation. `setTheme(id:)` (F-STY-4) sets the document's theme
selection, preserving stored overrides; `nil` clears it back to the default.

## Consequences

- `SceneGeometry` resolves everything from `model.theme?.id` (default paper)
  and the appearance variant; `PaperTheme` remains as the reference for tests
  and the editing overlay's color utilities.
- The rainbow toggle off means every branch uses palette color 0 (Blueprint
  is the one built-in that opts out).
- A migrated-and-saved document writes `map.json` at v2 while its `meta.json`
  keeps the previously-read `formatVersion`; harmless (the loader migrates
  from `map.json`'s own version) but worth aligning on save in a follow-up.
- `meta.json` formatVersion for brand-new documents is 2 via the
  `PackageMeta` default.
- The theme editor slice must add: per-node override application, the
  inspector's Theme picker, and `.arbortheme` import/export.
