# ADR-0023: Read-only documents are enforced by the MapStore, not by the UI

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

F-DOC-4 (SPEC §5.18): opening a package whose `formatVersion` is *newer*
than the app's must open the document **read-only with a banner** rather than
refusing. A forward migration is impossible by definition; the JSON decodes
(the coder ignores future keys), so the honest behavior is "look, don't touch".

The app has many mutation entry points: the canvas overlay's commit path, the
outline view's split/merge/indent/move/drop, the find-replace engine, drag to
reparent, study grading, slides authoring, and now Quick Entry's appends into
open documents. Disabling each UI path one by one would miss some and rot as
new paths land.

## Decision

Enforce read-only at the one choke point every mutation already funnels
through: `MapStore.isReadOnly` (ADR follows the gateway rule of SPEC §11.3 —
every change to a map goes through the store).

- `MapDocument.read` catches `ArborError.unsupportedFormatVersion`, re-reads
  through `ArborPackage.readWithoutMigration`, sets `isReadOnlyFormat`, and
  locks its store (`store.isReadOnly = true`).
- `MapStore.perform` and `MapStore.performWithoutUndo` **throw** while locked:
  the model, the undo stacks and any open edit session are untouched. Undo and
  redo need no gate of their own — nothing can register while locked.
- `MapStore.replaceModel` deliberately ignores the gate: it is the load and
  revert path, and an external-change reload (F-DOC-3) must always work — even
  for a read-only document.
- The UI layers then *tell the truth* about the same state: menu validation
  (`validateReadOnlyMenuItem`) disables the mutating actions, and the window
  carries a banner. Truth-telling only — the gate is the store.

## Consequences

- One flag, enforced everywhere, including paths that predate the feature
  (outline editing, study grading) and future ones.
- A refused command behaves exactly like any other throwing command: no-op,
  nothing to undo, no change count bump — so NSDocument stays clean and no
  autosave can write a future-format `map.json` back to disk.
- Quick Entry is honest about it too: appending into a read-only target shows
  an alert and keeps the captured text in the panel, so nothing typed is lost.
- Duplicate is disabled for read-only documents as well: a duplicate would
  mint a copy claiming a version this app can't vouch for.
