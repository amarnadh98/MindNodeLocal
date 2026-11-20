# ADR-0033: Space-drag pans the canvas; a Space tap keeps the replace-edit

Date: 2026-11-20
Status: Accepted

## Context

SPEC §6.2 promises "Use Space-drag or two-finger scroll to pan", and
the in-app shortcuts sheet already advertises "Pan the canvas —
Space-drag". Two-finger scroll panned, but Space-drag did nothing:
holding Space and dragging rubber-banded (or dragged a node), because
`keyDown` fell through to the F-EDT-2 typing rule — a plain Space on a
single selected node immediately began a replace-edit prefilled " ".

The conflict: Space has three existing meanings — replace-edit on a
selected node (F-EDT-2), a typed space inside the inline editor, and
"drop as a connection" while a node drag is active (F-REL-1) — and the
spec now adds a fourth, pan.

## Decision

1. **A plain, unmodified Space DOWN arms pan mode and consumes the
   event.** No ⌘/⌥/⌃/⇧ (⌘ shortcuts and ⌃⌥Space Quick Entry keep their
   events), no editing session open (the overlay's text view is first
   responder then and Space types), and no gesture in progress: not a
   pending or active node drag, not ⌘L's next-click mode, not a live
   connection-handle drag. **Space during an ACTIVE node drag is
   untouched — it still means connect** (`handleDragKey` owns it; its
   local event monitor runs before `keyDown` in the app, and the canvas
   routes a directly delivered key there too).
2. **While armed, the cursor is the open hand** (`resetCursorRects`
   adds one full-bounds rect, so it holds over nodes too; the closed
   hand while the button is down), **and the mouse gestures pan:**
   mouse-down, drag and up are consumed before any selection,
   rubber-band, Node Well, decoration or node-grab handling — `panByScreen`
   moves the camera by the drag delta (content follows the cursor, at
   any zoom; the delta divides by the camera scale, the same path
   two-finger scroll uses). No model command, no undo step.
3. **The tap-vs-hold rule: keyDown only arms; the tap meaning is
   deferred to keyUp.** A Space down+up with no mouse activity in
   between runs exactly the replace-edit the old `keyDown` default
   branch ran — `replaceEditText(for:)` + `beginEditingSelection(prefill:)`,
   so a single selected node edits prefilled " ", an image node Quick
   Looks (SPEC §5.4), and nothing happens with no selection. Any
   mouse-down while armed marks the hold: that release (and every later
   one) is a pan/click, never a replace-edit.
4. **Releasing Space while the button is still down finishes the pan**
   — a gesture in progress is never handed back mid-button; the drag
   keeps panning until mouse-up. Releasing Space with the button up
   ends pan mode (arrow cursor restored, normal gestures return). If
   focus leaves the canvas mid-hold (Quick Open, Find, another pane),
   `resignFirstResponder` disarms so pan mode can't get stuck without
   its keyUp.

Consequences: no timing heuristics (the mouse, not a timer, decides
tap vs hold); Space is never swallowed while editing; ⇧Space keeps its
old fall-through (replace-edit), as before this change.

## Consequences

- Space-drag pans at any zoom with no re-raster (the camera is a
  `sublayerTransform`, SPEC §11.4); pan is view state (F-CAN-8
  persists it through the host's camera-change hook) and never a
  model/undo step.
- The `SpacePanState` lives in `CanvasView+Pan.swift`; `CanvasView.swift`
  gains only the stored state and four consumed-event hooks, staying
  inside its swiftlint type/file length budgets.
- Headless tests (`SpacePanTests`) drive real `NSEvent` key/mouse
  events through `keyDown`/`keyUp`/`mouseDown`/`mouseDragged`/`mouseUp`,
  covering the pan (also over a node, at 2× zoom), the restore, the
  tap, the typing case and the connect case; a hosted test
  (`CanvasInteractionTests`) pans a real shown document and taps.
