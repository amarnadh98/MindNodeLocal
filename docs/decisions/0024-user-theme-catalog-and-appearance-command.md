# ADR-0024: User themes resolve through an app-level catalog

Date: 2026-11-19
Status: Accepted
Milestone: M2 (Look & feel)

## Context

F-STY-4 already gave documents a theme *selection*
(`model.theme.id`, ADR-0009) and `SceneGeometry` resolved it against
`BuiltInThemes`. F-STY-5 adds user themes: `.arbortheme` JSON files in
`~/Library/Application Support/Arbor/Themes`, importable, exportable,
installable by double-click, editable in the theme editor sheet with a
live preview. SPEC leaves three questions open:

1. How does a *document* reference a theme that is not compiled into
   the app?
2. What happens when a document's theme file is missing?
3. Is the per-document appearance override (F-STY-6) undoable, like
   the theme selection (`setTheme` is)?

## Decision

### 1. Themes resolve by id at the app boundary; built-ins win

A `ThemeCatalog` (App, `@MainActor`) merges `BuiltInThemes.all` with
the `.arbortheme` files in the themes folder, in load order, and is
the ONE resolver from document → `Theme` value. Built-ins are
compile-time app data and win over a user theme that reused their id;
an unknown id falls back to Paper, so a document whose theme file went
missing still opens, dressed in the default.

`SceneGeometry.build/update` gained an optional explicit `theme:`
parameter (default nil = the old built-in resolution). Every app-level
scene-build call site — the window controller (full and incremental),
the presentation coordinator, AI ghost probes, Quick Look previews and
the export paths — passes `ThemeCatalog.shared.theme(for: model)`; the
editor's live preview passes its *draft* value directly. No package
code changed, `MapCore` stays theme-file-agnostic, and a theme change
is still the full-rebuild `setTheme` path (dirty = nil).

### 2. Built-ins are read-only; edits mint a user id

The theme editor edits a working copy. Applying or saving a draft that
still carries a built-in id mints a `user-<uuid8>` id first, so built
in themes can never be shadowed by files; the sheet says so. Apply =
save to the catalog, then ONE `setTheme` command through the store —
one undo step, exactly like the inspector's one-click apply. "New
Theme from Current Map" is this same entry point: the draft seeds from
the live document's theme. Extracting per-node style overrides into it
lands with the inspector's per-node styles slice (the model does not
store enough yet — noted there).

### 3. Appearance is a command

F-STY-6's per-document Auto/Light/Dark override is a new undoable
`MapCommand.setAppearance(mode:)` with an exact-snapshot inverse
(`nil` normalizes to `.auto`, which the file format also stores). It
rides the ordinary store-change path; `SceneGeometry.dirtyIDs`
returns nil for it (the render variant flips, everything re-resolves).
View ▸ Appearance holds the radio group, validated by the one
`validateMenuItem` chain.

### 4. The M2 screenshot set renders from a test

`ThemeScreenshotTests` renders every built-in theme × light/dark
through the shared `SceneGeometry` + `SceneRenderer` pair into
`docs/design/themes/` (via the sandbox container — see that folder's
README for the copy step), so the committed set can only exist if the
real path draws it, and re-running the test is the drift check.

## Consequences

- A user theme moved between machines needs its `.arbortheme` file
  (or a re-import); documents keep working in Paper regardless.
- `ThemeCatalog.defaultThemeID` (Settings ▸ General) validates against
  the live catalog so a deleted default falls back to Paper.
- The export/Quick Look paths thread an explicit `Theme?` where they
  have no live scene, so user-themed documents export in their own
  colors.
