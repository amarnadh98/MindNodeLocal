# ADR-0032: A plain drag of a root moves the whole map

Date: 2026-11-20
Status: Accepted

## Context

MindNode's contract, and the user's expectation: grab the ROOT node and
drag it, and the whole map — root plus every descendant — moves with it
and stays where it is dropped. Arbor's plain drag didn't do that: a root
dropped on empty canvas resolved to `.newRoot`, and `DragCommands.newRoots`
only re-appended the root to the roots list (a no-op re-stack), so the map
snapped back to its auto-layout position. The only way to move a map was
the ⌥ free-position drag (F-LAY-11), which nobody discovers.

Roots carry no absolute position — only a manual `offset` from their auto
slot (SPEC §8.2, the same mechanism double-click's floating roots use,
F-CAN-5). `SceneGeometry` applies offsets after auto layout and a node's
offset moves its whole subtree, so the move mechanism already existed.

## Decision

1. **A plain drag (no modifier) whose every dragged node is a root is a
   map move.** The drop resolves to one `DragCommands.offsets` command —
   the existing F-LAY-11 `setOffset` per dragged root, carrying the drag
   delta accumulated onto any stored offset, with the same 24 pt
   snap-back rule. One undo step through the normal `MapStore` path;
   nothing is reparented, detached or reordered.
2. **Dropping a root ON another node's frame keeps the plain reparent
   drop** (F-EDT-5): the cursor over a node's frame is the one place a
   root drag still nests the root under that node. Everywhere else —
   empty canvas, back over the dragged root's own subtree, a sibling
   corridor — is a move.
3. **Multi-root maps move per root:** dragging one floating root moves
   that root's tree, not the others. Multi-selection drags move only
   when *every* dragged node is a root; a mixed root/child selection
   keeps today's behaviour (reparent over a node, snap back otherwise).
4. **The other modifiers are unchanged**: ⌥ free-positions (now the
   same thing as a plain root drag), D detaches non-roots, Space/⇧ drops
   a connection, Esc cancels. Non-root drags (reparent, reorder,
   snap-back on empty canvas) behave exactly as before.

Consequence: a root can no longer be *re-stacked* by dragging it to
empty canvas (the old `newRoots` re-append). Reordering roots was
already only reachable as "move to the end", and each root's permanent
position is its offset, so the loss is cosmetic; D followed by a move
covers the workflow. `DragCommands.newRoots` is removed with its call
site.

Also fixed in the same breath: `modelDidChange`'s incremental scene path
never mirrored the rebuilt scene into the minimap, so the minimap went
stale after any drag (a root move included). The incremental branch now
assigns `minimap.scene` like the full rebuild does.

## Consequences

- A root drag is one `setOffset` command: undo restores the pre-drag
  position exactly, redo replays the move, and the offset persists in
  `map.json` (save + reopen keeps the map where it was left).
- Connections, boundaries and summaries recompute from the placed frames
  on every build, so they follow the moved map automatically; the
  spatial grid syncs through the scene diff, so hit-testing lands on the
  moved nodes.
- Zoom-to-fit (⌘9) fits the moved bounds — nothing to change there.
- The insertion-line overlay is suppressed for all-roots drags (a
  corridor drop moves the map, it never inserts), and `isNoOp` learns
  `.setOffset` so a snap-back drop performs nothing — no phantom undo
  step.
