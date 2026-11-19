# ADR-0022: Recall mode as view state over the shared reveal overlay

Date: 2026-11-19
Status: Accepted
Milestone: M7 (Learn)

## Context

F-STD-5 puts recall **on the canvas**: select a branch → the branch's
descendants hide behind blurred placeholders (outlines visible), a
click or → reveals one at a time, ⌥-click reveals a subtree, and 1/2
mark each revealed node ✓ remembered / ✗ forgot, "which feeds FSRS as
Good/Again for that node's card if it is one". SPEC is otherwise silent
on four points:

1. What state is recall, and where does it live?
2. What exactly does → reveal — a node, or a subtree (the
   presentation build step reveals subtrees)?
3. Which of a node's several cards does a ✓/✗ feed?
4. How do the "blurred placeholders" render on the pooled layer tree?

## Decision

### 1. Recall is view state, with a session-owned machine

Recall is a `RecallSession` (App) driving a **`RecallMachine`**
(MapStudy, pure) over the existing `RevealOverlay` on the canvas layer
tree — the same overlay channel presentation mode reads (SPEC §10:
"the canvas renderer reads a `RevealState` overlay"). No model
mutation ever happens to enter, use or exit the mode; entering and
exiting are one opacity/effect pass, never a re-raster. A transparent
input shield over the canvas (the `PresentationShield` pattern) keeps
every canvas gesture from selecting or editing mid-recall, while
pan/pinch are forwarded so an off-screen branch stays reachable.

Because the shield only covers the canvas, menus still fire during a
run. A **real edit** (undo/redo included) therefore *ends* the mode —
`modelDidChange` stops the session on any origin except
`.nonUndoable`, so the overlay can never go stale against the tree.
The mode's own grading writes (`.nonUndoable`, ADR-0015) keep it
alive.

### 2. → reveals exactly one node; ⌥-click is the subtree reveal

The machine's reveal order is depth-first pre-order in `children`
order (map order, the same walk `CardExtractor` uses). `revealNext`
and a click insert ONE id into the revealed set — no cascade, unlike a
presentation build step whose ids carry their subtrees. The ⌥-click
expansion is `RevealEngine.subtree(of:)` — a new public method that
exposes the engine's own `collect` walk — so the hierarchy semantics
(subtree = id + everything below, cycle-safe) stay defined in exactly
the one place. Folded-away descendants are filtered out at start
(through the scene's ids), so → never stalls on an invisible node.

Esc exits through the same route the app's other modes use: the
bare-⎋ *Deselect* menu equivalent reaches `deselectAction`, which
routes to a live recall session first (the shield's
`performKeyEquivalent` usually consumes the key even earlier).

### 3. A mark feeds the node's basic card under the branch session scope

`RecallMachine.markingTarget(for:)` answers the node's **basic** card
from `CardExtractor.extract(from:subtreeRoot:)` — the branch session
treats its root as an implicit deck (ADR-0015's scope rule), so
noted/childful descendants are cards even without a deck mark. The
grade rides the existing non-undoable write path
(`MapDocument.grade`), so ✓ = Good, ✗ = Again, with the same
review-log append and no undo step. Non-card nodes (bare leaves, or
`card: off`) are session feedback only — no FSRS write, no dirtying.
Clozes, reversed and summary cards are session-UI artifacts; recall
tests spatial memory of a node as a whole, so only the basic card
carries the mark. The branch node itself stays visible as the prompt
and is never a marking target.

### 4. Placeholders blur through a per-layer Core Image filter

The M6 placeholder state was a plain 0.35 opacity dim; the overlay's
own doc reserved "a true blurred outline" for M7. `setRevealOverlay`
now also installs a `CIGaussianBlur` (radius 6) via macOS's public
per-layer `CALayer.filters` while a node's state is `.placeholder`,
and clears it on reveal/exit — an effect on the existing raster
(never a re-raster, the raster key is untouched), applied in the same
pass as the opacity write and picked up identically by the culling
realize path. Outlines and shape read; text does not.

## Consequences

- `RevealEngine.subtree(of:)` is a small widening of the engine's API
  (the collection logic was already there for `revealedIDs`).
- The dashboard reminder's time (F-STD-7's "toggle + time" leftover)
  is not part of this ADR's recall surface; it rides `UserDefaults`
  (`StudyDailyReminderTime`) and re-schedules the same local
  notification request atomically when the time changes.
- Hundreds of blurred placeholder layers are GPU-composited effects
  on already-realized layers; culling bounds the count to the
  viewport as before. If a future profile shows cost, the blur can be
  dropped per-zoom-band without touching the machine.
