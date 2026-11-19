# VoiceOver manual test script — M1 §14 exit criterion

**Criterion (SPEC §14, Accessibility row):** *VoiceOver can create, navigate, edit and fold a 20-node map.*

Run this by hand on a real Mac (VoiceOver is not automatable in unit
tests; the element contracts it relies on are covered by the headless
`CanvasAccessibilityTests` and the hosted `CanvasAccessibilityTests`).

## Setup

1. System Settings ▸ Accessibility ▸ VoiceOver ▸ **Enable VoiceOver**
   (or press ⌘F5). The VoiceOver cursor and caption panel appear.
2. Build and launch **Arbor**, then File ▸ New (⌘N). A new document
   opens with a centred root already in edit mode.

Useful VoiceOver commands referenced below:

| Keys | Meaning |
|---|---|
| VO = ⌃⌥ (Control-Option) | |
| VO-→ / VO-← | next / previous item |
| VO-⇧-↓ / VO-⇧-↑ | next / previous container content item |
| VO-U | rotor (choose the **Actions** category to reach custom actions) |
| VO-Enter | activate / perform the selected action |
| VO-Arrows inside the rotor | browse the rotor's category |
| ⌘F5 | toggle VoiceOver off |

## 1. Create a 20-node map (5 levels)

The root is already editing:

1. Type **Quarterly Plan**. Expected announcement while typing: the
   overlay text field's text is echoed. Press ⇥ (Tab).
2. Expected: *"Quarterly Plan"* is committed, a new node is created and
   focused — VoiceOver lands in its text field (the focused element is
   the editing `NSTextView`, SPEC §11.6).
3. Type **Goals**, press ⇥ → type **Team**, press ⇥ → type
   **Budget**. Each ⇥ commits and creates a child the same way.
4. Press ⇥ again on **Budget** and continue building breadth + depth
   (or press ⏎ to add siblings) until the map has 20 nodes total,
   e.g. root + 3 branches, each with 4–5 descendants spread over two
   more levels. Every commit/create must move VoiceOver into the new
   node's text field.
5. Press ⎋ to leave edit mode on the last node.

Expected after step 5: the canvas container is focused. VO-⇧-↓ walks
the map's rows in outline order — root first, then each branch
depth-first. Each row announces its label and value, e.g.
*"Goals, 4 children, expanded"*.

## 2. Navigate the hierarchy

1. Focus any row (VO-⇧-↓ until VoiceOver reads a node label).
2. VoiceOver announces hierarchy information from the disclosure
   attributes: a parent with visible children reads like
   *"Team, 2 children, expanded"*; a leaf reads *"leaf"*.
3. Navigate with VO-⇧-↓ / VO-⇧-↑: the cursor walks rows in the order
   shown (outline order, folded subtrees absent).
4. Pan the map with two fingers on the trackpad (or scroll), and zoom
   with ⌘+ / ⌘−: the focused row stays where it is on screen —
   VoiceOver's cursor rectangle follows the node through the camera,
   and re-VO-reading the focused row still highlights the correct
   on-screen node. (Frames are computed live from the camera; see
   `CanvasAccessibilityElement.accessibilityFrame()`.)
5. Click a node with the mouse pointer (VO-click): VoiceOver announces
   the newly selected node — the canvas posts selected-rows-changed /
   focused-changed, so the VoiceOver cursor follows the selection
   without re-querying the whole document.

## 3. Edit a node

1. Walk to a node (e.g. **Budget**).
2. Open the rotor with VO-U, choose the **Actions** category, and
   select **Edit** (VO-Enter). Expected: VoiceOver lands in the node's
   text field — the editing `NSTextView` becomes the focused element
   and announces the node's text.
3. Type **Budget 2027**. Expected: text is echoed in the field.
4. Press ⎋. Expected: one *Edit Text* undo step (Edit ▸ Undo shows one
   action for the whole session, F-DOC-2); VoiceOver returns to the
   row, which now announces *"Budget 2027"*.

## 4. Fold and unfold

1. Walk to **Goals** (announces *"Goals, N children, expanded"*).
2. VO-U → Actions → **Fold** (VO-Enter). Expected: the subtree
   disappears, the row's value becomes *"Goals, N children,
   collapsed"*; the descendants are no longer reachable in the row
   order (F-LAY-14 prunes them from the scene). One undo step.
3. Actions now offer **Unfold** instead of Fold. Perform it: the
   children return and the value reads *"expanded"* again.

## 5. Custom actions summary (each = one undo step through the store)

| Action | Result |
|---|---|
| Add Child | new child under the row's node, selected and editing |
| Add Sibling | new sibling above the row's node, editing |
| Fold / Unfold | toggles the subtree (only offered on nodes with children) |
| Edit | opens the inline text editor on the row's node |

Notes:

- **Add Sibling** inserts *above* the anchor (the "below" keyboard
  action ⏎ enters edit mode instead — F-EDT-2 — so the VoiceOver
  action routes to the creating variant).
- A custom action performed on a row that is not the current selection
  first moves the selection to that row; the action then acts exactly
  as the equivalent keyboard command (same `MapStore` command, one undo
  step).

## 6. Accessibility Inspector audit (optional but recommended)

Open Accessibility Inspector, hover the canvas:

- The canvas view: role **group**, label = the document's display name.
- Each node: role **row** (`AXRow`), label = title (empty nodes read
  **"Empty node"**), value = subtree description, selected state
  tracks the canvas selection, `AXDisclosedByRow` / `AXDisclosedRows`
  link the hierarchy, and `AXCustomActions` lists the actions above.
- Frames are in screen coordinates and track pan/zoom.

## Follow-ups (out of this slice)

- **Increase Contrast / Differentiate Without Color** (SPEC §11.6):
  the cheap render-side piece — a thicker selection ring and
  higher-contrast palette when
  `NSWorkspace.accessibilityDisplayShouldIncreaseContrast` — is a
  follow-up: the selection ring is drawn by the shared
  `SceneRenderer.draw` path, which the concurrent layer-tree/animation
  slice is reworking; folding state and selection are already conveyed
  textually, not by color alone. Branch shapes/patterns for
  Differentiate Without Color land with the theme work (M2).
- **Reduce Motion** matters once the relayout animation slice lands.
- A dedicated **Outline view** (M4) is the fully accessible alternative
  (SPEC §11.6) with standard NSOutlineView semantics.
