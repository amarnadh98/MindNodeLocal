# ADR-0026: Summary nodes keep their tree slot, placed post-layout

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

F-REL-3 (SPEC §5.5) adds summaries: a brace over a run of consecutive siblings and a REAL summary
node beyond it — a first-class node that can have children and is a flashcard candidate. Two
placement options existed:

1. A dedicated layout pass in `MapLayout` that treats summary nodes specially (MindNode-style).
2. An ordinary child of the range's parent, appended after the range, with a post-layout
   corrective translation in `SceneGeometry`.

## Decision

Option 2. The summary node is created by `RelationCommands.summary` as a plain
`addChild(parent: rangeParent, index: afterRange, node:)` plus an `addSummary` record — one
grouped command, one undo step. After `TreeLayout` places the root's tree, `SceneGeometry`
computes each summary's brace geometry from the range frames
(`RelationPath.summaryNodeFrame`), translates the summary node (and its descendants, like any
manual offset, F-LAY-11) to just beyond the brace, and the brace itself derives from the final
frames in `RelationGeometry.build`.

## Consequences

- Outline order, drag-reparent, folding, undo/redo and every existing command work on summary
  nodes with zero special cases; the summary participates in ordinary tree operations and only
  its *visual* position is adjusted.
- Placement is a pure function of the placed frames, so it is recomputed on every scene build
  and stays identical on the full-rebuild path and any future incremental path (both end at the
  same frames).
- The braces go right for horizontal layouts (left on the balanced map's left side — mirrored
  per range) and below for org charts (above for org-up), matching the map's reading direction.
- Deleting a range node purges the summary record (`purgeSecondaryReferences`/`purgeStaleSummaries`
  already run inside the delete commands); the summary NODE survives as an ordinary node when the
  record is purged — deleting it is a separate, ordinary delete.
- A summary node's auto slot (right after the range) means a theme/layout that overrides this
  slice can move the visual without touching the record.
