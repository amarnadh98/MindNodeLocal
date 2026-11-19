# ADR-0020: The Quick Entry global hotkey is a small in-app Carbon wrapper, not a dependency

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

F-QEN-1 (SPEC §5.11) needs a **global** hotkey (default ⌃⌥Space, configurable):
a key combination that opens the Quick Entry panel from *any* application, not
just while Arbor is frontmost. System-wide key monitoring on macOS is the one
thing SwiftUI/AppKit still delegate to Carbon's `RegisterEventHotKey`
machinery. The ecosystem answer is the `KeyboardShortcuts` package (SPEC even
says "KeyboardShortcuts package-style Carbon registration"), which is itself a
thin wrapper over the same Carbon calls.

SPEC §11.1 caps runtime dependencies at 8, and every added one must first earn
an ADR. Today the app carries **zero** third-party runtime dependencies.

## Decision

Write the ~40-line wrapper in-app (`GlobalHotkeyCenter` in
`App/Sources/QuickEntry/`) instead of adding a dependency:

- `RegisterEventHotKey`/`UnregisterEventHotKey` register one hotkey at a time
  against the application event target; re-registering swaps atomically
  (unregister first).
- One `InstallEventHandler` on `GetApplicationEventTarget` for
  `kEventClassKeyboard`/`kEventHotKeyPressed`, installed lazily on first
  registration, forwards to a `@MainActor` closure through the handler's user
  data. Carbon delivers application-target events on the main thread, so the
  main-actor hop is an `assumeIsolated`, not a dispatch.
- `HotkeySpec` is a small value type (virtual key code + Carbon modifier bits)
  whose `"49:6144"` string form persists in UserDefaults; a recorder view in
  Settings captures the next modifier-combination press and re-registers.
- The default is ⌃⌥Space per SPEC §6.1; the recorder refuses ⌘-combos (that
  key space belongs to menu commands) and bare keys (they would swallow normal
  typing in other apps).
- **Frontmost de-duplication:** the File ▸ Quick Entry menu item carries the
  registered spec as its key equivalent (kept in sync on every rebind). While
  Arbor is frontmost, that menu equivalent delivers the same key press to the
  app's menu, so the Carbon handler skips (`hotkeyTriggered`) — otherwise one
  press would toggle the panel open and closed in the same event, since Carbon
  hotkeys fire even when the registering app is active. While any other app is
  frontmost, only Carbon sees the key — the global path. Keys a menu can't
  represent stay Carbon-only.

## Consequences

- No dependency, no update cadence, no supply-chain surface for a feature that
  needs ~40 lines: the dependency budget stays at 0 of 8.
- The cost we accept: KeyboardShortcuts' conveniences (menu-item sync of
  recorded shortcuts, per-user storage niceties) are not inherited; if a
  second global hotkey ever lands, promoting the wrapper to the package (with
  its own ADR) is a local change — every consumer goes through
  `QuickEntryCoordinator`.
- The hotkey works in the sandbox as shipped (Carbon hotkeys are not gated by
  the app sandbox), so no entitlement changes.

## The menu-bar extra

The same F-QEN-1 row asks for a toggleable menu-bar extra; that is plain
`NSStatusItem` and needs no decision beyond its UserDefaults key
(`QuickEntryMenuBarExtra`, default on). Both entry points — hotkey and menu
bar — funnel into `QuickEntryCoordinator.togglePanel()`.
