# ADR-0007: The canvas's VoiceOver row model

- **Status:** Accepted
- **Date:** 2026-11-19

## Context

M1 slice 7c exposes the canvas to VoiceOver (SPEC §11.6): one element per visible node, custom
actions, focus notifications. The spec says "role outline row", which does not exist as a
distinct role in macOS's accessibility API, and the element has to stay correct through camera
pan/zoom on a view that renders into a single backing layer (no per-node NSViews exist).

## Decisions

1. **Rows report `AXRow`, outline-ness is carried by the disclosure attributes.** macOS has no
   `.outlineRow` role; `NSOutlineView` rows are `AXRow` whose hierarchy is conveyed through
   `AXDisclosedByRow` / `AXDisclosedRows` / `AXDisclosing`. `CanvasAccessibilityElement` does the
   same: the closest fitting role plus full disclosure wiring, so VoiceOver announces
   *"Goals, 4 children, expanded"* and can walk the tree.

2. **Frames are computed live, attributes are set at build time.** The canvas pans and zooms at
   120 fps; caching element frames would need per-frame invalidation traffic. Instead
   `accessibilityFrame()` derives the screen rect from the current camera and window on every
   query (zero invalidation), while label, value, selection, disclosure and custom actions are
   plain setters refreshed when the scene or selection changes (user-paced). The element cache
   rebuilds lazily (`needsRebuild` set by the `scene`/`dragModel` `didSet`s).

3. **The element class matches `NSAccessibilityElement`'s own (nonisolated) isolation.** The
   Swift overlay types `NSAccessibilityElement`'s protocol methods nonisolated, so the subclass is
   not `@MainActor`; `@MainActor` state (the camera, the scene) is touched only inside
   `MainActor.assumeIsolated` with values hoisted into locals — exact here because AppKit
   invokes accessibility methods on the main thread only.

4. **Custom actions are handler-based `NSAccessibilityCustomAction`s routed through host
   closures.** The view never mutates the model (SPEC §11.3): each action forwards the node id to
   a host-set closure; `DocumentWindowController` wires them to the existing first-responder
   actions (select the row first, then the same action the keyboard uses), so every VoiceOver
   mutation is exactly one `MapStore` undo step. "Add Sibling" maps to the sibling-above action:
   the below variant of the keyboard action enters edit mode on a single selection (F-EDT-2's ⏎
   rule), while the accessibility action must always create.

5. **All visible nodes are exposed, not just the viewport.** The scene already contains only
   non-folded nodes (folded subtrees are pruned at build time, F-LAY-14). Viewport culling is a
   draw-time optimization; VoiceOver users navigate the whole document semantically, and
   off-screen rows keep correct (screen-space) frames through the live computation above.

## Consequences

- VoiceOver's linear navigation walks the map in outline (creation) order, roots first,
  depth-first within each tree.
- The manual test script (SPEC §14) lives in `docs/accessibility/voiceover-script.md`.
- Increase Contrast / Differentiate Without Color render-side support is a follow-up (the shared
  `SceneRenderer.draw` selection ring is being reworked by the layer-tree slice); selection and
  fold state are already conveyed textually, not by color alone.
