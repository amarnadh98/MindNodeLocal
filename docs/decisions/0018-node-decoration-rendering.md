# ADR-0018: Node decorations render through one shared layout value

Date: 2026-11-19
Status: Accepted
Milestone: M3 (notes, links, tasks, tags)

## Context

M3 adds per-node decorations (SPEC §7): a leading task mark (checkbox for
a leaf task, F-TSK-1; a progress ring for a parent with task
descendants, F-TSK-2), trailing note/link badges (F-CNT-1/4) and tag
pills under the title (F-TAG-1). The canvas (pooled CALayers), export
and Quick Look must paint them identically, layout sizes must include
them, hit-testing must land where they were drawn, and the raster cache
must repaint only when they change. Concurrent slices (M2 inspector,
shapes) are editing `NodeRenderer` itself, so M3's additions needed a
clean seam.

## Decision

1. **One `NodeDecorations` value per `SceneNode`.** `SceneGeometry`
   computes it in the same walk that measures (never twice), from two
   O(n)-per-build passes: `TaskProgress.index` and the document tag
   table. Every consumer — renderer, overlay, hit-testing, a11y — reads
   the same value.
2. **All decoration geometry comes from one function**
   (`NodeRenderer.decorationLayout`, in `NodeRenderer+Decorations.swift`):
   title row, leading column, badge columns, pill row, in node
   coordinates. `drawTitle`, the editing overlay's placement and
   `CanvasView.decorationHit` all call it, so a click lands where the
   checkbox was drawn at every padding/theme shape.
3. **Sizes include decorations by construction**
   (`NodeRenderer.contentSize`): the measured text block keeps its
   `maxWidth` constraint; leading/trailing columns and the pill row add
   around it. Plain nodes are byte-identical to M2.
4. **`TaskProgress.index` holds exactly the ring set** — nodes with task
   *descendants*. This pins F-TSK-2's ambiguous "a parent with task
   descendants": a task node without task descendants renders a checkbox
   even though its subtree ratio would be (done, 1); a *non-task* node
   with a task descendant still renders a ring. Leaf-task completion
   (`setLeafTasksDone`) targets `TaskProgress.leafTaskIDs` (task nodes
   with no task descendants).
5. **Raster keys include the decoration value**, and `SceneDiff`
   treats a decoration change as `.restyled` — pan/zoom still never
   repaint, and an unrelated node's decoration change doesn't touch
   its siblings' rasters.
6. **Highlight mode (F-TAG-2/F-TSK-5) is view state**: matching ids
   ride `ApplyContext.highlightedIDs` and dim other layers to 25%
   opacity. No command, no undo; Esc exits before deselecting.
7. **Deferred with a seam**: `x-arbor://open?doc=…` links to another
   document route to `DocumentWindowController.onOpenExternalDocument`
   (unset by default, logged as deferred). Same-document node jumps are
   implemented.
8. **The incremental path (ADR-0011) treats decorations as measured
   inputs.** The per-document `SceneBuildCache` size key carries the
   decoration value (a change never reuses a stale size), the layout
   source records the last-measured value per node for the scene
   assembly, and `dirtyIDs` maps every decorations-affecting command:
   task changes dirty the node **plus its whole ancestor chain** (every
   ring is a leading decoration, so each ring node's own size is an
   input), `toggleTag`/`setNodeTags` dirty exactly their nodes, and
   tag-definition edits (`setTags`) return `nil` — the full-rebuild
   fallback, because a rename can touch any carrier node. A dedicated
   equivalence suite pins `update(dirty:)` == full rebuild across task
   toggles, tag edits and note/link edits.

## Consequences

- The done-task 50% text opacity is a fixed metric today
  (`NodeDecorationMetrics.doneOpacity`, the Paper value) — the theme
  field that overrides it lands with the theme slice.
- A map with tasks pays the O(n) progress pass on every full rebuild
  (~1.2 ms on 5k nodes with 25% tasks); SPEC's 8 ms keystroke budget
  still requires §11.3's incremental relayout, as before. Task-free
  maps skip the pass entirely (an early-exit scan).
- `SceneNode` grew by one optional field; `NodeDecorations` is
  `Hashable`, which is what keeps the raster-key comparisons cheap.
