# ADR-0015: Study state on nodes, and grading as non-undoable history

Date: 2026-11-19
Status: Accepted
Milestone: M7 (Learn)

## Context

F-STD-3/F-STD-6 store a card's scheduling state **on the node** ("there is
no separate card database; card scheduling state is stored on the node in
the document file, so it travels with the map", SPEC §5.14), and §10 keys
that state "by card subtype": a node can carry several cards — basic
(`nodeID`), reversed (`nodeID#r`), one per cloze index (`nodeID#cN`) and
summary cards — each needing its own FSRS state. Grading a card also
appends to `study/reviews.jsonl` (§8.1), an append-only log.

Two questions the spec leaves open:

1. Where exactly do companion-card states live in `map.json`'s `study`
   object, whose schema (§8.2) shows a single `fsrs` field?
2. Is grading an undoable map edit? SPEC §11.3 says "every change to a map
   goes through a `MapCommand` with an inverse, registered with the
   document's `UndoManager`" — but a grading is a *review*, not an edit.

## Decision

### 1. Per-card state: `fsrs` keeps the basic card, `fsrsByCard` holds the rest

- `study.fsrs` (the existing field) remains the state of the node's
  **basic** card, so files written by M7 slice 1 — and the FSRSCard
  round-trip built on it — read exactly as before.
- A new **optional** `study.fsrsByCard` dictionary holds every other
  card's state, keyed by card key: `"r"` (reversed), `"cN"` (cloze), and
  `"s:<summaryID>"` (a summary card owned by this node — its card id is
  the summary's id, not node-derived).
- A new **optional** `study.deck` boolean on a branch node marks a Study
  deck (F-STD-1 "Make Study Deck"); `nil` reads as not-a-deck.

Both fields are additive and optional, so `formatVersion` stays at **2**
(the same additive precedent as `FSRSState.learningSteps` in slice 1:
v2 files decode with the fields absent; no migration is needed because
there is nothing to back-fill — absence is the pre-M7-slice-2 meaning).

Deck semantics (also spec-silent, recorded here): the deck node itself
counts as *inside* its deck ("a branch is a node plus its subtree",
§18); explicit `card: on/off` beats the auto rule anywhere; cloze markup
anywhere is explicit intent and derives cards regardless of decks; a
branch session (`Study Branch`, `Study Weakest Branch`) treats its scope
root as an implicit deck for the session's duration.

### 2. Grading is a `MapCommand` but NOT on the user's undo stack

- The write still goes through the command layer: one
  `MapCommand.setStudy(name:id:study:)` per grade, with an **exact**
  snapshot inverse (property-fuzz covered like every other command). No
  view mutates the model directly; §11.3's mechanism is intact.
- The store applies it through a new **`performWithoutUndo`** path: the
  model changes and the host is told to mark the document dirty
  (`.nonUndoable` origin → `updateChangeCount(.changeDone)`), but nothing
  registers with the `UndoManager`, so the next autosave persists both
  the FSRS state and the appended review.

Why the deviation from §11.3's letter is right:

- **A review cannot be un-happened.** The same grading appends to
  `study/reviews.jsonl`. An undoable grading would rewind the node's
  FSRS state while the log keeps the review — desyncing state from
  history, and corrupting the input of the P2 parameter optimization the
  log exists to serve (§10). Reviews are history, not edits.
- **It matches the platform.** Undo is for *document edits*; no
  flashcard app (Anki, MindNode's study sibling) puts "Grade Good" on an
  undo stack, and F-DOC-2's "meaningful action names" are about edits.
- **The document still saves.** The non-undoable path deliberately marks
  the document dirty, so autosave persists grading without the user ever
  pressing ⌘S — the user-visible contract of §11.3 (nothing is lost) is
  unchanged.

## Consequences

- Deck toggling and card marking (Make Study Deck, Card / Not a Card /
  Auto) ARE user edits and stay normally undoable through the same
  `setStudy` command.
- Duplicating a node strips all review state (basic + companions) — a
  duplicate is a new node, not a clone of a study history.
- The mastery overlay, dashboard and Study Due read the document's
  deck-gated card set (`CardExtractor.extract(from:)`); sessions are
  scope-based (`extractAll` / `extract(from:subtreeRoot:)`).
