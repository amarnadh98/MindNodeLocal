# ADR-0031: Studio, the default theme for new maps

Status: accepted · Date: 2026-11-20

## Context

Hands-on use against MindNode showed Paper's proportions reading as
dense and wiry: tight padding (0.75× the text size against MindNode's
1.2×), 2.2× text height per node (3× there), branches 0.18× the text
size in width (0.32×), dark-tinted level-1 fills with white text in
dark mode, underlined leaves, and round branch caps that poked through
outlined nodes. SPEC §7.2 defines Paper as the reference theme, and
`PaperThemeEquivalenceTests` pins it to the M1 reference renderer.

## Decision

1. Add **Studio** as the first built-in theme and the default for new
   maps (`BuiltInThemes.newDocumentDefaultID`). Paper is untouched and
   stays the engine fallback (`BuiltInThemes.defaultID`: a map with no
   theme selection, or an unknown id) so existing geometry and the
   reference test are stable.
2. Studio: solid pastel level-1 fills with dark text in both
   appearances, outlined rounded level-2 boxes, underlined level 3+,
   26/18/16 pt rounded type, 24×14 pt level-1 padding with a 150 pt
   floor (`ThemeLevelStyle.minWidth`, new and optional), 9→3 pt tapered
   branches.
3. A font-family token, `FontSpec.roundedFamily` ("system-rounded"),
   selects the rounded system face; any weight keeps it rounded.
4. Tapered branches end **flat** and run 0.75 pt into their nodes. A
   round cap bulged through outlined nodes' borders; a flat tucked end
   meets the border or fill flush. This changes every theme's branch
   ends (hence the SVG golden and theme screenshots).
5. One-time migration: a stored default-theme id of "paper" from before
   Studio is the old default, not a choice, so it is cleared once.

## Consequences

- Files and Settings keep working: a theme id is just an id.
- Existing maps without a theme selection still render as Paper.
- The theme gallery has 13 themes; `docs/design/themes/` holds 26 renders.
- The palette and proportions were chosen by eye against screenshots,
  not copied from any MindNode asset or theme file.
