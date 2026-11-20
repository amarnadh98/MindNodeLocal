# ADR-0034: Blank nodes are dropped by command, never by undo; siblings inherit the anchor's side

Date: 2026-11-20
Status: Accepted

## Context

PR #53 made a node created and left empty disappear when its editing
session ends (⌎ the click-away tidy-up). It did so by calling
`UndoManager.undo()` — "undo the creation" — guarded by a node-count
check. Two defects surfaced in real use:

1. **Data loss.** With the app's real undo grouping
   (`UndoManager.groupsByEvent == true`), the ⏎ commit-and-create runs
   two commands in one run-loop event — the just-typed `editText` and
   the post-commit `addSibling` — which land in ONE event undo group.
   When the user later clicks away from the still-blank sibling, the
   drop's `undo()` reverts that whole group: the blank sibling vanishes
   (so the count check passes) but the previously typed node's text is
   reverted with it. The user sees the box they typed into go empty.
   PR #53's tests never caught this because they set
   `groupsByEvent = false`, which splits the two commands into separate
   undo steps.
2. **Stray boxes.** A sibling or inserted parent created by ⏎/⇥/⌥⏎/⌥⇥
   or the Node Well carried no side pin, so the balanced layout's
   free-child alternation placed it on the opposite side of the map
   from the node it was created from; and a blank ⌥⇥ inserted parent
   (which owns the anchor as its child, so it is no *leaf*) survived
   every tidy-up as a stray empty box.

## Decision

1. **Never drop a node through `undo()`.** The blank-node drop is one
   deterministic `MapCommand` — `deleteSubtrees` for a blank leaf,
   `deleteNodePromotingChildren` for a fresh inserted parent — selected
   through the store like every other mutation, with the store's
   `selectionAfterDelete` picking the replacement selection. No undo
   history is consulted anywhere in the logic, so no undo-grouping
   regime (by event or not) can change what the drop removes. Safety
   rules unchanged from #53: only when the node's *stored* title was
   already empty (a session that never had content — clearing an
   existing node's text keeps the node), only a contentless node, and
   never the map's only root. Acceptable undo history: ⌘Z after the
   drop restores the blank box like any ordinary delete step; what is
   never acceptable is any change to other nodes' text.
2. **A fresh inserted parent is dropped through
   `deleteNodePromotingChildren`.** ⌥⇥'s node owns the anchor as its
   only child, so the leaf rule cannot see it as blank. The window
   controller records the node it just created as a fresh inserted
   parent; that record is consumed by the node's FIRST commit — empty
   drops it (promoting the anchor back into its exact slot), anything
   else makes it a normal node. An old empty-titled node with children
   is never touched, because the record is gone by then.
3. **⎋ on a just-created still-empty node drops it.** ⎋ during an
   editing session routes through the same commit path as a click-away
   (`NodeTextEditor.decide` maps it to `.commit`), so the empty-commit
   tidy-up covers it; a node left *selected but not edited* is not
   cleaned up retroactively (the user may still type into it via ⏎'s
   replace-edit). A session ended by focus loss
   (`sessionEndedByFocusLoss`, window switch) commits too, so it cleans
   up as well.
4. **A new sibling or inserted parent inherits the anchor's `side`
   pin** (⏎/⌥⏎/⌥⇥ while editing, the toolbar/VoiceOver sibling actions,
   Insert Parent): the box lands on the same side of the balanced map as
   the node it was created from/next to, instead of wherever unpinned
   alternation would place it. A new child keeps no pin — only a root's
   children carry one, and the Node Well already pins those by the
   clicked side.

## Consequences

- The drop is one undoable delete step; ⌘Z resurrects the blank box
  (harmless, and the user can ⌫ it away again).
- Tests drive the shown document with the real `groupsByEvent` undo
  grouping and real key events; because the hosted test host bypasses
  NSApp's event dispatch, the per-event undo group is drawn explicitly
  around each driven event (a bare run-loop pump does not close it in
  the test host). The regression suite reproduces the reported loss on
  the pre-fix code: the typed text is reverted and the typed-into node
  itself is left blank.
