# ADR-0005: View state persists in a per-user sidecar, not the document

- **Status:** Accepted
- **Date:** 2026-11-19

## Context
F-CAN-8 (SPEC §5.1) requires the per-document view state — zoom, scroll, selection, folded nodes, active view — to be restored on reopen. SPEC §8.2 reserves a `view` field inside `map.json` for it, but view state changes with every pan, pinch and click:

1. Writing it into the package on each change would dirty the document (autosave + Versions churn) on camera moves that are not model mutations — SPEC §11.3 ties `updateChangeCount` to commands only.
2. `map.json` is sold as Git-friendly (§8.1: pretty-printed, sorted keys, clean diffs); a camera origin that changes on every scroll would pollute every diff.
3. Zoom and scroll are per-user comfort state, not map content — one person's 180% zoom shouldn't be imposed via the shared file (iCloud/Dropbox between a user's own devices is the real case).

Folded flags are different: they change what the document *shows* and already live on `node.folded` in `map.json` (F-LAY-14). They are not duplicated in the sidecar.

## Decision
Persist the view state as a JSON sidecar keyed by the document's `docID`, stored outside the package by `ViewStateStore` in CanvasKit:

- Location: `~/Library/Application Support/Arbor/ViewState/<docID>.json` (production base; injectable for tests). Written atomically with sorted-key pretty-printed JSON, per SPEC §8.1's conventions.
- The host writes it on camera/selection change (debounced by the caller), never through `MapDocument.updateChangeCount` — panning does not dirty the document.
- `MapCore`'s schema-level `ViewState` (the `map.json` `view` field, SPEC §8.2) remains in the schema as the portable fallback the app may write on explicit save; it is not the live store.
- On restore, selection is sanitized against the scene — ids deleted or folded away since the last session are dropped (folded flags themselves restore from `node.folded`).
- A missing or corrupt sidecar means "fresh default view" (`nil`), never an error: it can't block opening a document.

## Consequences
- Reopening restores zoom, scroll and selection (F-CAN-8) with zero document churn and clean Git diffs.
- View state does not travel with the file: moving a map to another Mac (or another user) resets the view. Acceptable — it is comfort state, and the in-document `view` field covers portability once the app wiring chooses to write it on save.
- The directory grows one small file per document ever opened; pruning stale docIDs is deliberately deferred (not required at this scale).
- Sandbox note: Application Support is app-scoped, so no extra entitlement is needed.
