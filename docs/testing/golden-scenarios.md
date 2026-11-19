# Golden-path scenarios — what is automated, and where

SPEC §3 defines five golden-path scenarios; §14 requires them end to end
(UI row of the testing table). This page tracks which are automated,
where they live, and how to run them.

| # | Scenario (SPEC §3) | Status | Where |
|---|---|---|---|
| 1 | Launch → New map → type root → ⇥ child → ⏎ siblings → drag a branch to reparent → ⌘S → quit → reopen: everything restored | **Automated (M1)** | `App/Tests/GoldenScenarioOneTests.swift` (hosted) |
| 2 | Paste 40-line Markdown → map → Radial → theme → PDF export | Not yet — depends on paste (M1, partly covered by `ClipboardTests`), Radial (M2), themes (M2), export (M5) | — |
| 3 | Select branch → Study Branch → 10 cards → mastery colors | Not yet — M7 (`MapStudy`) | — |
| 4 | Present → auto slides → arrow keys + clicker → presenter notes | Not yet — M6 | — |
| 5 | Global hotkey → Quick Entry → indented list → Create Map | Not yet — M4 (`F-QEN`) | — |

## Scenario 1: how it is automated

`GoldenScenarioOneTests.launchNewMapEditDragSaveQuitReopenRestoresEverything`
runs the whole scenario through the **real app paths** as a hosted test
(in the app process, real `NSDocument`, real window):

- **Launch → New map**: `NSDocumentController.makeUntitledDocument` +
  the real `DocumentWindowController` window (F-CAN-3 seeds the
  placeholder root, already in edit mode).
- **Typing**: text into the editing overlay's `NSTextView`
  (`CanvasView.nodeTextEditor.insertText`).
- **⇥ / ⏎ / ⎋ / ⌘=**: key events through the first responder — the
  overlay's `performKeyEquivalent` while editing (the routing that beats
  the menu's key equivalents, F-EDT-1), the canvas's `keyDown` otherwise.
- **Drag to reparent**: synthesized `NSEvent` mouseDown/mouseDragged/
  mouseUp over real view points (scene frames through the camera).
- **⌘S**: the real save machinery (`NSDocument.save(to:ofType:for:)`,
  the Save-As path minus the panel) to a temp `.arbor` URL — iCloud Drive
  in SPEC §3 stood in for by a temp directory.
- **Quit → reopen**: `document.close()` (which flushes the F-CAN-8
  view-state sidecar), then `NSDocumentController.makeDocument(
  withContentsOf:)` + `showWindow`. The sidecar runs against an injected
  temp `ViewStateStore` base directory (ADR-0005).
- **Asserts**: the tree (titles, structure, order, the reparented
  branch under its new parent), the camera (scale + origin within
  0.5 pt), the selection, a clean change count after save and after
  reopen, and one undo step per user action (12 counted; the test also
  proves a full undo returns to the pristine placeholder map and redo
  rebuilds it step for step).

Run it alone:

```bash
xcodebuild -scheme Arbor -destination 'platform=macOS' test \
    -only-testing:ArborTests/GoldenScenarioOneTests
```

or as part of the usual suite (the CI `xcode` job runs it with the rest
of `ArborTests`):

```bash
xcodebuild -scheme Arbor -destination 'platform=macOS' test
```

## Why there is no XCUITest target (yet)

Scenario 1 is deliberately a **hosted** test, not an `ArborUITests`
XCUITest target. A hosted test drives the identical window/document/
responder code (the only untested layer left is AppKit's own event
dispatch), runs in ~2 s, and is deterministic — it passed three
consecutive full runs locally. An XCUITest version would additionally
exercise `NSApplication.sendEvent` and the menu bar, but its remaining
value is small today while its costs are real: the save step needs
save-panel automation (fragile), sandboxed launch timing is flaky on
loaded CI runners, and a UI-test target doubles the build matrix of a
job that does not gate merging. The plan (per SPEC §14's "UI: smoke")
is to add an `ArborUITests` target in its own scheme — outside the CI
`xcode` job — once a second scenario (2 or 5) is ready to share the
launch cost.
