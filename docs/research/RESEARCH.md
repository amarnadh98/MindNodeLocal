# Research Notes — MindNode & the Mind-Mapping Landscape (Nov 2026)

Compiled 2026-11-18 from official sites, App Store listings, release notes and reviews. These notes are the evidence behind [`../../SPEC.md`](../../SPEC.md). Items marked **[unverified]** came from a single third-party source or from inference.

---

## 1. MindNode, the app we are replacing

### 1.1 Status
- **Developer:** IdeasOnCanvas GmbH (Austria), independent and founder-owned.
- **Two apps:**
  - **MindNode** (formerly "MindNode Next"), v2026.7.2. Requires macOS 15 or later.
    - Documents live in an in-app database synced with CloudKit, not as files on disk.
    - Released on a calendar-versioned cadence: 2025.5 → 2026.7.
  - **MindNode Classic**, v2026.0.3. Requires macOS 13 or later.
    - The file-based `.mindnode` app. Maintenance only, and hidden from App Store search.
- **Pricing:** the app is free to download. **MindNode Plus** costs $2.99/month or $24.99/year, with no lifetime option. It is also included in Setapp.
- **Free tier includes:** mapping, folding, *read-only* outline, sync, import/export.
- **Plus-only features:**
  - Outline editing, notes, tasks, connections
  - Images, emoji and stickers
  - Focus Mode, visual tags
  - Styling and themes
  - Apple Intelligence features, Shortcuts, document linking
  - SVG export
  - Collaboration and Apple Watch
- **So:** nearly everything that makes the app good is paywalled. Our app ships all of it for free.
- Sources: [mindnode.com/download](https://mindnode.com/download), [App Store](https://apps.apple.com/us/app/mindnode-next/id6446116532), [releases](https://mindnode.com/releases), [Classic page](https://mindnode.com/classic).

### 1.2 Recent feature timeline
| Release | Notable additions |
|---|---|
| 2025.5 | Personal themes, Apple Reminders sync, independent image/text resizing |
| 2025.6 | Liquid Glass redesign; on-device Apple Intelligence (brainstorm, generate text, summarize); background removal |
| 2025.7 | Inspector sizing, sticker tints, Finder aliases to documents, Things/OmniFocus export |
| 2026.1 | Folding actions ("Show 3 Levels"), find and replace in notes (also Apple Watch, out of scope) |
| 2026.2 | Document History, document linking with canvas previews, highlight tasks, always-visible notes sidebar |
| 2026.3 | Nested folders, widgets, Marked integration |
| 2026.4 | **Radial layout**, circle/square shapes, **tapered branches**, **LaTeX** |
| 2026.5 | Advanced printing, **MCP agent integration**, history marks AI changes |
| 2026.6 | macOS 27 update, Spotlight and Siri improvements |
| 2026.7 | Side-by-side map and outline, unified toolbars and inspectors |

### 1.3 Features in detail
- **Canvas and editing**
  - Infinite canvas. A new document opens with the main node already in edit mode.
  - **Multiple main nodes** per document (⇧⏎).
  - **Node Well:** a "+" handle on hover. Click it to add a child, or drag it to place the child.
  - Drag a node onto another to reparent it. Modifier keys while dragging:
    - **D** detaches the node.
    - **Space** connects it to the target instead.
    - **⌥** places it freely.
    - **⌘** keeps the node's own style.
  - ⌫ deletes the subtree. ⌥⌫ deletes the node only and promotes its children.
  - Node width auto-fits up to about 320 pt, then switches to a fixed width.
  - Rich-text titles, structured copy/paste, and pasting Markdown creates a hierarchy.
- **Layouts**
  - Orientations: horizontal (left/right/balanced), vertical (up/down), compact (org-chart style), radial.
  - Branches: rounded or angular, optionally tapered. Spacing: narrow, default or wide.
  - **Flexible layout:** a dragged node keeps its offset from its parent. A shadow previews where it will snap. An indicator appears once the node has left auto layout. *Reset Position* (⌃⌘R) returns it to auto layout.
- **Focus Mode** (⇧⌘F) dims everything outside the selection and zooms to it.
- **Folding:** fold (⌥.), fold with siblings (⌥⌘.), unfold one level (⌃⌥.), and "Show N levels".
- **Outline view**
  - ⌘1 shows the map, ⌘2 the outline. The two stay in sync and can sit side by side.
  - First-level order follows the map clockwise.
  - Keyboard: ⏎ new row or split, ⇥/⇧⇥ indent/outdent, ⌘↑↓ move a row, ←/→ fold and unfold.
  - Display options: inline notes, tags and images, and an "Open Tasks" filter.
- **Quick Entry (Classic only):** a menu-bar capture field where each line becomes a node, then the result becomes a document. *Removed in Next, and users miss it.*
- **Smart typing**
  - `#tag` at the end of a title tags the node.
  - `-[]` at the start makes the node a task.
  - `--` on its own line starts the node's note.
- **Visual tags:** colored pills on nodes, defined per document. **Tag Highlight Mode** emphasizes nodes with the chosen tags.
- **Tasks**
  - Checkboxes on nodes. Parent nodes show a **progress ring** (hover shows the percentage; click toggles every child).
  - Sort children by task state, and a highlight-tasks mode.
  - One-way sync to Reminders: completion syncs both ways, but new reminders do not come back as nodes.
  - Export to Things, OmniFocus and TaskPaper.
- **Notes:** a rich-text note per node. Opens as a popover, a detachable window, or a persistent sidebar. Has find and replace.
- **Connections** (cross links)
  - Create with ⌘L or a ⇧-drag between nodes.
  - A draggable midpoint waypoint bends the curve; double-click it to reset.
  - Optional label, plus style, color, width, arrow caps and direction.
- **Links:** URL per node (⌘K, open with ⌥⌘K), and links to other nodes or documents with a preview.
- **Media**
  - Over 250 designer stickers, tinted or colored. Any emoji.
  - Photos (Space opens Quick Look). Image Playground and background removal.
- **Styling**
  - 10 node shapes: circle, square, rectangle, rounded, pill, cloud, **line** (text on an underline), embedded, hexagon, octagon.
  - Fill, border, text attributes, branch color/thickness/taper, fixed width, canvas color.
- **Themes**
  - Dynamic themes (light/dark aware) and static themes.
  - A theme is *extracted* from a styled sample map with 6 children, which is clunky. There is **no direct theme editor**.
  - Each level-1 branch gets a palette color that its descendants inherit.
- **AI and integrations**
  - On-device Apple Intelligence: brainstorm, expand, map to article, summarize, title suggestions.
  - **Local MCP server**, read-only by default.
  - 14 Shortcuts actions, Siri, Spotlight, widgets, Control Center.
  - Document History, nested folders, printing.
- **Find:** ⌘F, ⌥⌘F (replace), ⌘G, ⌘E, and ⌘J (jump to selection).
- **Import:** MindNode, Classic, text, RTF, Markdown, TextBundle, FreeMind, iThoughts, OPML, Xmind, .docx.
- **Export:** PDF (map or outline), SVG, PNG (transparent option), Markdown/TextBundle, text, RTF, TaskPaper, FreeMind, OPML.

### 1.4 UI and UX character
- **Window:** a unified toolbar over a full-bleed canvas, with an optional right **inspector** (Themes, Canvas, Layout, Style) and an optional notes sidebar. A small floating contextual bar appears next to the selection.
- **Keyboard-first creation:** ⇥ adds a child, ⏎ a sibling, ⌥⏎ a sibling above, ⌥⇥ a parent, ⇧⏎ a main node. Esc ends editing and deselects. Arrow keys navigate spatially.
- **Motion:** every structural change animates siblings and branches into their new places. Zoom snaps to round levels with a haptic tick. Pinch zoom and inertial scrolling.
- **Look:**
  - Off-white canvas, or near-black in dark mode. No grid.
  - The main node is a filled pill or rounded rectangle.
  - Level-1 branches get rainbow-pastel colors that their descendants inherit.
  - Default children use the "line" shape, with text sitting on a colored underline that flows into the branch.
  - Tapered cubic-Bézier branches in SF Pro, with lots of whitespace.
  - Liquid Glass chrome and SF Symbols.
- **Small touches:**
  - An untitled document is auto-named from its root node's text.
  - Scroll position and zoom are restored on reopen.

### 1.5 File format (`.mindnode` v9, reverse-engineered [unverified])
- A package directory containing:
  - `contents.xml`, which is actually a **binary plist** despite the extension.
  - `resources/` for attachments.
  - `QuickLook/` previews.
- Keys:
  - `canvas.mindMaps[].mainNode`, with recursive `subnodes[]`.
  - Each node has `nodeID` (UUID), `title.text` (small HTML), `note`, `task{state}`, `tags[]` and `attachment{fileName,…}`.
  - `canvas.crossConnections[]` and `canvas.tags[]{tagID,name,color}`.
- Source: [mindnode-mcp](https://github.com/masamitsu-konya/mindnode-mcp). Verify against real files with `plutil -p`.

### 1.6 What users complain about (our opportunities)
1. **Subscription paywall.** Long-time owners say the app was gutted.
2. **No more real files.** Next keeps maps in a hidden database, so they can't go in Git, project folders or normal backups. Reviewers call it a "dealbreaker for professional use".
3. Next launched without features Classic had: Quick Entry, manual layout, several exporters.
4. Clunky theme creation, with no theme editor.
5. Missing features: **boundaries/summaries**, **presentation mode**, custom fields, repeating tasks, two-way Reminders sync. Japanese IME bugs.

---

## 2. Competitive landscape

### 2.1 App snapshots
| App | Positioning | Steal | Pain |
|---|---|---|---|
| **XMind** | Cross-platform leader | **Mixed structures per branch**: logic, brace, org, tree, timeline, fishbone, tree table, matrix. Boundaries, summaries, relationships, LaTeX. **ZEN** mode with a timer. **Pitch**: auto slides per branch, the remaining topics ghosted for context, export to PPTX. AI: text→map, image→map, expand a branch. | Paywall creep (Pro $4.92/mo, Premium $8.25/mo), AI credits, slow on big maps, not native |
| **iThoughtsX** | Power user's Mac mapper, **discontinued Jan 2024** | **Authored presentation slides**: snapshots of fold state, selection and focus dimming, plus a slide picker, clicker support and editing mid-presentation. The widest import/export. | Abandoned, dated UI |
| **SimpleMind Pro** | One-time purchase, cross-platform | Free-form plus 7 auto-layouts, multiple central topics, slideshow, checkboxes, progress, auto-numbering | Dated look, no LaTeX or AI |
| **MindManager** | Enterprise planning | Many diagram types, filters, SmartRules, conditional formatting, Gantt | Expensive, Mac version lags, cluttered |
| **MindMeister** | Collaborative web app | Presentation, Focus and Outline modes; history | Web-only |
| **Scapple** | Freeform scratchpad | Double-click anywhere to add a note; drag a note onto another to link them; background shapes | No hierarchy, rarely updated |
| **Whimsical / Miro** | Web whiteboards | Very fast keyboard flow; **⌘. AI suggests 5 child ideas**; map from a URL | Shallow maps, online only |
| **Heptabase** | Visual learning PKM | Cards that link back to the exact PDF page or video timestamp; AI Tutor that turns a goal into a course; MCP | Subscription, slow with many cards, weak auto layout |
| **Obsidian Canvas / Excalidraw** | Local-first vault | Open JSON Canvas format, backlinks, slideshow plugins, spaced-repetition plugins | Fragmented across plugins, unpolished |
| **Logseq** | Outliner | `#card` flashcards with cloze deletions | Weak spaced repetition (no decks or learning phase), DB version still in beta |
| **Ayoa** | Organic maps | Hand-drawn branches, maps within maps, neuro-inclusive settings | Paywalls, sprawl |
| **Freeplane** | Free Java power tool | Summary nodes, clouds, attributes, conditional styles, filters, **encrypted branches**, scripting | Ugly UI |
| **MarginNote 4** | Study app | **One object is the excerpt, the map node and the flashcard at once.** FSRS scheduling, a Recall blur mode, one-by-one reveal. | Very complex UI |
| **Mapify / Napkin** | AI generators | Turn a PDF, YouTube video, web page or image into a map; select prose and get a diagram; present as slides | Credits; maps get used once and dropped |
| **Apple Freeform** | Whiteboard | "Scenes": saved viewpoints you step through | No map structure |
| **Tana** | Graph outliner | **Supertags**: typed nodes with fields | No map view |

### 2.2 Best ideas to adopt (ranked)
**Learning**
1. **One object, many views.** A node is also an outline row and a flashcard. Review results write back as mastery colors on the map (MarginNote).
2. **Study a branch with FSRS.** The node title is the prompt; its children and note are the answer. Support cloze deletions and image occlusion. Include decks and a learning phase.
3. **Progressive-reveal recall on the canvas:** hide the children and reveal them one at a time.
4. **AI quiz and flashcard generation** from the map structure, each card linked back to its node.
5. **Source-anchored nodes:** a PDF page or video timestamp link on a node.
6. **Learning goal → curriculum map** (Heptabase AI Tutor).
7. **Typed nodes:** Concept, Definition, Example, Question (Tana supertags, kept light).

**Presenting**

8. **Both presentation models:**
   - Auto-pitch, one slide per branch, with the remaining topics ghosted.
   - Authored snapshot slides that also save the camera position.
9. **Branch-by-branch build.** It reuses the same reveal engine as recall study mode.
10. **Presenter view** on a second display: notes, timer, next slide, mini-map. Clicker support. Export to PDF and PPTX.
11. **Focus/ZEN mode** with a brainstorm timer.

**Structure and editing**

12. Mixed structures per branch: timeline, fishbone, org chart, logic chart, matrix.
13. A free-form and auto-layout hybrid, with multiple roots and loose scratch notes.
14. Boundaries, summaries and callouts.
15. Paste text or an image and get a map, on-device.
16. Native integration: Reminders, Shortcuts, Spotlight, Quick Look, LaTeX, Markdown.
17. Filters, conditional styling, encrypted branches.
18. **Broad import** to win switchers from iThoughts (`.itmz`), MindNode (`.mindnode`), XMind (`.xmind`), FreeMind (`.mm`), OPML and Markdown.

### 2.3 Gaps nobody fills well
1. A **native Mac mind mapper with a built-in study mode**, plus a mastery heatmap.
2. **One mechanism for both presenting and self-testing.**
3. A worthy successor to iThoughts.
4. **No subscription**, with on-device AI or bring-your-own-key.
5. AI-generated maps that you **keep**, link back to their sources, and review.
6. Links between maps, **backlinks**, and a library-wide concept index.
7. Rich node content (code blocks, tables, math) for learning technical subjects.
8. **Performance**: thousands of nodes at 120 fps.
9. An **open, plain-file, Git-friendly** format.
10. A visual spaced-repetition dashboard: which parts of the map are fading from memory.

Sources: [xmind.com/features](https://xmind.com/features), [xmind.com/pricing](https://xmind.com/pricing), [toketaware.com](https://www.toketaware.com/ithoughtsx-howto-present), [simplemind.eu](https://simplemind.eu/features/), [marginnote.com](https://www.marginnote.com/en/features/card-axis/), [heptabase.com](https://heptabase.com), [whimsical help](https://help.whimsical.com/get-started/ai), [Logseq SRS forum](https://discuss.logseq.com/t/flashcards-srs-improvements/5932), [obsidian canvas](https://obsidian.md/help/plugins/canvas).

---

## 3. Technical research summary
The full recommendations are in SPEC §11. The key points:
- **Canvas:** AppKit and Core Animation, not SwiftUI `Canvas` (no per-element hit-testing or accessibility, and it redraws everything) and not Metal (text rendering is too costly).
  - A camera-transformed, layer-hosting `NSView`, culled through a spatial index and with a layer pool.
  - One shared TextKit 2 `NSTextView` overlay for editing.
- **Document:** an `NSDocument` file package with `autosavesInPlace`, which provides Versions, Revert, rename in the title bar and async saving. iCloud Drive works through the ordinary Save panel with no entitlements.
- **Layout:** van der Ploeg's **non-layered tidy tree** (linear time, variable node sizes). Every orientation is a transform of one engine, with incremental contour caching.
- **AI:** the Foundation Models framework (`LanguageModelSession`, `@Generable`).
  - The context window is small (4K–8K tokens), so expand one branch per call.
  - macOS 27 adds a `LanguageModel` protocol and partner packages. Fall back to a user API key stored in the Keychain.
- **Distribution:**
  - **Developer ID and notarization** cost $99/yr and give friends a smooth install.
  - Ad-hoc signing is free, but since Sequoia each friend has to approve the app in System Settings → Privacy & Security → *Open Anyway*.
  - Updates: Sparkle 2 with GitHub Releases, packaged with create-dmg.
- **Testing:** Swift Testing, pointfreeco swift-snapshot-testing for the renderer, a few XCUITests. CI uses the GitHub `xcode-27` runner.
- **Formats:**
  - XMind files are a zip containing `content.json` (2020+) or `content.xml` (Xmind 8).
  - FreeMind `.mm` is XML.
  - OPML 2.0.
  - MindNode `.mindnode` is a binary plist package, read best-effort.
