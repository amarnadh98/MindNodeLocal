# ADR-0037: Box or Line — a per-node shape choice that carries its own look

- **Status:** Accepted
- **Date:** 2026-11-20

## Context

Real usage against MindNode: "sometimes I can't leave a node as just a
branch (a line with text on the line) instead of a box, and sometimes
the opposite — under one node I can't get a box, under another I can't
get a line." The shape came only from the theme's per-LEVEL style
(Paper: underlined level 2+; Studio per ADR-0031: outlined level-2
boxes, underlined level 3+), so the result depended on depth, and the
11-entry shape menu (contextual-bar popup, inspector row, Format ▸
Style) never read as "the knob that makes this a box or a line".

Worse, the knob was half-broken when found: a stored `shape` swap
left the level's other looks in place. Line on a filled level kept
the fill and drew NO line (the level had no border, so there was
nothing to convert into an underline — just text floating in a
tinted rectangle's ghost). Box on an underline level kept the
underline level's cramped 2/3 pt padding and zero radius — an
outlined box nobody would recognize.

The same session surfaced a second defect: the user's new maps still
opened in Paper. `defaults read com.example.arbor` showed
`DefaultThemeID = paper` **and** `arbor.defaultThemeID = paper`, with
`arbor.defaultThemeMigratedToStudio = 1` already set — the one-shot
migration of ADR-0031 had run, and the "paper" value reappeared after
its flag was set (a pre-Studio build's Settings picker wrote its
resolved default back; the flag then guaranteed the clear would never
run again). `arbor.defaultThemeID` is the dead key of a superseded
development build (commit 88d341c's `DocumentPreferences.defaultTheme`)
— nothing at HEAD reads it, but it kept describing a "paper" default
no code path ever chose.

## Decision

1. **The control.** A "Box | Line" segmented control leads the
   contextual floating bar (SPEC §6.3) and the Inspector ▸ Style pane's
   Node section. Both funnel into ONE selection action
   (`DocumentWindowController.setNodeShapeClass(box:)`), which is one
   `setStyle(ids:patch:)` command — one undo step for any selection
   size. The full 11-shape list stays in the inspector's Shape row and
   Format ▸ Style ▸ Shape. The control lights the segment matching the
   selection's class (stored override, else the theme's level shape);
   a mixed selection lights neither.

2. **The look resolves; it is not stored.** Box stores a background
   shape (`roundedRect` — the theme's box shape); Line stores
   `.underline`. The class-flip look lives in the theme resolver
   (`Theme.resolvedStyle` → `Theme.shapeDonor`): a Box on an underline
   level takes the theme's level-1 fill/border/corner-radius/padding
   (a sensible filled box); a Line on a box level takes the level-3+
   style's border and padding — text on a line in the branch color,
   the theme's own underline look. Font, text color, width bounds and
   shadows always stay the node's own level's; a patch's explicit
   fill/border/padding still win over the donor. Nothing is written
   as a hex, so the look respects light/dark and survives theme
   changes. Because a flip changes the donor padding, `shape` joins
   `NodeStylePatch.sizeAffectingKeys` (the layout-dirty set and the
   scene's size-cache fingerprint) — a flip re-measures, same-class
   picks over-mark safely (SPEC §11.3).

3. **Creation defaults** (`NodeCreationShape`, MapCore — pure and
   model-shaped so every create path shares one tested rule): a new
   sibling (⏎/⌥⏎) inherits the shape of the node it is created next
   to when that node carries an explicit override; a new child (⇥ and
   the Node Well's "+") follows its theme level style unless a
   sibling already carries an explicit shape — the LAST such
   sibling's shape wins (lines stay lines, boxes stay boxes; a
   trailing theme-default sibling does not hide an earlier explicit
   choice). The inserted parent (⌥⇥) keeps the theme's level style.

4. **The theme-default chain.** A second one-time migration
   (`ThemeCatalog.clearStalePaperDefault`) clears the dead legacy key
   and a stored default equal to Paper once more — the observed state
   is precisely "the old default came back after the flag", which
   ADR-0031 already declared not-a-choice; a deliberate Paper pick
   made afterwards sticks (this never re-runs). Two new-map paths that
   dropped the default got the same rule as `MapDocument.initialModel`:
   the onboarding tour map (previously theme-less → always Paper) and
   theme-less imports (`adoptImportedModel`, `x-arbor://new`) keep the
   untitled document's default theme instead of rendering as the
   engine's Paper fallback. Templates and saved maps are content and
   keep their own theme selections.

## Consequences

- One stored field per choice; `map.json` stays schema-free of new
  keys (no `formatVersion` bump — the `shape` field is v1).
- The scene's `BuildCaches` memoizes at most two extra styles per
  level/branch pair (the donor buckets), keeping the flip off the
  §11.8 fast path.
- Format ▸ Style ▸ Shape (all 11 shapes) still works untouched; the
  bar's old shape popup is replaced by the segmented control (the
  full list remains two clicks away in the inspector).
