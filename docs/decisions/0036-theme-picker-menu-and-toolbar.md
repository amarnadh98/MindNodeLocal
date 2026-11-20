# ADR-0036: Theme selection gets a menu door and a toolbar pull-down

Date: 2026-11-20
Status: Accepted

## Context

User feedback: "there is no theme selection in the Arbor app." There
was — the Inspector's Theme pane (F-STY-4) — but it is hidden by
default behind View ▸ Toggle Inspector (⌥⌘I), so a user who never
opened the inspector had no findable way to change the current map's
theme. SPEC §1 principle 2 ("every action is also discoverable from
menus") and §14.1 require menu reachability; the spec names no
concrete menu path for theme choice (F-STY-4 only says "one-click
apply from Inspector ▸ Theme").

## Decision

1. **Format ▸ Theme** is the canonical menu path: a submenu listing
   every theme `ThemeCatalog` knows (built-ins first, then user
   themes), built by one shared factory (`ThemeMenuController`) that
   both doors use. Each item carries the theme's name (keyboard menu
   navigation and VoiceOver), a canvas-colour swatch image, a
   checkmark when it is the current theme, and a "— Default" title
   suffix when it is the new-map default (Settings ▸ General).
2. The existing **Edit Theme… ⇧⌘E** item moved from the Format top
   level into the submenu, and a **Show Theme Inspector** item was
   added (`InspectorPaneController.show(tab:)` — a show-always door,
   never uninstalling a visible pane).
3. The toolbar gains a **Theme** item — an `NSMenuToolbarItem`
   (`paintpalette`) whose menu is the same factory's output. The
   toolbar autosave name bumps `ArborDocumentToolbar.v2` → **`.v3`**:
   autosaved v2 configurations predate the item, and a bump is the
   one-time reset that hands existing users the new default set (the
   same trick the v1 → v2 icon-and-label bump used).
4. Choosing a theme routes through the window controller's
   `setDocumentThemeAction`, which performs the SAME one
   `MapCommand.setTheme` the inspector performs — one undo step; the
   already-current theme is a no-op; read-only documents refuse it.
5. **Live hover preview (F-STY-4)** rides `NSMenuDelegate`:
   `menu(_:willHighlight:)` pins the highlighted theme through the
   existing `previewThemeOverride` seam (view-only — no model, undo
   or dirty change); `menuDidClose` and highlighting anything else
   restore the stored selection.
6. The submenu is **eagerly populated at build time** and refreshed
   in `menuNeedsUpdate` — so the ⇧⌘P palette and the ⌘/ cheat sheet,
   which walk the live `NSApp.mainMenu`, list every theme and the
   ⇧⌘E item before the submenu is ever opened.

## Consequences

- One factory, two doors (menu + toolbar), one command, one preview
  seam — no third copy of the theme list.
- AppDelegate stays inside its swiftlint length limits: the
  menu-building helper lives in `AppDelegate+ThemeMenu.swift`
  (`App/Sources/Themes/`), and `AppDelegate.swift` swaps one item.
- Hosted `ThemePickerTests` cover the list, checkmark, default mark,
  doors, one-undo choose/undo/redo, the no-op, validation (enabled
  only with a document window), the view-only hover apply/revert, and
  the toolbar's default + installed identifiers.
