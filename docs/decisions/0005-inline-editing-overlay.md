# ADR-0005: The inline editing overlay's contract

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

M1 slice 6a adds the inline title editor (SPEC §11.4; F-EDT-1/2/7/8/14/15, F-CAN-3/5). Several
decisions were either spec-silent or needed an explicit choice among AppKit behaviors.

## Decisions

1. **Point sizes scale with the zoom, no view transform.** The overlay is an `NSTextView` whose
   font sizes, frame and wrap width all multiply by `camera.scale`, so it renders crisp at every
   zoom and wraps identically to the measurer's model-space layout. A view transform
   (`scaleUnitSquare(to:)`) would rasterize text at the transformed size instead.

2. **The overlay is wider than the node, but hit-testing is confined to the node.** The text view
   spans the full wrap width (280 pt theme max) so typing never wraps early, yet clicks outside the
   node's rect return `nil` from `hitTest` and reach the canvas, which commits the session and
   selects. Clicks inside the node — including its padding band — go to the text view (caret).

3. **Editing keys are claimed via `performKeyEquivalent`, and the menu actions are
   editing-aware.** ⇥/⏎/⎋/⌫ are also menu key equivalents ("Add Child", "Add Sibling Below",
   "Deselect", "Delete"). Whichever wins AppKit's dispatch, the behavior is identical: the text
   view routes the event to the editing session, and the menu actions detect
   `canvas.isEditing` and do the same (commit-and-create, commit, forward the delete, insert a
   line break for ⇧⏎).

4. **IME guard (F-EDT-15):** while `hasMarkedText()` is true, every editing key is routed into
   the text input system instead (`keyDown(with:)`, bypassing the menu), so ⏎ confirms the
   composition and can never commit or create a sibling.

5. **Typing never touches the store; one commit is one `editText` command.** Each keystroke
   converts to a draft `NodeTitle` and the host rebuilds the scene with it (full rebuild for M1;
   incremental is the §9 follow-up). The host calls `closeEditSession()` after each commit, so two
   sessions on the same node are two undo steps (F-DOC-2). The overlay's typing undo lives on a
   private `UndoManager` that dies with the session — otherwise AppKit's typing coalescing would
   register steps on the document's stack and shadow the commit's `editText` step.

6. **An empty commit of a brand-new node keeps the node** (MindNode behaviour; the task brief's
   explicit choice). The F-CAN-3 "Central Idea" hint is drawn as a placeholder while the text is
   empty and never becomes text.

7. **Floating roots have no absolute position field** (SPEC §8.2 offers only `offset`, a manual
   offset from the auto slot). Double-click on empty canvas probes the post-add layout for the
   new root's auto slot and stores `click point − auto slot` as its `offset`; `SceneGeometry` now
   applies accumulated offsets after auto layout (also the F-LAY-11 groundwork for ⌥-positioned
   nodes). The root + offset is one grouped undoable command.

8. **Bold on system fonts is a weight, not a symbolic trait.** `withSymbolicTraits(.bold)`
   silently resolves back to the same weight on `.AppleSystemUIFont*`; the editor composes bold
   through the weight (≥ 0.4) exactly like `TextMeasurer`'s `max(base.weight, 0.4)`, so live and
   committed metrics agree and the §8.3 round-trip is stable.

## Consequences

- The context-dependent keys (⏎ edits a selected node; creates a sibling while editing) mean the
  "Add Sibling Below" menu item behaves differently from its title when a single node is
  selected. Menu titles will get contextual treatment when the contextual bar (§6.3) lands.
- Draft-scene rebuilds are O(map) per keystroke for now; the incremental dirty-path layout
  (SPEC §9) is the tracked follow-up.
