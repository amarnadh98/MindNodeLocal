# Arbor: Product & Technical Specification

> **Arbor** is the working name. The bundle ID, document type and app name are centralized (§11.9) so the app can be renamed in one place. We deliberately avoid "MindNode" and other trademarks.
>
> **Status:** v1.0 spec, 2026-11-18
> **Audience:** the implementing coding agent, and later the reviewer
> **Evidence:** [`docs/research/RESEARCH.md`](docs/research/RESEARCH.md)

---

## 0. How to use this document

- Every feature has an ID (`F-<area>-<n>`) and a priority:
  - **P0**: v1.0 cannot ship without it.
  - **P1**: should be in v1.0.
  - **P2**: post-1.0.
- Build in the milestone order of §16. Each milestone has exit criteria; don't start the next milestone until they pass.
- **MUST / SHOULD / MAY** follow RFC 2119.
- When this spec is silent:
  1. Do what macOS's own apps (Keynote, Freeform, Notes) do.
  2. Then do what MindNode does (research §1).
  3. Write the decision down in `docs/decisions/NNNN-title.md`, a lightweight ADR.
- Do **not** copy MindNode's artwork, sticker set, theme files, marketing text or name. Re-implementing behavior and file-format interop is fine.

---

## 1. Vision & principles

**One line.** A beautiful, fast, native Mac mind-mapping app. It does everything MindNode Plus does, plus presenting and studying. It is free, stores your maps as real files, and works fully offline.

**Principles, in priority order when they conflict:**

1. **Native & instant.** AppKit-grade feel: 120 fps pan and zoom, zero-latency typing, standard Mac behaviors (undo, Versions, services, dark mode, Liquid Glass chrome). It must never feel like a web app.
2. **Keyboard-first, mouse-friendly.** You can build a full map without touching the mouse. Every action is also discoverable from menus.
3. **Your files, your Mac.** Maps are documented, Git-friendly packages that live anywhere (iCloud Drive, Dropbox, project folders). No account and no telemetry. Network access happens only for features the user explicitly turns on (BYO-key AI, update checks).
4. **Calm by default, deep on demand.** The empty canvas is clean. Power features (structures, boundaries, study, presentations, filters) are a click away and never clutter a simple map.
5. **Think → Present → Learn.** One map serves three modes. The same reveal engine drives presentation builds and self-testing.
6. **Polish is a feature.** Every structural change animates. Typography and spacing are meticulous. Empty states and onboarding are designed, not defaulted.

---

## 2. Scope

### 2.1 In scope (v1.0)

| Area | Covers |
|---|---|
| Editing | Map editing; multiple layouts and per-branch structures |
| Views | Outline view (side-by-side), Focus/Zen modes |
| Node content | Rich node content: notes, images, stickers/icons, links, LaTeX, code |
| Organizing | Tasks, tags, connections, boundaries, summaries |
| Look | Themes plus a real theme editor |
| Capture | Templates; Quick Entry (menu bar) |
| Finding | Find & replace; filters |
| Library | Library window, cross-map links and backlinks |
| Presenting | Presentation mode |
| Learning | Study mode (flashcards with FSRS, recall reveal, mastery heatmap) |
| Data exchange | Broad import/export |
| Intelligence & automation | On-device AI; local MCP server; Shortcuts/App Intents; Spotlight and Quick Look |
| Tasks | Apple Reminders two-way sync |
| Distribution | Sparkle updates, DMG distribution |

### 2.2 Out of scope (explicit user decision)

- Real-time collaboration, shared documents, comments, presence, and any multi-user feature.
- Apple Watch app.
- iOS/iPadOS/visionOS apps. Mac only for v1. The core packages MUST stay platform-agnostic (no AppKit in `MapCore`, `MapLayout` or `MapIO`) so an iPad app stays possible later.
- Accounts, a cloud backend, a web app, Windows/Linux.
- App Store distribution. The design should not preclude it: sandbox stays on.

### 2.3 Non-goals

- Becoming a general whiteboard (Freeform/Miro) or a full PKM (Obsidian). Free-form notes exist, but the tree is the hero.
- Gantt and project management. Tasks stay lightweight.

---

## 3. Users & core jobs

| Persona | Jobs to be done |
|---|---|
| **Thinker** (primary: the owner) | Brainstorm fast; restructure ideas by dragging; capture a thought from anywhere (Quick Entry) |
| **Learner** | Map a topic or course; attach sources (PDF page, video timestamp); turn branches into flashcards; see what they've forgotten |
| **Presenter** | Walk an audience through a map branch by branch, with notes on a second display; export a PDF handout |
| **Planner** | Break a project into tasks with progress rings; sync open tasks to Reminders |
| **Friend** (secondary) | Install a DMG, open the app, understand it in 2 minutes with no manual |

**Golden-path scenarios.** These are tested end-to-end in §14.

1. Launch → New map → type root → ⇥ child ×3 → ⏎ siblings → drag a branch to reparent → ⌘S to iCloud Drive → quit → reopen: everything is restored, including zoom and scroll.
2. Paste a 40-line indented Markdown list → it becomes a map → switch to Radial → apply a theme → export a PDF.
3. Select a branch → *Study Branch* → review 10 cards → the map shows mastery colors.
4. *Present* → auto-generated slides → advance with arrow keys and a clicker → presenter notes appear on the second display.
5. Press the global hotkey → Quick Entry → type an indented list → "Create Map".

---

## 4. Information architecture

```
Arbor.app
├── Library window (one; optional, ⇧⌘L)
│   ├── Sidebar: Recents · Favorites · Folders (watched locations) · Tags · Study Due · Templates
│   ├── Grid/List of maps (live thumbnails), search field, sort, new-from-template
│   └── Concept Index (global node search & backlinks across library)
├── Document window (one per map)
│   ├── Toolbar (Liquid Glass, customizable)
│   ├── Optional left sidebar: Outline (side-by-side) | Slides | Study panel
│   ├── Canvas (map) — or full-width Outline (⌘2)
│   ├── Floating contextual bar (near selection)
│   ├── Optional right Inspector: Style · Layout · Theme · Canvas · Node (notes/links/fields) · Document
│   └── Optional Notes sidebar (persistent note editor for selection)
├── Presenter (full screen on audience display + Presenter view on main display)
├── Study session window (sheet or full screen)
├── Quick Entry panel (menu-bar extra + global hotkey)
├── Settings (General · Editing · Appearance · Themes · AI · Shortcuts · Study · Integrations · Updates · Advanced)
└── Onboarding (first launch: 3-step welcome + sample maps)
```

### 4.1 Document window layout (default)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [Map|Outline]  Title ▾     ＋  🖼  ☐  📝  ⟿  ◎  ▶︎  ⋯   🔍  ▣  ⓘ │ toolbar
├──────────────┬─────────────────────────────────────────────┬─────────────┤
│ (Outline /   │                                             │ Inspector   │
│  Slides /    │            ∞ canvas                         │  Style      │
│  Study)      │       ┌──────┐                              │  Layout     │
│  hidden by   │   ────│ Root │────                          │  Theme      │
│  default     │       └──────┘                              │  …          │
│              │                       [contextual bar]      │ hidden by   │
│              │                                  ▢ minimap  │ default     │
├──────────────┴─────────────────────────────────────────────┴─────────────┤
│ status: zoom 100% · 42 nodes · 3/7 tasks · filter: #exam  (auto-hides)   │
└──────────────────────────────────────────────────────────────────────────┘
```

Toolbar items, in default order:

1. View switcher (Map/Outline)
2. Document title with a rename/move popover (standard NSDocument)
3. Add Node
4. Media (sticker/emoji/image/SF Symbol)
5. Task
6. Note
7. Connection
8. Focus
9. Present ▶︎
10. More (⋯: Study, Boundary, Summary, Export)
11. Search
12. Sidebar toggles

The toolbar MUST be customizable (`NSToolbar` allowsUserCustomization).

---

## 5. Feature specification

### 5.1 Canvas & navigation (`F-CAN`)

| ID | Pri | Requirement |
|---|---|---|
| F-CAN-1 | P0 | Infinite canvas. Two-finger trackpad scroll pans with native inertia and rubber-banding at nothing (no bounds). Space-drag or middle-drag pans with a mouse. |
| F-CAN-2 | P0 | Zoom 10%–400%. Pinch zooms around the cursor; ⌘+/⌘− step through 25/50/75/100/125/150/200/300/400; ⌘0 = 100%; ⌘9 = zoom to fit (also ⌘*); ⌥⌘0 = zoom to selection. Pinch snaps softly at 100% with a haptic tick (`NSHapticFeedbackManager`). |
| F-CAN-3 | P0 | New document: the root node sits centered and is already in text-edit mode with placeholder "Central Idea". |
| F-CAN-4 | P0 | Selection: click; ⇧/⌘-click to add or toggle; rubber-band drag on empty canvas; ⌘A all; ⌥⌘A children; ⌘R the current root. Arrow keys move selection **spatially**: on the left side of a balanced map, ← goes to the child and → to the parent. |
| F-CAN-5 | P0 | Double-click empty canvas creates a **floating node** (a new root) at that point and enters edit mode. Scapple-style. |
| F-CAN-6 | P1 | Minimap, bottom-right. Shows the viewport rect; drag to pan. Toggle with ⌥⌘M. Auto-hides when the whole map fits. |
| F-CAN-7 | P1 | ⌘J jumps to the selection (centers it). After any keyboard navigation off-screen, the camera follows smoothly (scroll-into-view with 40 pt margin). |
| F-CAN-8 | P0 | Per-document view state (zoom, scroll, selection, folded nodes, active view) is restored on reopen. |
| F-CAN-9 | P2 | Optional dot grid background (theme-controlled), off by default. |

### 5.2 Node creation & editing (`F-EDT`)

| ID | Pri | Requirement |
|---|---|---|
| F-EDT-1 | P0 | ⇥ adds a child, ⏎ a sibling below, ⌥⏎ a sibling above, ⌥⇥ a new parent (inserted between node and parent), ⇧⏎ a new root. The new node is selected and in edit mode. While editing, ⇥/⏎ commit and create (same semantics). ⇧⏎ inside text inserts a line break. ⌘⏎ or Esc commits; Esc again deselects. |
| F-EDT-2 | P0 | ⏎ on a selected (not editing) node, ⌘⏎, F2, or double-click enters edit mode with all text selected. Typing any printable character on a selected node replaces its text, like a spreadsheet. Setting "Typing replaces text": on. |
| F-EDT-3 | P0 | **Node Well**: hovering a node shows a small "+" at its outer edge. Click adds a child; drag places a new child where dropped (or a new root if dropped on empty space). ⌥-hover on a parent shows the fold chevron instead. |
| F-EDT-4 | P0 | ⌫/⌦ deletes the selected nodes and their subtrees; ⌥⌫ deletes the node only and promotes its children. Animated. Undoable. |
| F-EDT-5 | P0 | **Drag to reparent.** Drag a node and its subtree: (a) a translucent ghost follows the cursor; (b) hovering a node highlights it as the drop parent, and a shadow placeholder shows where it will land among siblings; (c) hovering between siblings shows an insertion line. Modifiers during drag: **⌥** free-positions (keeps the parent, sets a manual offset); **D** detaches into a new root; **Space** drops as a *connection* to the target instead of reparenting; **⌘** keeps the node's own style (default: adopt the new branch's color). |
| F-EDT-6 | P0 | ⌘↑/⌘↓ reorder among siblings; ⌘← promotes one level (outdent); ⌘→ demotes (becomes the last child of the previous sibling). Mirrored on the left side. |
| F-EDT-7 | P0 | Rich text titles: bold, italic, underline, strikethrough, inline code, text color, highlight, link, font family and size per run. Standard ⌘B/⌘I/⌘U and the Format menu. Multi-line titles. Text attributes are restricted to an allow-list so Markdown/OPML round-trip (see §8.3). |
| F-EDT-8 | P0 | Auto-width: a node grows with text up to **max width** (theme default 280 pt, configurable per node), then wraps. Users can drag the node's right edge to set a fixed width; double-click the handle to reset. |
| F-EDT-9 | P0 | Copy/cut/paste nodes (internal UTI plus plain text, Markdown and OPML on the pasteboard). Pasting text with indentation, Markdown lists/headings or OPML creates a hierarchy under the selection. ⇧⌥⌘V pastes and keeps source style; plain paste adopts the target style. ⌥⌘C/⌥⌘V copy/paste **style**. ⌘D duplicates a subtree. |
| F-EDT-10 | P0 | **Smart typing** (settings toggle, on by default): `#tag` at the end of a title becomes a tag; `[ ] ` or `-[] ` prefix makes a task; `[x] ` makes a completed task; `--` on its own line inside the editor starts the node's note; `$$…$$` makes a LaTeX node; `` ``` `` starts a code block. |
| F-EDT-11 | P1 | Balance map (⌥⌘B) redistributes root children between left and right. Sort children (alphabetical, by task state, by tag, by due date, by mastery). Reset position (⌃⌘R) clears manual offsets. |
| F-EDT-12 | P1 | Multi-selection editing: style changes, tagging, tasks and deletion apply to all selected nodes. |
| F-EDT-13 | P1 | Auto-numbering per branch (1, 1.1, 1.1.1 / A, B / i, ii), set as a branch style option. |
| F-EDT-14 | P0 | Untitled documents are auto-named from the root's text on first save (like MindNode). |
| F-EDT-15 | P0 | Spell check, autocorrect, Writing Tools, dictation, emoji picker (⌃⌘Space) and correct IME behavior (CJK). ⏎ during IME composition MUST NOT create a sibling (a known MindNode bug). |

### 5.3 Layouts & structures (`F-LAY`)

Every root and every node MAY set a **structure** that applies to its subtree. Structure is inherited until overridden (XMind-style mixing).

| ID | Pri | Structure | Notes |
|---|---|---|---|
| F-LAY-1 | P0 | **Mind map, balanced** | Default. Root children are split left and right to balance height. A child can be pinned to a side. |
| F-LAY-2 | P0 | **Mind map, right** / **left** | One-sided horizontal. |
| F-LAY-3 | P0 | **Org chart (down)** / **up** | Vertical tidy tree. |
| F-LAY-4 | P0 | **Logic chart (right)** | Children to the right, aligned at the left. Compact, like a horizontal outline. |
| F-LAY-5 | P1 | **Radial** | Root children spread evenly around 360°, sized by subtree weight; deeper levels fan outward. |
| F-LAY-6 | P1 | **Tree / list (indented)** | Vertical file-tree style with elbow connectors. Good for outlines on canvas. |
| F-LAY-7 | P1 | **Timeline (horizontal)** | Children on a spine with alternating above/below placement; grandchildren stack. |
| F-LAY-8 | P1 | **Fishbone (left/right)** | Head = root; ribs at ±60° alternate; grandchildren are horizontal bones. |
| F-LAY-9 | P2 | **Brace map** | Curly brace from parent to the children's extent. |
| F-LAY-10 | P2 | **Matrix / tree table** | Children are columns; grandchildren are rows. |
| F-LAY-11 | P0 | **Flexible positioning** | A node dragged with ⌥ (or dragged far from its slot when "Snap to layout" is off) stores a manual offset relative to its auto slot. Its subtree still auto-lays out relative to it. A small indicator dot on the branch marks manually placed nodes. During a drag, a ghost shows the snap target; releasing within 24 pt snaps back. |
| F-LAY-12 | P0 | **Spacing** | Narrow, Default and Wide presets, plus custom sibling gap and level gap in the inspector. |
| F-LAY-13 | P0 | **Animation** | Every relayout animates (§7.6). |
| F-LAY-14 | P0 | **Folding** | ⌥. folds/unfolds the selection. ⌥⌘. folds the selection and its siblings. ⌃⌥. unfolds one level. View ▸ Show Levels ▸ 1–5 / All (⌃1…⌃5, ⌃0). A folded node shows a pill with its hidden-descendant count (e.g. "12"); click it to unfold. |
| F-LAY-15 | P0 | **Branch line styles** | Curved (default), tapered curved, straight, angular/elbow (with rounded corners), and none. Thickness 1–12 pt, with taper amount. |

### 5.4 Node content (`F-CNT`)

| ID | Pri | Requirement |
|---|---|---|
| F-CNT-1 | P0 | **Notes.** Each node has a Markdown-backed rich note (headings, lists, checkboxes, quotes, code, tables, links, images, LaTeX). Open with ⇧⌘K or the toolbar: a popover anchored to the node, which can be detached to a floating window. Settings or the toolbar can switch to a **persistent Notes sidebar** that follows the selection. A note icon (≡) shows on nodes that have one. Hovering the icon shows a 3-line preview. |
| F-CNT-2 | P0 | **Images.** Drag, paste, or Media ▸ Image. The image sits above, below, left or right of the title (inspector). Resizable with corner handles, aspect locked (⇧ to unlock). Space opens Quick Look. Stored content-addressed in `assets/`. Large images are downscaled on import to ≤ 2048 px on the long edge (setting). |
| F-CNT-3 | P0 | **Icons and stickers.** The Media picker has tabs for **SF Symbols** (searchable, tintable), **Emoji**, and the **Arbor sticker set**: ~120 original vector stickers we create (arrows, priority 1–5, progress quarters, flags, stars, faces, check/x/question, plus learning markers like 💡 idea, ❓ question, ⚠️ pitfall, 📌 key, 🔁 review). Multiple markers per node render as a row before the text. Clicking a priority/progress marker cycles it. |
| F-CNT-4 | P0 | **Links.** ⌘K attaches a URL (web, file, `x-arbor://` node/document link). ⌥⌘K or clicking the link badge opens it. Links to another map or node show a hover **preview card** (thumbnail plus title). |
| F-CNT-5 | P1 | **LaTeX.** A node title or note block can be LaTeX math (`$…$` inline, `$$…$$` block). Rendered natively via **SwiftMath** (MIT, Core Graphics-based) so it exports as vector. Editing shows the source; committing renders it. |
| F-CNT-6 | P1 | **Code blocks** in notes and as node content, with syntax highlighting (a tree-sitter-free approach: **Splash**-style tokenizer or `HighlightSwift`). Monospace and theme-aware. |
| F-CNT-7 | P1 | **Attachments.** Any file can be attached (stored in `assets/`, opened with its default app). PDF attachments can anchor to a **page**: link format `asset.pdf#page=12` opens in the built-in PDF viewer sheet (PDFKit) at that page. |
| F-CNT-8 | P1 | **Source anchors.** A node can carry a `source` (URL plus optional timestamp or page plus quoted excerpt). Shown as a small citation chip; YouTube/Vimeo URLs with `t=` open at that time. |
| F-CNT-9 | P2 | **Custom fields** (typed key/value: text, number, date, select, URL) per node, shown in the inspector and optionally under the title. Usable in filters, sort and conditional styles. |
| F-CNT-10 | P2 | **Node types** (Tana-like, lightweight): built-in *Concept, Definition, Example, Question, Quote, Task, Idea*, plus user-defined types. Each type has a default style, default fields and study behavior. |

### 5.5 Relationships & grouping (`F-REL`)

| ID | Pri | Requirement |
|---|---|---|
| F-REL-1 | P0 | **Connections** (cross-links): ⌘L then click the target, or ⇧-drag from node to node, or Space during a node drag. Rendered as a curved Bézier with one draggable **midpoint handle** (double-click to reset). Options: label (inline editable, sits on the curve), color, width, dash, arrowheads (none/start/end/both), curve/straight. Connections are selectable and deletable. ⌃⌘L / ⇧⌘L jump to the start/end node. |
| F-REL-2 | P1 | **Boundaries.** Select siblings (or one node for its subtree) → ⌥⌘G "Add Boundary". Draws a rounded or organic outline around the nodes' combined frame with padding, optional title tab, fill (10% tint) and dashed/solid stroke. It follows layout automatically. |
| F-REL-3 | P1 | **Summaries.** Select consecutive siblings → ⇧⌘] "Add Summary". Draws a brace to the right (or below) of the range and a summary node beyond it. The summary node is a real node (it can have children) attached to the range. Summary nodes are first-class flashcard candidates ("key takeaway"). |
| F-REL-4 | P2 | **Callouts.** A floating comment bubble attached to a node, not part of the hierarchy. Hidden in presentations unless enabled. |
| F-REL-5 | P1 | **Cross-map links & backlinks.** Any node can link to a node in another map (`x-arbor://open?doc=<docID>&node=<nodeID>`). The inspector "Linked From" section lists backlinks from the library index (§5.12). Copy Node Link: ⌃⌘C. |

### 5.6 Tasks (`F-TSK`)

| ID | Pri | Requirement |
|---|---|---|
| F-TSK-1 | P0 | ⇧⌘T toggles "is task" (a checkbox before the title). ⌃⌘T or clicking the checkbox completes it. A completed task gets a strikethrough plus 50% opacity (theme-controlled). |
| F-TSK-2 | P0 | A parent with task descendants shows a **progress ring** instead of a checkbox (pie filled to the completed/total ratio of leaf tasks). Hovering shows "7 of 12 · 58%". Clicking completes all; ⌥-click reopens all. |
| F-TSK-3 | P1 | Optional due date, priority (1–3) and repeat rule (daily/weekly/monthly/custom) per task (inspector). Overdue tasks show a red date chip. |
| F-TSK-4 | P1 | **Apple Reminders two-way sync** (EventKit), per document, opt-in. Each document maps to a Reminders list (created or chosen). Title, notes, due date, priority, completion and URL deep link sync both ways. Reminders created in that list appear as children of a configurable "Inbox" node. Conflicts resolve last-writer-wins by modification date. Shows sync status. |
| F-TSK-5 | P1 | Highlight Tasks mode (dims non-task nodes). Filter: open tasks only. Outline: open-tasks filter. |
| F-TSK-6 | P2 | Export tasks to Things (URL scheme JSON), OmniFocus (TaskPaper paste) and TaskPaper file. |

### 5.7 Tags, filters & conditional styling (`F-TAG`)

| ID | Pri | Requirement |
|---|---|---|
| F-TAG-1 | P0 | Tags are document-scoped `{id, name, color}`, shown as small colored pills under the title (toggleable). Assign via `#tag` smart typing, the inspector token field, or the ⌥⌘T tag popover (type-ahead, create new). |
| F-TAG-2 | P0 | **Highlight mode**: pick one or more tags; matching nodes stay full opacity, everything else dims to 25%. Esc exits. |
| F-TAG-3 | P1 | **Filter bar** (⇧⌥⌘F): combine tags, task state, has-note, has-image, node type, mastery level, due date and text. Modes: dim, or hide non-matching (ancestors of matches stay visible). Saved filters per document. |
| F-TAG-4 | P2 | **Conditional styles**: rules like "if tag = #exam → fill red", "if mastery < 0.5 → orange outline", "if task overdue → red". Evaluated live; non-destructive (they overlay node style). |

### 5.8 Styling & themes (`F-STY`)

| ID | Pri | Requirement |
|---|---|---|
| F-STY-1 | P0 | **Node shapes**: Rounded rect (default), Pill, Rectangle, Circle, Square, Hexagon, Octagon, Cloud, Diamond, **Underline** (text on a line that continues the branch), **None** (text only). |
| F-STY-2 | P0 | **Per-node style**: fill (color/none), border (width, color, dash), corner radius, padding, shadow (none/soft/raised), text (font, size, weight, color, alignment), branch (color, width, taper, line style), min/max/fixed width, image placement. Inspector ▸ Style is context-aware: node / text / branch / connection / boundary. |
| F-STY-3 | P0 | **Style inheritance**: theme → level style (root, level 1, level 2, level 3+) → branch color (from the level-1 ancestor's palette index) → per-node overrides. The inspector shows overridden properties with a dot and a "Reset to theme" button. |
| F-STY-4 | P0 | **Themes**: ≥ 12 built-in, all **dynamic** (light and dark variants). Each theme defines canvas color, palette (8–12 branch colors), level styles, connection style, boundary style, fonts, and task/tag appearance. One-click apply from Inspector ▸ Theme (live preview on hover). |
| F-STY-5 | P0 | **Theme editor** (a direct editor, not MindNode's "extract from sample"): a sheet with a live preview map on the left and all theme properties on the right, grouped (Canvas, Palette, Root, Level 1, Level 2, Level 3+, Connections, Boundaries, Typography). Also *New Theme from Current Map* (extract). Themes are saved as `.arbortheme` JSON files in `~/Library/Application Support/Arbor/Themes` and can be imported/exported (double-click to install). |
| F-STY-6 | P0 | Set a default theme for new documents. Per-document *Appearance: Auto / Light / Dark* override. |
| F-STY-7 | P1 | Color palettes in pickers: the theme palette first, then recent colors, then the system color panel. |
| F-STY-8 | P1 | **Rainbow branches**: each level-1 branch takes the next palette color and descendants inherit it (toggle in the theme). Recolor Branches action. |

**Built-in themes** (names are ours):
1. Paper (default)
2. Graphite
3. Pastel
4. Ocean
5. Forest
6. Sunset
7. Mono Ink
8. Chalkboard (dark-first)
9. Neon (dark-first)
10. Blueprint
11. Sakura
12. Study (high contrast, built for learning maps)

Visual definitions are in §7.

### 5.9 Outline view (`F-OUT`)

| ID | Pri | Requirement |
|---|---|---|
| F-OUT-1 | P0 | ⌘1 shows the Map, ⌘2 the Outline (full width). ⌘3 shows **Side by side** (outline as the left sidebar, map on the right; both live and selection synced). |
| F-OUT-2 | P0 | Outline rows: disclosure triangle, indent guides, task checkbox/progress, title (bold/italic preserved), trailing indicators (note, image, link, tags, mastery dot). Roots appear as top-level sections in creation order (reorderable). First-level order follows the map's clockwise visual order. |
| F-OUT-3 | P0 | Keyboard: ⏎ new row (splits text at the caret), ⌫ at the start merges with the previous row, ⇥/⇧⇥ indent/outdent, ⌘↑/⌘↓ move, ⌥⌘←/→ fold/unfold, Esc toggles between text editing and row selection, arrow keys navigate. |
| F-OUT-4 | P0 | Drag and drop rows (vertical = reorder, horizontal offset = depth). Drop images, files and text into rows. |
| F-OUT-5 | P1 | Options: show notes inline (expandable), show tags, show images, open-tasks-only, numbering. |
| F-OUT-6 | P0 | Implemented with `NSOutlineView` (performance, accessibility, type-select), bound to the same `MapDocument` model and command layer. |

### 5.10 Focus, Zen & search (`F-FOC`)

| ID | Pri | Requirement |
|---|---|---|
| F-FOC-1 | P0 | **Focus Mode** (⇧⌘F): dims everything except the selected node's subtree and its ancestor path to 15% opacity, and smoothly zooms to fit it. Navigation inside focus moves the focus. Esc exits. |
| F-FOC-2 | P1 | **Zen Mode** (⌃⌘F): full screen, hides all chrome (toolbar, sidebars, minimap) and dims everything except the current branch. Optional **brainstorm timer** (5/10/15/25 min, subtle ring in the corner, soft chime at the end). |
| F-FOC-3 | P0 | **Find** (⌘F): the standard find bar (NSTextFinder-style) searches titles, notes and (toggle) tags. Matches highlight on the canvas; ⌘G/⇧⌘G move through them with camera follow; folded ancestors auto-expand temporarily. ⌥⌘F finds and replaces (titles and notes). ⌘E uses the selection for find. |
| F-FOC-4 | P1 | **Quick Open / Command Palette** (⌘P / ⇧⌘P): fuzzy-jump to any node in the document, any map in the library, or any menu command. |

### 5.11 Quick Entry (`F-QEN`)

| ID | Pri | Requirement |
|---|---|---|
| F-QEN-1 | P1 | A menu-bar extra (toggleable) plus a global hotkey (default ⌃⌥Space, configurable; uses `KeyboardShortcuts` package-style Carbon registration). Opens a floating Liquid Glass panel with an outline-style editor (⏎ new line, ⇥ indent). |
| F-QEN-2 | P1 | Actions: **Create Map** (new document, first line = root); **Add to…** (pick a recent map and node; appended as children); **Append to Inbox map** (a designated inbox document). Smart typing works here. |
| F-QEN-3 | P2 | Clipboard and selected text from the frontmost app can be pulled in with one click ("Paste as outline"). |

### 5.12 Library (`F-LIB`)

| ID | Pri | Requirement |
|---|---|---|
| F-LIB-1 | P0 | Maps are ordinary files (`.arbor` packages) anywhere on disk. The Library window shows **Recents** (NSDocumentController) and **watched folders** the user adds (default suggestion: `~/Library/Mobile Documents/com~apple~CloudDocs/Arbor` if iCloud Drive is enabled, else `~/Documents/Arbor`). Access is persisted through security-scoped bookmarks. |
| F-LIB-2 | P0 | Grid view with live thumbnails (read from `QuickLook/Thumbnail.png` in each package), title, modified date. List view with columns. Sort, search (filename and full text via the index), favorite (star), and Finder tags shown. New Map, New from Template, Open, Reveal in Finder, Duplicate, Move to Trash (system Trash, so it is recoverable). |
| F-LIB-3 | P1 | **Library index**: a disposable SQLite (GRDB) or SwiftData store in Application Support that indexes node text, tags, links, and study state across watched folders. Updated on save plus a background `NSMetadataQuery`/FSEvents watcher. Powers the Concept Index, backlinks, "Study Due" and global search. Fully rebuildable ("Rebuild Index" in Advanced). |
| F-LIB-4 | P1 | **Concept Index**: a searchable list of every node title across maps, grouped by normalized text. It reveals the same concept in different maps and offers "Link these". |
| F-LIB-5 | P0 | **Templates**: ≥ 10 built-in templates (Brainstorm, Project Plan, Meeting Notes, Book Summary, Lecture Notes, Concept Study, SWOT, Decision Matrix, Weekly Review, OKRs, Fishbone RCA, Timeline). Save any map as a template. Templates live in Application Support/Templates as `.arbor` packages. |

### 5.13 Presentation mode (`F-PRE`)

One engine, two authoring models. It shares the **Reveal Engine** with Study (§5.14).

| ID | Pri | Requirement |
|---|---|---|
| F-PRE-1 | P1 | **Auto Presentation** (▶︎ / ⌥⌘⏎): slides are generated from the tree. Slide 1 = the whole map overview. Then, for each level-1 branch in clockwise order: a slide focusing that branch (others ghosted at 15%), optionally a sub-slide per level-2 child if the branch has > N nodes (setting). Final slide = overview again. The camera animates between slides (smooth zoom/pan, 600 ms ease-in-out). |
| F-PRE-2 | P1 | **Authored slides**: a *Slides* sidebar. "Add Slide" captures the current **camera rect**, the **fold state**, the **focus set** (nodes fully visible; the rest dimmed or hidden per slide option), and the **build steps**. Slides can be reordered, duplicated, renamed and given speaker notes. A map can hold multiple presentations. |
| F-PRE-3 | P1 | **Builds**: within a slide, children can reveal one at a time (per-slide option "Reveal children one by one", or a custom build order chosen by clicking nodes in sequence). Reveal animation: fade and slide from the parent (250 ms). |
| F-PRE-4 | P1 | **Presenting**: full screen on the selected display. →/Space/⏎/PageDown/click = next build or slide; ←/PageUp = back; Home/End; number + ⏎ jumps to a slide; B/W blacks/whites the screen; Esc exits. Supports Bluetooth presentation clickers (they send these keys). |
| F-PRE-5 | P1 | **Presenter view** on the second display: current slide, next slide, speaker notes (the node note of the focused node, or slide notes), elapsed timer, clock, slide counter, mini-map with position. With one display, toggle with ⌥P. |
| F-PRE-6 | P1 | **Live edit**: E pauses the presentation into editing at the current camera; ⌘⏎ resumes. |
| F-PRE-7 | P1 | Laser pointer (hold L): a soft red dot follows the mouse. Spotlight (hold S): a circular spotlight follows the mouse. |
| F-PRE-8 | P2 | Export the presentation to PDF (one page per slide or build step, with optional notes pages) and **PPTX** (each slide as a full-bleed vector-ish PDF-rendered image plus notes; hand-written OOXML writer, no dependency). |

### 5.14 Study mode (`F-STD`): our differentiator

**Concept.** One object, many views. A node *is* a flashcard. There is no separate card database: card scheduling state is stored on the node in the document file, so it travels with the map. The library index aggregates "due" across maps.

| ID | Pri | Requirement |
|---|---|---|
| F-STD-1 | P1 | **Card generation rules** (per document; defaults shown). A node becomes a card if it is inside a branch marked **Study** (Branch ▸ "Make Study Deck", ⌥⌘S), and it has children or a note. **Front** = the node title plus its ancestor path as breadcrumb context ("Biology › Cell › Mitochondria"). **Back** = children titles (as a list, in map order) plus note. Leaf nodes without a note are not cards by default. Users can explicitly mark any node "Card" / "Not a card". |
| F-STD-2 | P1 | **Card types**: *Basic* (front/back as above); *Reversed* (optional, also back → front); **Cloze**: any text wrapped in `{{c1::…}}` (or selected text → ⌘⇧C "Make Cloze") in a title or note becomes a cloze card, rendered as `[…]`; **Summary card** (from F-REL-3: the range of siblings is the prompt, the summary is the answer, and vice versa); P2: **Image occlusion** (draw rectangles over an attached image; each becomes a card). |
| F-STD-3 | P1 | **Scheduler: FSRS-5/6** (open algorithm; port the reference `fsrs-rs`/`ts-fsrs` logic to Swift as `MapStudy` package). Grades: Again / Hard / Good / Easy (keys 1–4, Space = Good). Supports learning and relearning steps (defaults 1 m, 10 m), desired retention (default 0.9), max interval, optional fuzz. Per-card state: `{due, stability, difficulty, elapsedDays, scheduledDays, reps, lapses, state(new/learning/review/relearning), lastReview}` plus a review log. |
| F-STD-4 | P1 | **Study session UI**: a sheet or full-screen window with a card centered in the map's theme typography, the breadcrumb above, and "Show Answer" (Space). On reveal, the answer children **animate in one by one** (the Reveal Engine), and the mini-map in the corner highlights where this card lives. Grading buttons show the next interval ("Good · 4d"). Session summary at the end (cards reviewed, accuracy, time, streak). Daily new-card limit (default 20) and review limit (default 200). |
| F-STD-5 | P1 | **Recall mode on the canvas** (no cards, spatial): select a branch → *Recall* (⌥⌘R). All descendants hide behind blurred placeholders with their outlines visible. Click a placeholder or press → to reveal one at a time; ⌥-click reveals the whole subtree. Mark each revealed node ✓ remembered / ✗ forgot (keys 1/2), which feeds FSRS as Good/Again for that node's card if it is one. |
| F-STD-6 | P1 | **Mastery heatmap**: View ▸ Mastery Overlay (⌥⌘H) tints each card node by retrievability R (FSRS): ≥ 0.9 green, 0.7–0.9 yellow, 0.5–0.7 orange, < 0.5 red, new = gray outline. Parents show the aggregate as a small ring. "Study Weakest Branch" starts a session on the subtree with the lowest mean R. |
| F-STD-7 | P1 | **Study dashboard** (Library ▸ Study Due): cards due today per map and per deck, a 30-day forecast chart (Swift Charts), retention stats, streak, a heatmap calendar. Optional daily reminder notification (UserNotifications, local). |
| F-STD-8 | P2 | **AI study helpers** (if AI is enabled): generate cloze/Q&A cards from a node's note; generate a quiz (multiple choice) from a branch; "Explain this node simply"; "What's missing from this branch?". Generated cards are inserted as normal nodes/clozes (undoable, one group). |
| F-STD-9 | P2 | Import/export Anki (`.apkg` export of the deck with Basic/Cloze note types; CSV import of front/back). |

### 5.15 AI assistant (`F-AI`), optional and off-device only by explicit opt-in

| ID | Pri | Requirement |
|---|---|---|
| F-AI-1 | P1 | **Backend abstraction** `AIProvider` protocol with: (1) **Apple on-device** (Foundation Models, `SystemLanguageModel.default`), the default when `availability == .available`; (2) **Anthropic API** (user key in Keychain; default model `claude-sonnet-5-5`, configurable); (3) **OpenAI-compatible endpoint** (covers Ollama/LM Studio locally). On macOS 27 the Apple `LanguageModel` protocol MAY be adopted to unify these. If no provider is available, AI UI is hidden. Settings ▸ AI shows the provider, a privacy notice ("map text is sent to <provider>") for cloud providers, and a master off switch. |
| F-AI-2 | P1 | **Expand node** (⌘. like Whimsical): suggest 5–8 child ideas for the selected node, given its ancestor path and siblings. Suggestions appear as **ghost nodes** (dashed, 50% opacity). ⇥ accepts all, click accepts one, Esc dismisses, ⌘. again regenerates. Streams in. |
| F-AI-3 | P1 | **Generate map from…**: a prompt/topic, pasted text, a URL (fetched only with a cloud provider or explicit consent), a PDF, or an image (macOS 27 image attachments / cloud vision). Generates level by level to respect small context windows (flat `@Generable` list `{text, parentIndex}`). |
| F-AI-4 | P2 | **Summarize branch → note**, **Map → article/Markdown outline**, **Rewrite titles concisely**, **Suggest title for document**, **Learning goal → curriculum map** (with prerequisite connections). |
| F-AI-5 | P1 | Every AI mutation is a single undo group and is marked in the document history metadata (`lastModifiedBy: "ai"`). |

### 5.16 Automation & system integration (`F-INT`)

| ID | Pri | Requirement |
|---|---|---|
| F-INT-1 | P1 | **App Intents / Shortcuts**: Create Map (from text/outline), Open Map, Find Maps, Add Node (to doc and parent node), Find Nodes (title/tag/task state), Get Node, Set Node Title/Note, Toggle Task, Export Map (format), Get Due Cards Count, Start Study Session. Expose entities `MapEntity`, `NodeEntity` for Spotlight/Siri. |
| F-INT-2 | P1 | **Spotlight importer** (Core Spotlight `CSImportExtension`): indexes the title and all node text and notes so Finder/Spotlight find maps by content. |
| F-INT-3 | P0 | **Quick Look**: the package always contains `QuickLook/Thumbnail.png` (512 px) and `QuickLook/Preview.pdf` written on save, plus a `QLThumbnailProvider`/`QLPreviewingController` extension (P1) for high-fidelity previews. |
| F-INT-4 | P1 | **Local MCP server** (stdio, bundled helper binary `arbor-mcp` exposed via Settings ▸ Integrations with "Copy config for Claude Desktop/Code"). Read-only by default; a toggle allows edits. Tools: `list_maps`, `read_map` (as outline JSON/Markdown), `search_nodes`, `add_nodes`, `update_node`, `move_node`, `create_map`, `get_due_cards`. Edits go through the same command layer and are marked `lastModifiedBy: "mcp"`. Communicates with the running app via XPC or a Unix socket; works on files directly if the app is closed (with file coordination). |
| F-INT-5 | P1 | **URL scheme** `x-arbor://`: `open?doc=&node=`, `new?title=&outline=`, `add?doc=&parent=&text=`, `study?doc=`. |
| F-INT-6 | P1 | **Services menu**: "New Arbor Map from Selection", "Add Selection to Arbor Inbox". **Share extension**: send text/URL/image to Arbor (Inbox or new map). |
| F-INT-7 | P2 | Desktop widgets (WidgetKit): Recent maps; Cards due; Quick capture button. Control Center control: New brainstorm. |
| F-INT-8 | P2 | AppleScript dictionary (basic: documents, nodes, title, note, children, make, delete). |
| F-INT-9 | P0 | Standard: Services, Print (⌘P with options: fit to page / tile across pages / outline print; header/footer), Versions browser, Handoff not needed. |

### 5.17 Import / export (`F-IO`)

| Format | Import | Export | Pri | Notes |
|---|---|---|---|---|
| Arbor `.arbor` | ✓ | ✓ | P0 | Native (§8) |
| OPML 2.0 | ✓ | ✓ | P0 | `_note` attribute for notes; custom `arbor:` namespaced attrs for task/tags so round-trip is lossless |
| Markdown (`.md`) | ✓ | ✓ | P0 | Headings + nested lists; notes as indented paragraphs; tasks as `- [ ]`; options: headings depth |
| Plain text (indented) | ✓ | ✓ | P0 | Tabs or 2/4 spaces auto-detected |
| PDF | – | ✓ | P0 | Vector via shared renderer; options: whole map / selection / outline PDF; background on/off; PDF outline (bookmarks) mirrors the tree |
| PNG / JPEG / HEIC | – | ✓ | P0 | 1×/2×/3×, transparent background option, max 16k px with tiling |
| SVG | – | ✓ | P1 | Hand-written emitter; text as `<text>` (option: outlines) |
| FreeMind / Freeplane `.mm` | ✓ | ✓ | P1 | Rich text via `richcontent` |
| XMind `.xmind` | ✓ | P2 | P1 | Zip (ZIPFoundation); `content.json` (2020+) and `content.xml` (Xmind 8); sheets → roots; relationships → connections; boundaries/summaries mapped |
| MindNode `.mindnode` | ✓ | – | P1 | Package; `contents.xml` is a binary plist v9; best effort (titles, notes, structure, tasks, tags, connections, images); documented fallback: "export OPML from MindNode" |
| iThoughts `.itmz` | ✓ | – | P2 | Zip + XML |
| TextBundle / TextPack | ✓ | ✓ | P1 | Markdown + assets |
| RTF / DOCX | ✓ (RTF) | ✓ (RTF, DOCX outline) | P2 | DOCX via `NSAttributedString` docFormat |
| CSV | ✓ | ✓ | P2 | `path,title,note,tags,task` |
| PPTX | – | ✓ | P2 | From presentation (§5.13) |
| Anki `.apkg` | CSV | ✓ | P2 | §5.14 |
| JSON Canvas (`.canvas`, Obsidian) | ✓ | ✓ | P2 | Nodes + edges, positions preserved |
| Mermaid mindmap | – | ✓ | P2 | Text |

All importers produce a `MapModel` and go through validation. Every importer/exporter has round-trip or golden-file tests (§14). Export UI: File ▸ Export… (⌥⌘E) opens a sheet with format picker, live preview and format options. It remembers the last choice.

### 5.18 Document safety & history (`F-DOC`)

| ID | Pri | Requirement |
|---|---|---|
| F-DOC-1 | P0 | NSDocument autosave-in-place, Versions browser (File ▸ Revert To ▸ Browse All Versions), Duplicate, Rename/Move from title bar, Lock. |
| F-DOC-2 | P0 | Unlimited undo/redo within session with meaningful action names ("Undo Add Node", "Undo Move 3 Nodes", "Undo AI Expand"). Typing in a node coalesces into one undo per edit session. |
| F-DOC-3 | P0 | Crash safety: atomic package writes; if a save fails, the user is alerted and nothing is lost (NSDocument default). External modification (iCloud/Dropbox) is detected via `NSFilePresenter` and offers reload (auto-reload if no local edits). |
| F-DOC-4 | P1 | Schema versioning with forward migrations. Opening a file from a newer app version opens read-only with a banner. |
| F-DOC-5 | P2 | **Encrypted documents/branches**: password-protect a whole document (AES-GCM via CryptoKit, key from PBKDF2/scrypt; password optionally in Keychain) or an individual branch (content encrypted inside `map.json`; shows a lock node). |

### 5.19 Onboarding & help (`F-ONB`)

| ID | Pri | Requirement |
|---|---|---|
| F-ONB-1 | P0 | First launch: 3-card welcome (Think · Present · Learn) → "Open Sample Map" or "New Map". The sample map *is* the tutorial: each branch teaches a feature by doing ("Press ⇥ to add a child here →"). |
| F-ONB-2 | P0 | Help ▸ Keyboard Shortcuts (⌘/) opens a searchable cheat-sheet overlay. |
| F-ONB-3 | P1 | Empty states designed for: Library (no maps), Slides (no slides), Study (nothing due: celebratory), Search (no results). |
| F-ONB-4 | P1 | Tips: one contextual tip at most per session (e.g. first time dragging: "Hold ⌥ to place freely"), dismissible forever. |

### 5.20 Settings (`F-SET`)

Use SwiftUI `Settings` scene with tabs:

| Tab | Settings |
|---|---|
| General | Default theme; default structure; new-document location; open Library at launch; restore windows |
| Editing | Typing replaces text; smart typing toggles; node max width; spell check; default spacing; animation speed (Off/Fast/Normal) |
| Appearance | Toolbar style; show minimap; show status bar; reduced motion override |
| Themes | Manage, import, export |
| Shortcuts | Global Quick Entry hotkey; custom key bindings for any menu command |
| Study | Daily limits; desired retention; learning steps; reminder time |
| AI | Provider; keys; privacy; off switch |
| Integrations | Reminders; MCP; URL scheme; Services |
| Updates | Sparkle: automatic check, beta channel |
| Advanced | Rebuild index; reset tips; export diagnostics; file-format pretty-print toggle |

---

## 6. Interaction specification

### 6.1 Keyboard map (canonical; all MUST appear in menus)

The tables below use these symbols for keys:

| Symbol | Key |
|---|---|
| ⌘ | Command |
| ⌥ | Option |
| ⌃ | Control |
| ⇧ | Shift |
| ⇥ | Tab |
| ⏎ | Return |
| ⌫ | Delete |
| ⎋ | Esc |

#### Create

| Action | Keys |
|---|---|
| Child | ⇥ |
| Sibling below | ⏎ |
| Sibling above | ⌥⏎ |
| Parent | ⌥⇥ |
| New root | ⇧⏎ |
| Floating note | double-click empty canvas |

#### Edit

| Action | Keys |
|---|---|
| Edit title | ⏎ (on a selected node) / ⌘⏎ / F2 |
| Commit | ⎋ |
| Deselect | ⎋ again |
| Delete subtree | ⌫ |
| Delete node only | ⌥⌫ |
| Duplicate | ⌘D |
| Copy / paste style | ⌥⌘C / ⌥⌘V |
| Paste with style | ⇧⌥⌘V |

#### Move

| Action | Keys |
|---|---|
| Reorder siblings | ⌘↑ / ⌘↓ |
| Promote / demote | ⌘← / ⌘→ (side-aware) |
| Detach | ⇧⌘D |
| Balance | ⌥⌘B |
| Reset position | ⌃⌘R |
| Sort alphabetically | ⌃⌥⌘A |

#### Select

| Action | Keys |
|---|---|
| Spatial move | arrows |
| Extend selection | ⇧ arrows |
| All | ⌘A |
| Children | ⌥⌘A |
| Current root | ⌘R |
| Next / previous root | ⌃⌥N / ⌃⌥P |
| Jump to selection | ⌘J |

#### Fold

| Action | Keys |
|---|---|
| Toggle | ⌥. |
| With siblings | ⌥⌘. |
| Unfold one level | ⌃⌥. |
| Show levels 1–5 / all | ⌃1–⌃5 / ⌃0 |

#### Content

| Action | Keys |
|---|---|
| Note | ⇧⌘K |
| Link | ⌘K |
| Open link | ⌥⌘K |
| Task on/off | ⇧⌘T |
| Complete | ⌃⌘T |
| Tags | ⌥⌘T |
| Media | ⇧⌘M |
| Connection | ⌘L |
| Boundary | ⌥⌘G |
| Summary | ⇧⌘] |
| Make cloze | ⇧⌘C |
| Copy node link | ⌃⌘C |

#### View

| Action | Keys |
|---|---|
| Map / Outline / Side-by-side | ⌘1 / ⌘2 / ⌘3 |
| Zoom | ⌘+ / ⌘− |
| Actual size | ⌘0 |
| Fit | ⌘9 |
| Zoom to selection | ⌥⌘0 |
| Focus | ⇧⌘F |
| Zen | ⌃⌘F |
| Minimap | ⌥⌘M |
| Mastery overlay | ⌥⌘H |
| Inspector | ⌥⌘I |
| Sidebar | ⌃⌘S |

#### Find

| Action | Keys |
|---|---|
| Find | ⌘F |
| Find & replace | ⌥⌘F |
| Next / previous | ⌘G / ⇧⌘G |
| Use selection | ⌘E |
| Quick open | ⌘P |
| Command palette | ⇧⌘P |

| Filter bar | ⇧⌥⌘F |

**Deliberate deviation:** ⌘P opens Quick Open, as in developer tools, so **File ▸ Print moves to ⌃⌘P**. Document this in Help. Users can rebind it in Settings ▸ Shortcuts.

#### Present & study

| Action | Keys |
|---|---|
| Present | ⌥⌘⏎ |
| Make study deck | ⌥⌘S |
| Recall | ⌥⌘R |
| Study now | ⌃⌘⏎ |
| AI expand | ⌘. |

#### Global

| Action | Keys |
|---|---|
| Quick Entry (configurable) | ⌃⌥Space |
| Library | ⇧⌘L |
| Shortcuts help | ⌘/ |

### 6.2 Pointer interactions

- **Hover over a node:** a subtle lift (shadow +1 level), the Node Well "+" appears, and the cursor stays an arrow.
- **Hover over a branch:** the branch highlights slightly. Clicking a branch selects its child node.
- **Click and drag on a node:** moves it (reparent semantics, §F-EDT-5). If the drag starts with less than 4 pt of movement, treat it as a click.
- **⇧-drag from a node:** draws a connection.
- **Drag on empty canvas:** rubber-band selection. Use Space-drag or two-finger scroll to pan.
- **Right-click:** context menus for node, branch, connection, boundary and canvas, each holding every relevant command.
- **Drop from Finder or other apps:**
  - Images become image nodes.
  - Files become attachment nodes.
  - Text, Markdown and OPML become a hierarchy.
  - URLs become link nodes, titled from the page `<title>` when network is allowed, otherwise from the URL host.
  - `.arbor`, `.mindnode`, `.opml` and other importable files dropped on the Dock icon open as new documents.
- **Force Touch:** a deep press on a node opens Quick Look of its content.

### 6.3 Contextual floating bar

- When a selection settles for at least 300 ms, a compact Liquid Glass bar appears 12 pt above it, or below if there is no room.
- **Node selection controls:** shape, fill color, text style (B/I), add child, task, note, link, ⋯
- **Connection selection controls:** label, color, arrows, style, delete.
- The bar hides while typing or dragging. It can be disabled in Settings.

---

## 7. Visual design system

**Goal:** a calm, premium, Apple-native feel, competitive with MindNode, Craft and Things. All values are tokens in `DesignTokens.swift`, and themes override them.

### 7.1 Chrome

- System materials and Liquid Glass (macOS 26+) for the toolbar, sidebars, floating bars and Quick Entry.
- SF Pro for UI and SF Symbols for icons. Nothing custom-drawn where a system control exists.
- The inspector uses a SwiftUI `Form` with grouped sections, 11–13 pt controls, and section headers in `.secondary`.
- Accent color follows the system accent.

### 7.2 Canvas & nodes (Paper theme, the reference)

| Token | Light | Dark |
|---|---|---|
| Canvas | `#FAF9F7` | `#1C1C1E` |
| Root fill | `#2C2C2E` | `#F2F2F7` |
| Root text | `#FFFFFF`, 20 pt semibold | `#1C1C1E` |
| Level-1 node | fill = palette color @ 16% alpha, text 16 pt medium, radius 10, padding 10×16 | palette @ 24% |
| Level-2+ node | shape **Underline**, text 14 pt regular, underline 2 pt in branch color | same |
| Branch | tapered cubic Bézier, 6 pt at root → 2 pt at leaves, palette color | palette, +8% lightness |
| Palette (8) | `#E5484D` red, `#F76B15` orange, `#FFC53D` amber, `#46A758` green, `#12A594` teal, `#0090FF` blue, `#8E4EC6` purple, `#D6409F` pink | same hues, adjusted for contrast ≥ 4.5:1 on text |
| Selection | 2.5 pt system accent ring, offset 3 pt, radius = node radius + 3 | same |
| Shadow (raised) | y 1, blur 3, black 8% + y 4, blur 12, black 6% | black 40% |
| Connection | 1.5 pt, dashed 4/3, `#8E8E93`, arrow end | `#98989D` |
| Boundary | 1 pt `#8E8E93` @ 60%, fill palette @ 6%, radius 16, padding 14 | — |

### 7.3 Spacing (Default preset)

| Gap | Size |
|---|---|
| Level gap (parent → child horizontal) | 56 pt |
| Sibling gap | 12 pt |
| Gap between subtrees of different first-level branches | 24 pt |
| Root-to-level-1 gap | 72 pt |

Narrow and Wide are ×0.7 and ×1.4.

### 7.4 Branch geometry

Horizontal layout, from parent anchor `p0` (the parent's outer edge, at vertical center, or the underline end for underline nodes) to child anchor `p1`:

```
dx = p1.x − p0.x
c1 = (p0.x + dx·0.5, p0.y)
c2 = (p1.x − dx·0.5, p1.y)
```

Vertical layouts use the same formula with the axes swapped.

**Tapered branches:** offset the centerline by ±w(t)/2 along its normal, where w goes linearly from `w0` to `w1`. Sample at 16 points, build the closed polygon from the two offset curves, and fill it with round caps. Precompute this; don't re-sample during animation if only translation changes.

**Underline nodes:** the branch flows into the underline, which extends the full text width. Children leave from the underline's far end.

### 7.5 Typography

- Default font: SF Pro Text/Display. Theme options include New York (serif), SF Rounded, SF Mono, and any installed font.
- Line height 1.25. Text is optically centered in its shape.
- Minimum rendered size in study and presentation is 18 pt, auto-scaled.

### 7.6 Motion

| Event | Animation |
|---|---|
| Relayout (add/delete/move/fold) | 280 ms, spring (response 0.32, damping 0.86). Nodes move to new frames; branches morph with them. |
| New node | Scales 0.85 → 1 and fades 0 → 1 from the parent anchor, 220 ms. |
| Delete | Fades and scales to 0.9, 160 ms, then relayout. |
| Fold | Children collapse toward the parent and fade, 220 ms. The count pill pops in. |
| Camera (jump, focus, slides) | 450–600 ms, ease-in-out cubic. |
| Reveal (study/present) | Fade plus 8 pt slide from the parent, 250 ms, staggered 60 ms. |
| Selection ring | 120 ms fade. |

- **Reduce Motion:** all durations become 0 except a 120 ms crossfade on camera moves.
- **Animation speed setting:** ×0, ×0.6 or ×1.

### 7.7 App icon & brand

Original icon: a stylized tree or branch glyph forming a node graph on a soft gradient squircle, in the macOS 26 icon style (Icon Composer, layered for light, dark and tinted modes). It MUST NOT resemble MindNode's icon. Accent brand color: `#12A594` (teal). Deliver it as an `.icon` (Icon Composer) asset.

---

## 8. Data model & file format

### 8.1 Package layout

The UTI `com.arbor.map` conforms to `com.apple.package`, with extension `.arbor`.

```
My Map.arbor/
├── map.json                 # the document (schema below), UTF-8, sorted keys
├── assets/                  # content-addressed: <sha256>.<ext>  (images, attachments)
├── study/
│   └── reviews.jsonl        # append-only FSRS review log (one JSON per line)
├── QuickLook/
│   ├── Thumbnail.png        # 512×512 max, written on save
│   └── Preview.pdf          # whole-map vector preview
└── meta.json                # {formatVersion, appVersion, created, modified, docID}
```

- Pretty-printed JSON with sorted keys, so files are Git-diffable. Settings ▸ Advanced has a compact option.
- Unchanged `FileWrapper`s are reused, so autosave rewrites only `map.json`.

### 8.2 `map.json` schema (formatVersion 1)

```jsonc
{
  "formatVersion": 1,
  "docID": "UUID",
  "title": "Optional explicit title",
  "theme": { "id": "paper", "overrides": { /* ThemePatch */ } },
  "appearance": "auto",            // auto | light | dark
  "roots": ["nodeID", "..."],      // order = creation order (outline order)
  "nodes": {                       // flat map for O(1) lookup & clean diffs
    "nodeID": {
      "id": "UUID",
      "parent": "nodeID|null",
      "children": ["nodeID"],
      "title": { "text": "Plain text", "runs": [ { "range": [0,5], "bold": true, "color": "#hex" } ] },
      "note": "Markdown string",
      "structure": "mindmap.balanced",   // only if overriding inherited
      "side": "left|right|null",         // pinned side for root children
      "offset": { "x": 0, "y": 0 },      // manual offset from auto slot (flexible layout)
      "folded": false,
      "width": { "mode": "auto|fixed", "value": 280 },
      "style": { /* NodeStylePatch, only overridden props */ },
      "markers": ["sf:star.fill", "emoji:💡", "sticker:priority-1"],
      "image": { "asset": "sha256.png", "size": [200, 120], "placement": "above" },
      "attachments": [ { "asset": "sha256.pdf", "name": "Paper.pdf" } ],
      "link": "https://… | x-arbor://…",
      "source": { "url": "…", "page": 12, "time": 93.5, "excerpt": "…" },
      "tags": ["tagID"],
      "task": { "done": false, "due": "2026-12-01", "priority": 2, "repeat": "weekly", "reminderID": "EK…" },
      "fields": { "fieldID": "value" },
      "type": "concept",
      "study": {
        "card": "auto|on|off",
        "fsrs": { "due": "ISO8601", "stability": 3.1, "difficulty": 5.2, "reps": 4, "lapses": 0,
                  "state": "review", "lastReview": "ISO8601" }
      },
      "math": false,
      "numbering": "none|decimal|alpha|roman",
      "created": "ISO8601", "modified": "ISO8601", "modifiedBy": "user|ai|mcp|sync"
    }
  },
  "connections": [ { "id": "UUID", "from": "nodeID", "to": "nodeID", "label": "…",
                     "control": { "x": 0, "y": 0 }, "style": { /* ConnectionStyle */ } } ],
  "boundaries":  [ { "id": "UUID", "nodes": ["nodeID"], "title": "…", "style": {} } ],
  "summaries":   [ { "id": "UUID", "parent": "nodeID", "range": ["firstChildID", "lastChildID"],
                     "node": "summaryNodeID" } ],
  "tags":        [ { "id": "UUID", "name": "exam", "color": "#E5484D" } ],
  "fieldDefs":   [ { "id": "UUID", "name": "Due", "kind": "date" } ],
  "presentations": [ { "id": "UUID", "name": "Talk", "slides": [
      { "id": "UUID", "title": "…", "camera": { "x":0,"y":0,"scale":1 }, "folded": ["nodeID"],
        "focus": ["nodeID"], "dimOthers": true, "build": ["nodeID"], "notes": "…" } ] } ],
  "studySettings": { "newPerDay": 20, "retention": 0.9 },
  "view": { "camera": { "x": 0, "y": 0, "scale": 1 }, "selection": ["nodeID"], "mode": "map" },
  "filters": [ /* saved filters */ ]
}
```

**Invariants.** The loader validates these, repairs what it can, and logs:

- Every node except roots has exactly one parent.
- `children` and `parent` agree.
- There are no cycles.
- IDs are unique.
- Every asset reference exists.
- Every connection endpoint exists.

### 8.3 Rich text

- Titles store plain text plus attribute runs drawn from an allow-list:
  - `bold`, `italic`, `underline`, `strike`, `code`
  - `color`, `highlight`, `link`
  - `font`, `size`
- No arbitrary RTF.
- Notes are CommonMark plus GFM (tables, task lists) plus `$math$`. The note editor is WYSIWYG-ish: TextKit 2 with live Markdown styling, Bear/Craft-like, which hides the markup when the caret leaves.
- Parse notes with **swift-markdown** (Apple).

### 8.4 Migrations

- `formatVersion` is an integer.
- `MapCore.Migrations` holds a function `vN → vN+1` for each version step.
- Tests use fixture files for every version ever shipped.

---

## 9. Layout engine (`MapLayout` package)

- **Algorithm:** non-layered tidy tree (A. van der Ploeg, "Drawing non-layered tidy trees in linear time", 2014). It runs in linear time and supports variable node sizes. Port it from the public-domain reference into Swift on struct arrays, with no class graph.
- **Primitive:** `layoutSubtree(root, axis: .horizontal|.vertical, direction: +1|−1, spacing) → [NodeID: CGRect]`.
- **Structures built from that primitive:**
  - **Balanced:** partition root children greedily by subtree extent, preserving order, while respecting pinned sides. Lay out each side, mirror the left side, and center both on the root.
  - **Right / Left / Down / Up:** axis and direction transforms of the primitive.
  - **Logic chart:** the primitive, plus align children's left edges.
  - **Tree/list:** custom indented placement. y accumulates, x = depth × indent.
  - **Radial:** assign angular wedges in proportion to subtree leaf count. The radius per level is `max(prev radius + level gap, wedge arc length ≥ node extent)`.
  - **Timeline / Fishbone / Brace / Matrix:** dedicated placers in the same protocol `StructureLayout`.
  - **Mixing:** when a child declares a different structure, lay out its subtree with that structure into a bounding box. The parent treats that box as an opaque node.
- **Incremental:**
  - Cache node sizes from `TextMeasurer`, and subtree contours/extents.
  - Dirty-mark a changed node and its ancestors, recompute contours along that path, then run one top-down absolute-position pass.
  - Folded subtrees contribute only the node itself.
- **Flexible offsets:** `offset` is added after auto layout. Descendants move with it.
- **Determinism:** the same input gives the same output. This matters for snapshot tests.
- **Text measurement:** `TextMeasurer` (Core Text) is the single source of truth for node sizes. Canvas, export and layout all use it, so text never jumps on commit.
- **Budgets:** full layout of 5k nodes in under 10 ms; an incremental keystroke relayout in under 2 ms. Measure on an M1 base model.

---

## 10. Study engine (`MapStudy` package)

- **FSRS port:**
  - Use parameters `w[0…20]` from FSRS-6 defaults.
  - Implement the functions `initStability`, `initDifficulty`, `nextDifficulty` (with mean reversion), `retrievability(t,S)`, `nextRecallStability`, `nextForgetStability`, `nextShortTermStability` and `nextInterval(S, desiredRetention)`.
  - Unit-test against reference vectors from `fsrs-rs` / `ts-fsrs`. Commit those vectors as fixtures.
- **Card extraction:** `CardExtractor(map) → [Card]` derives cards on demand from the nodes. Card IDs are stable:
  - `nodeID` for basic cards.
  - `nodeID#r` for reversed cards.
  - `nodeID#c1` for cloze cards.
  - `summaryID` for summary cards.
  - Card state is stored on the node, under `study.fsrs` and keyed by card subtype.
- **Review log:** each review appends `{cardID, ts, grade, elapsed, stateBefore, stateAfter}` to `study/reviews.jsonl`. This supports optional parameter optimization later (P2), when there are 1,000+ reviews.
- **Queue building:** apply the daily limits, then order learning cards first, then due reviews (most overdue first), then new cards in map order.
- **Reveal Engine** (shared with presentations):
  - It is a state machine over an ordered list of node IDs and their reveal state.
  - The canvas renderer reads a `RevealState` overlay: hidden, placeholder or visible.

---

## 11. Architecture

### 11.1 Stack decisions

| Concern | Decision |
|---|---|
| Language | Swift 6.4, strict concurrency, Swift 6 language mode everywhere |
| Minimum OS | **macOS 26 (Tahoe)**, the last release with Intel support, so friends on Intel Macs are covered. macOS 27 APIs sit behind `if #available`. |
| App lifecycle | AppKit (`NSApplication`, `NSDocumentController`, `NSDocument`, `NSWindowController`). SwiftUI is hosted (`NSHostingView`/`Controller`) for the inspector, sidebars except Outline, settings, sheets, Library, onboarding and the study UI. |
| Canvas | Custom layer-hosting `CanvasView: NSView` with camera transform, Core Animation layers per visible node (pooled), `CAShapeLayer` edges, model-space hit-testing through a spatial grid index. **No SwiftUI Canvas, no Metal.** |
| Text editing | A single shared TextKit 2 `NSTextView` overlay, scaled to camera zoom, for in-node editing. A TextKit 2 note editor. |
| Outline | `NSOutlineView` |
| Persistence | Package files via `NSDocument` + `FileWrapper`, with async writes from a Sendable snapshot. Library index: **GRDB** (SQLite), disposable. |
| Undo | A command layer in `MapCore` (`MapCommand` with `apply`/`inverse`), registered with the document's `UndoManager` by the app adapter |
| State | Value-type `MapModel` (Sendable struct) inside an `@MainActor @Observable MapStore` that applies commands and publishes diffs (`ChangeSet`) to the canvas and outline. No Combine. |
| Dependencies (SPM) | swift-markdown, SwiftMath, ZIPFoundation, GRDB, Sparkle, KeyboardShortcuts (sindresorhus), swift-snapshot-testing (tests only). Keep it at **8 or fewer runtime dependencies**. Each needs an ADR. |
| AI | FoundationModels (on-device), plus a URLSession-based Anthropic / OpenAI-compatible client (no SDK dependency required), behind the `AIProvider` protocol |
| Sandbox | **On.** Entitlements: user-selected files read/write, app-scoped bookmarks, network client (AI/updates only), Reminders (on demand). |

### 11.2 Module layout

```
Arbor/
├── App/                         # Xcode app target (thin): AppDelegate, menus, windows, DI
├── Extensions/
│   ├── QuickLookThumbnail/      # QLThumbnailProvider
│   ├── QuickLookPreview/        # QLPreviewingController
│   ├── SpotlightImporter/       # CSImportExtension
│   └── ShareExtension/
├── Tools/arbor-mcp/             # MCP stdio helper (Swift executable)
├── Packages/
│   ├── MapCore/        # model, commands+inverses, validation, migrations, Codable (no AppKit)
│   ├── MapLayout/      # tidy tree + structures, contours, incremental (no AppKit; CoreGraphics only)
│   ├── MapRender/      # NodeRenderer, BranchPath, TextMeasurer, theme resolution (CoreGraphics/CoreText)
│   ├── MapIO/          # importers/exporters (OPML, MD, FreeMind, XMind, MindNode, SVG, PDF, …)
│   ├── MapStudy/       # FSRS, card extraction, queues, RevealEngine
│   ├── MapAI/          # AIProvider protocol + Apple/Anthropic/OpenAI-compatible backends
│   ├── MapLibrary/     # index (GRDB), watcher, backlinks, concept index
│   ├── CanvasKit/      # CanvasView, camera, culling, hit-test, drag/drop, text overlay, a11y (AppKit)
│   └── ArborUI/        # SwiftUI views: inspector, library, study, settings, design tokens
└── Tests/              # per-package test targets + UITests + Fixtures/
```

**Dependency direction:**

```
MapCore ← MapLayout ← MapRender ← (CanvasKit, MapIO)
MapCore ← MapStudy, MapAI, MapLibrary
ArborUI depends on everything above; App wires it all together
```

`MapCore`, `MapLayout`, `MapStudy` and `MapIO` (minus PDF/PNG) MUST build and test with `swift test` on the command line.

### 11.3 Data flow

```
User input → CanvasView/OutlineView → Intent (e.g. .addChild(of:)) → MapStore.perform(command)
  → MapModel' + ChangeSet + inverse → UndoManager.registerUndo(inverse)
  → Layout.update(dirty: ChangeSet) → [NodeID: Frame] diff
  → CanvasView.apply(frames, animated) + OutlineView.reload(items) + Inspector refresh
  → NSDocument.updateChangeCount (autosave)
```

### 11.4 Canvas internals

- **Camera:** `struct Camera { var origin: CGPoint; var scale: CGFloat }`. Apply it as `rootLayer.sublayerTransform`. Pan and zoom never redraw layers.
- **Culling:** a uniform grid spatial index with 512 pt cells. Realize layers only for the visible rect plus 50% margin, and recycle them from a pool.
- **Level of detail:**
  - Below 0.35× zoom, render nodes as colored capsules without text.
  - When a zoom gesture settles, wait 120 ms, then re-rasterize visible layers at `contentsScale = backingScale × camera.scale` (clamped to 1…8).
- **Node layer contents:** drawn by `MapRender.NodeRenderer` into a `CGContext`, the same code export uses. Mark layers dirty only on content or style change.
- **Edges:**
  - One `CAShapeLayer` per visible branch.
  - Tapered branches use a filled path.
  - Path animation uses identical element structure, so a `CABasicAnimation` on `path` works.
- **Display link:** use `NSView.displayLink` for custom-driven animations (relayout springs, camera). Keep all per-frame work under 4 ms.
- **Editing overlay:**
  - Position the overlay at the node's screen rect.
  - Hide the node's text layer while editing.
  - Commit on end-editing as one `editText` command.
  - Measure live while typing so the node grows and the layout updates incrementally.

### 11.5 Concurrency

- `MapStore` and all UI are `@MainActor`.
- Layout of more than 2k dirty nodes runs on a background actor with the snapshot, and results are applied on main. Smaller layouts run inline.
- Export, import, index and AI calls run in `Task`s with progress (`Progress`/`Subprogress`) and cancellation.

### 11.6 Accessibility

- The canvas exposes `NSAccessibilityElement`s per visible node, with role outline row, label = title, and value = "3 children, collapsed, task 2 of 5 done".
- Custom actions: add child, add sibling, fold, edit, open note.
- Post focus-change notifications as selection moves.
- The Outline view is the fully accessible alternative.
- Respect Reduce Motion, Increase Contrast (thicker borders, higher-contrast palette) and Differentiate Without Color (branch patterns or shape cues, task icons).
- Full keyboard access throughout.
- VoiceOver test script in §14.

### 11.7 Localization

- String Catalogs from day one. English ships first.
- In packages, use `String(localized:bundle:.module)`.
- Pseudo-localization scheme for testing.
- RTL locales default "Right" layouts to "Left".

### 11.8 Performance budgets

Measured on an Apple M1 base model with a 5,000-node map.

| Interaction | Budget |
|---|---|
| Pan/zoom | 120 fps on ProMotion, never below 60 |
| Keystroke → relayout → paint | < 8 ms |
| Open 5k-node document to first paint | < 300 ms |
| Full layout | < 10 ms |
| Expand/collapse animation | no dropped frames |
| Autosave main-thread cost | < 2 ms |
| Memory | < 300 MB |
| PDF export | < 1 s |
| App launch to window | < 500 ms |

The CI benchmark suite tracks these numbers (§14).

### 11.9 Identity & configuration

`AppIdentity.swift` and `Config.xcconfig` centralize:

| Setting | Value |
|---|---|
| App name | `Arbor` |
| Bundle ID | `com.<owner>.arbor` |
| Document UTI | `com.arbor.map` |
| Extension | `arbor` |
| URL scheme | `x-arbor` |
| Theme UTI and extension | `.arbortheme` |
| Sparkle feed URL | |

Renaming the app MUST be a one-file change, plus the icon.

---

## 12. Privacy & security

- No analytics or telemetry.
- Network is used only for:
  1. Sparkle update checks (can be disabled).
  2. Cloud AI providers the user configures.
  3. Fetching a page title or URL content when the user explicitly imports from a URL.
- API keys are stored in the Keychain and never written to documents or logs.
- AI privacy notice before the first cloud call. Per-document "Never send to cloud AI" flag.
- MCP is read-only by default and listens only via stdio/XPC from the local user. No TCP.
- Sandbox and Hardened Runtime are on.

---

## 13. Distribution

| Path | Cost | Experience for friends |
|---|---|---|
| **A. Developer ID + notarization** (recommended when sharing) | $99/yr Apple Developer Program | Double-click DMG → drag to Applications → opens normally. Extensions (Quick Look, Spotlight) work reliably. Keychain is stable across updates. |
| **B. Ad-hoc signed (free)** | $0 | Since macOS 15, each friend must try to open the app, then go to System Settings ▸ Privacy & Security ▸ **Open Anyway** (or run `xattr -dr com.apple.quarantine /Applications/Arbor.app`). Keychain prompts after updates. Extensions may not register. |

- **Personal use:** build and run locally with a free Personal Team. This is fine indefinitely on your own Mac.
- **Release pipeline**, triggered by a `vX.Y.Z` tag in GitHub Actions on `runs-on: xcode-27`:
  1. Test.
  2. Archive.
  3. Sign (Developer ID if secrets are present, else ad-hoc).
  4. Notarize and staple (if Developer ID).
  5. Build the DMG with `create-dmg` (background art, Applications alias).
  6. Run Sparkle `generate_appcast` (EdDSA key in CI secrets).
  7. Upload to GitHub Releases.
  8. Publish `appcast.xml` to GitHub Pages.
- **In-app updates:** Sparkle 2, via Check for Updates… in the app menu.

---

## 14. Quality & testing

| Layer | Tooling | What |
|---|---|---|
| Unit | Swift Testing | `MapCore` commands (apply∘inverse = identity, property-based over random trees); validation and repair; migrations; FSRS reference vectors; card extraction; filters |
| Layout | Swift Testing + snapshot | Invariants: no node overlaps (AABB), children order preserved, balanced symmetry, determinism. Golden JSON of frames for fixture maps per structure. |
| Render | swift-snapshot-testing | `NodeRenderer` and full-map images for each theme × light/dark × structure (fixed fonts; perceptual precision 0.98). SVG/OPML/Markdown outputs as text snapshots. |
| IO | Swift Testing | Round-trip tests (export→import equals model, modulo the lossy fields documented per format). Real-world fixture files for XMind (both versions), FreeMind, OPML from MindNode/OmniOutliner, `.mindnode` v9, and Markdown variants. |
| Performance | XCTest `measure` + `os_signpost` | Layout 1k/5k/10k; open; render; export. Trend-tracked in CI, with failure at > 25% regression. |
| UI | XCUITest (smoke) | The golden paths of §3. Undo/redo of each. Export menu. Presentation start/advance/exit. Study session complete. |
| Accessibility | Manual script + Accessibility Inspector audit per milestone | VoiceOver can create, navigate, edit and fold a 20-node map |
| Lint | `swift format` (checked-in `.swift-format`) + SwiftLint in CI | — |

- Every package has ≥ 80% line coverage in `MapCore`, `MapLayout`, `MapStudy` and `MapIO`.
- Each bug fix comes with a regression test.

### 14.1 Definition of Done (each feature)

1. Its acceptance criteria are met.
2. It is reachable from menus and the keyboard.
3. It is undoable where it mutates.
4. It is persisted and round-trips.
5. It works in light and dark, and with Reduce Motion.
6. It has VoiceOver labels.
7. It has tests.
8. It has no new warnings under strict concurrency.
9. It meets its performance budget.
10. `CHANGELOG.md` is updated.

---

## 15. Repository conventions

- **Branches:** `main` is always releasable. Use `feat/<milestone>-<topic>` for work.
- **Commits:** Conventional Commits.
- **Pull requests:** one per milestone slice, with a checklist from §14.1.
- **Docs:**
  - `docs/decisions/` for ADRs.
  - `docs/research/` for research.
  - `docs/design/` for screenshots and mockups as the UI evolves.
  - `CHANGELOG.md`.
- `AGENTS.md` (and a `CLAUDE.md` symlink) holds build commands, architecture rules and "do not" lists for coding agents.

---

## 16. Milestones

Each milestone ends with a tagged build (`v0.N.0`) that the owner can use daily.

| M | Name | Contents | Exit criteria |
|---|---|---|---|
| **M0** | Foundation | Xcode project + SPM packages per §11.2; CI (`swift test` + `xcodebuild test`); swift-format/SwiftLint; AppIdentity; empty NSDocument with package read/write; ADR-0001 stack | CI green; open/save an empty `.arbor` round-trips |
| **M1** | Core editor | MapCore model + commands + undo; MapLayout balanced/right/left/down; TextMeasurer + NodeRenderer (Paper theme); CanvasView with camera, culling, selection, spatial nav, inline editing, F-EDT-1…9, 14, 15; drag-reparent; folding; relayout animation; view-state restore | Golden scenario 1 passes; 5k-node perf budgets met; no data loss under fuzzed command sequences |
| **M2** | Look & feel | All shapes, styles, inspector (Style/Layout/Theme/Canvas); 12 themes (dynamic); theme editor; branch styles incl. tapered; contextual bar; minimap; toolbar; app icon; onboarding + sample map | A designer-quality screenshot set (each theme, light/dark) checked into `docs/design/`; owner sign-off |
| **M3** | Content | Notes (popover/window/sidebar, Markdown); images; markers (SF Symbols/emoji/stickers); links; tasks + progress; tags + highlight; connections; boundaries; summaries; LaTeX; smart typing | Each F-CNT/F-REL/F-TSK/F-TAG P0–P1 criterion has a passing test |
| **M4** | Views & capture | Outline view (full + side-by-side); Focus; Zen + timer; Find/Replace; Quick Open/Command palette; Quick Entry; print | Golden scenario 5 passes; outline ↔ map edits stay consistent under randomized tests |
| **M5** | Interop | Import/export P0+P1 formats; Quick Look extensions; Spotlight importer; Library window + index + backlinks; templates | Fixture corpus round-trips; a real MindNode/XMind file imports correctly; Finder previews work |
| **M6** | Present | RevealEngine; auto + authored slides; builds; presenter view; clicker keys; live edit; PDF export of slides | Golden scenario 4 passes on two displays |
| **M7** | Learn | MapStudy (FSRS); card extraction (basic/reversed/cloze/summary); study session UI; recall mode; mastery overlay; dashboard; notifications | Golden scenario 3 passes; FSRS matches reference vectors |
| **M8** | Intelligence & automation | AIProvider (Apple, Anthropic, OpenAI-compatible); expand/generate/summarize; App Intents; URL scheme; Services/Share ext; MCP server; Reminders two-way sync | Each feature is usable with AI disabled-by-default; MCP works from Claude Code |
| **M9** | Ship | Performance pass; accessibility audit; Sparkle; DMG pipeline; notarization (if enrolled); README with screenshots; v1.0.0 | Fresh-Mac install test by a friend succeeds; zero P0 bugs open |
| **M10+** | Post-1.0 | P2 items: radial polish, matrix/brace, custom fields & node types, conditional styles, encryption, PPTX/Anki/iThoughts/JSON Canvas, widgets, AppleScript, AI study helpers, image occlusion | — |

---

## 17. Open questions (for the owner)

The defaults below are assumed until changed.

1. **Name.** "Arbor" is a placeholder. Alternatives: Branchwise, Mindgarden, Synapse. The default is Arbor.
2. **Developer ID ($99/yr).** Needed only when sharing with friends. The pipeline supports both paths. The default is ad-hoc until the owner decides.
3. **Minimum OS.** Default macOS 26. Raising it to 27 would allow the new SwiftUI document APIs, but would drop Intel friends.
4. **Cloud AI default model.** Anthropic `claude-sonnet-5-5`, configurable. On-device is used first when available.
5. **Public or private GitHub repo.** Default private. Make it public before sharing if you want free CI minutes and public releases.

---

## 18. Glossary

| Term | Meaning |
|---|---|
| **Root / main node** | A top-level node. A document can have several. |
| **Branch** | A node plus its subtree. Also the line drawn to a child. |
| **Level-1 node** | A direct child of a root. It defines its branch's palette color. |
| **Structure** | The layout algorithm applied to a subtree. |
| **Connection** | A non-hierarchical link between any two nodes. |
| **Boundary** | A visual enclosure around a subtree or a group of siblings. |
| **Summary** | A brace over a sibling range, with a summary node. |
| **Card** | A study item derived from a node. |
| **FSRS** | Free Spaced Repetition Scheduler. |
| **R** | Retrievability: the probability of recall now. |
| **Reveal Engine** | The shared progressive-disclosure mechanism behind presentation builds and study recall. |
