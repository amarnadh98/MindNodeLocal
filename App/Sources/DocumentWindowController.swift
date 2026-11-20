import AppKit
import CanvasKit
import MapCore
import MapIO
import MapRender

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

    /// The inspector pane (SPEC §4.1, F-STY-2/3/4/6): a trailing
    /// inspector-style split item hosting SwiftUI, hidden by default
    /// (visibility persisted in `DocumentPreferences`). Owns no model
    /// state; every mutation is one `MapStore` command. Installed
    /// lazily — see InspectorPaneController.
    let inspector = InspectorPaneController()

    /// §6.3: the contextual floating bar above a settled selection.
    let contextualBar = ContextualBarController()

    /// F-STY-4 live theme preview: the theme grid's hovered tile pins
    /// the scene's theme WITHOUT touching the model (view-only; hover
    /// never dirties the document). `nil` = the stored selection.
    var previewThemeID: String?

    /// M4 (F-OUT): the outline pane — a second view on the same store.
    /// All outline logic lives in App/Sources/Outline/; the integration
    /// hooks are in DocumentWindowController+Outline.swift.
    let outlineController = OutlineViewController()
    /// M4 (F-OUT-1 ⌘3): the side-by-side container.
    let documentSplitView = NSSplitView()
    /// M4: which of ⌘1/⌘2/⌘3 is active (persisted via CanvasViewState).
    /// Internal setter: the mode logic lives in
    /// DocumentWindowController+Outline.swift.
    var activeViewMode: ViewMode = .map
    /// M4: outline ↔ canvas selection sync loop guard.
    var isSyncingSelection = false
    /// M4: the outline pane's width across ⌘3 sessions.
    var lastOutlinePaneWidth: CGFloat = 300

    /// The pasteboard the clipboard actions exchange (F-EDT-9).
    /// Injectable so hosted tests use a private `NSPasteboard(name:)`
    /// instead of the user's clipboard.
    var clipboard: NSPasteboard = .general

    /// F-CAN-8 (ADR-0005): the per-document view-state sidecar store.
    /// Injectable so hosted tests run against a temp directory.
    var viewStateStore = ViewStateStore(baseURL: ViewStateStore.defaultBaseURL())

    /// How long a camera/selection change waits before the view state
    /// persists (F-CAN-8); injectable so tests don't wait a real second.
    var viewStateSaveDelay: Duration = .seconds(1)

    // MARK: F-FOC wiring (find, focus, zen, quick open)
    // The coordinator owns all F-FOC state; the hooks below are the
    // only touch points in this shared file. See
    // App/Sources/FocusFind/.
    let focusFind = FocusFindCoordinator()
    /// M3 media: images, markers, attachments, sources and the filter
    /// bar (DocumentWindowController+Media + MediaCoordinator.swift).
    let mediaCoordinator = MediaCoordinator()

    private var viewStateSaveTask: Task<Void, Never>?

    /// F-CAN-6: the minimap overlay, anchored bottom-right of the canvas
    /// and installed by `installChrome()` (DocumentWindowController+Toolbar).
    var minimap: MinimapView?

    /// The document toolbar (§4.1), kept so selection changes can
    /// re-validate its items.
    var documentToolbar: NSToolbar?

    /// The zoom % pull-down's button, synced on camera moves.
    var zoomPopupButton: NSButton?

    /// F-DOC-4: the read-only banner pinned to the window's top edge
    /// while the document came from a newer app version. Managed by
    /// DocumentWindowController+DocumentSafety.
    var readOnlyBanner: ReadOnlyBannerView?

    /// M6 (F-PRE): lazily-built presentation coordinator, the Slides
    /// sidebar, and any in-flight build-order recording. Kept as
    /// optional boxes because stored properties cannot live in
    /// extensions; all the presentation logic is in
    /// DocumentWindowController+Presentation.swift.
    var presentationCoordinatorBox: PresentationCoordinator?
    var slidesSidebarBox: SlidesSidebarController?
    /// The frontmost study session of this window (kept so hosted tests
    /// and VoiceOver scripts can reach it; a new session replaces it).
    var activeStudySession: StudySessionController?
    /// F-STD-5: the live recall run on this window's canvas, if any —
    /// pure view state (an overlay + an input shield); the logic lives
    /// in App/Sources/Study/RecallSession.swift and the menu hooks in
    /// DocumentWindowController+Recall.swift.
    var recallSessionBox: RecallSession?

    init(document: NSDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = document.displayName
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = canvas
        // Note: addWindowController(_:) assigns .document, so this init
        // must not set it first — assigning it here makes AppKit's insert
        // a no-op and the document ends up with zero window controllers.
        super.init(window: window)
        // The window controller must be the window's delegate for two
        // reasons: `windowWillClose` flushes the view state (F-CAN-8),
        // and the delegate is the responder-chain hop that lets the
        // menu's clipboard actions reach this controller (F-EDT-9).
        // Programmatic windows don't get the nib-loading path's implicit
        // delegate assignment.
        window.delegate = self
        installOutlineIntegration()
        // The inspector reaches back into this controller (its store,
        // canvas and window); the pane installs only after `super.init`.
        inspector.host = self
        contextualBar.attach(to: self)

        canvas.onEffectiveAppearanceChange = { [weak self] in
            self?.updateScene(preserveCamera: true)
        }
        canvas.onCameraChange = { [weak self] in
            self?.scheduleViewStateSave()
            // F-CAN-6: the minimap re-strokes its viewport rect; the
            // toolbar's zoom % follows.
            self?.syncMinimapCamera()
            // F-FOC: find rings re-pin at the new camera and dimming
            // re-applies to whatever the new viewport realized.
            self?.focusFind.cameraDidChange()
            // §6.3: the contextual bar follows the selection under the
            // camera.
            self?.contextualBar.reposition()
        }
        canvas.onSelectionChange = { [weak self] ids in
            self?.canvasSelectionDidChange(ids)
            // The inspector's snapshot follows the selection.
            self?.inspector.refresh()
            // §6.3: the contextual bar waits for the selection to
            // settle.
            self?.contextualBar.selectionDidChange()
            // Toolbar/menu validation follows the selection.
            self?.documentToolbar?.validateVisibleItems()
            // F-FOC: navigation inside focus moves the focus.
            self?.focusFind.selectionDidChange()
            // M6 (F-PRE-3): a click during a build recording appends to
            // the draft order.
            self?.slidesRecordSelectionChange(ids)
        }
        canvas.onEditingCommit = { [weak self] id, title, next in
            self?.handleEditingCommit(id: id, title: title, next: next)
        }
        // §6.3: the bar hides while typing — the editing session's own
        // hooks (commit and the live draft) carry this; a fresh selection
        // change re-presents it after the settle delay.
        canvas.onEditingDraftChange = { [weak self] id, title in
            self?.editingDraftTitle = (id, title)
            self?.contextualBar.dismiss()
            self?.updateDraftScene()
        }
        canvas.onCreateFloatingNode = { [weak self] point in
            self?.createFloatingNode(at: point)
        }
        // F-LAY-14: a folded node's count pill unfolds it — one undo
        // step, the selection untouched.
        canvas.onUnfoldPill = { [weak self] id in
            self?.unfoldFromPill(id)
        }
        canvas.onDrop = { [weak self] command, selection in
            self?.performDragDrop(command, selection: selection)
        }
        // The Node Well "+" and the ⌫ key (SPEC §6.2, F-EDT-4).
        canvas.onAddChildAtHandle = { [weak self] id, side in
            self?.addChildFromHandle(id, side: side)
        }
        canvas.onDeleteSelection = { [weak self] nodeOnly in
            if nodeOnly {
                self?.deleteNodeOnlyAction(nil)
            } else {
                self?.deleteSubtreeAction(nil)
            }
        }
        // F-FOC wiring: the coordinator reaches back through this weak
        // reference (see FocusFindCoordinator).
        focusFind.controller = self
        // F-AI-2: clicking a ghost suggestion accepts exactly that one.
        ai.host = self
        canvas.onGhostAccept = { [weak self] ghostID in
            self?.ai.acceptGhost(ghostID)
        }
        setupAccessibility()
        // M3: notes/links/tasks/tags closures (DocumentWindowController+Content).
        setupContent()
        // F-REL: connection interactions and the relation accessibility
        // hooks route through the same store paths as the menus.
        installRelationHandlers()
        // M3 media: images, markers, attachments, sources, filters
        // (DocumentWindowController+Media + MediaCoordinator).
        mediaCoordinator.attach(self)
        // §4.1/§7.1 chrome: the customizable toolbar and the minimap.
        installChrome()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The live draft of an open editing session: the scene is rebuilt
    /// with it so the node grows while typing (F-EDT-8). Cleared on
    /// commit (the draft becomes the model's title).
    var editingDraftTitle: (id: String, title: NodeTitle)?

    /// Per-document scene build caches for the incremental path (SPEC
    /// §11.3): measured sizes and per-root layout state, filled by every
    /// full build and reused by `modelDidChange`'s small-change path.
    /// Variant-tagged: an appearance flip replaces it wholesale.
    var sceneCache: SceneBuildCache?

    /// Above this many dirty ids the incremental path stops paying off;
    /// §11.5 additionally wants such large relayouts (> 2k dirty nodes)
    /// computed on a background actor — a documented follow-up. Until
    /// then the host falls back to a full rebuild.
    private static let incrementalDirtyLimit = 2_000

    /// M3: the open note popover session (one `setNote` on close);
    /// and the cross-document `x-arbor://` link seam (F-REL-5,
    /// deferred — stored here because extensions can't hold state).
    var notePopoverHolder: NotePopoverHolder?
    var onOpenExternalDocument: ((String, String?) -> Void)?

    /// The document is only wired up after `addWindowController` returns,
    /// and the window reaches its real content size once shown — so the
    /// first scene build and fit run here, not in `init`.
    override func showWindow(_ sender: Any?) {
        // F-CAN-3: seed the placeholder root before the first scene
        // build, so a brand-new document opens with its centred root
        // already editing.
        let placeholderRootID = seedUntitledPlaceholderRoot()
        if canvas.scene == nil {
            updateScene(preserveCamera: false)
        }
        // M4: the outline pane builds its rows before it can be shown
        // (⌘2/⌘3 or a restored active view).
        outlineController.reloadPreservingSelection()
        // F-DOC-4: a document from a newer app version shows its
        // read-only banner from the first frame.
        installReadOnlyBannerIfNeeded()
        super.showWindow(sender)
        // The inspector's first install (persisted preference) and
        // snapshot; later refreshes ride selection and model changes.
        inspectorWindowDidShow()
        // F-CAN-8: a stored view state restores the camera and the
        // (sanitized) selection INSTEAD of zoom-to-fit; only a document
        // with no sidecar (or a corrupt one) fits.
        if restoreViewState() {
            canvas.needsInitialFit = false
        } else if canvas.needsInitialFit {
            canvas.zoomToFit()
            canvas.needsInitialFit = false
        }
        if let rootID = placeholderRootID {
            // Fitting a single empty node would zoom to 400%; sit at 100%
            // with the node centered instead (F-CAN-3).
            if let frame = canvas.scene?.nodes[rootID]?.frame {
                canvas.camera = Camera(
                    origin: CGPoint(
                        x: frame.midX - canvas.bounds.midX,
                        y: frame.midY - canvas.bounds.midY),
                    scale: 1)
            }
            canvas.setSelection([rootID])
            canvas.beginEditing(nodeID: rootID, placeholder: "Central Idea")
            // F-ONB-4: the keyboard-first tip rides the brand-new
            // document's first frame.
            showTipOnce(TipCenter.keyboardFirstTip)
        }
        // The camera may not have changed (a restored state that equals
        // the default never fired `onCameraChange`), so seed the minimap
        // and the zoom % once, then validate the toolbar.
        syncMinimapCamera()
        documentToolbar?.validateVisibleItems()
    }

    /// F-CAN-3: an untitled, still-empty document gets its placeholder
    /// root. Model surgery, not a command: the fresh document stays
    /// pristine (not edited, nothing to undo) until the user types. The
    /// root's title stays empty — "Central Idea" is an editing hint, not
    /// text.
    private func seedUntitledPlaceholderRoot() -> String? {
        guard let mapDocument = document as? MapDocument else { return nil }
        guard mapDocument.fileURL == nil, mapDocument.model.roots.isEmpty else { return nil }
        var model = mapDocument.model
        let root = Node(id: UUID().uuidString)
        model.nodes[root.id] = root
        model.roots = [root.id]
        mapDocument.store.replaceModel(model)
        return root.id
    }

    /// F-AI-2/F-AI-3/F-AI-4: the per-window AI assistant. Owned here,
    /// handed a weak `host` back in init; all provider consent and
    /// privacy gating lives in it (see App/Sources/AI/).
    let ai = AIController()

    /// The theme variant for the current model and system appearance.
    /// (Internal since M6: the presentation coordinator resolves the
    /// same variant for its derived scenes.)
    func currentVariant() -> ThemeVariant {
        guard let mapDocument = document as? MapDocument else { return .light }
        switch mapDocument.model.appearance {
        case .dark:
            return .dark
        case .light:
            return .light
        case .auto, .none:
            return canvas.effectiveVariant
        }
    }

    /// The AI ghost probe rebuild needs the same variant the canvas
    /// shows (AIController).
    var effectiveThemeVariant: ThemeVariant {
        currentVariant()
    }

    /// Rebuilds the scene from the store's model at the view's effective
    /// appearance. The document's explicit override wins; `auto` follows
    /// the system (and re-renders when it changes). An open editing
    /// session's live draft overrides the editing node's title so the
    /// node grows while typing (F-EDT-8). The full build also fills the
    /// per-document scene cache for the incremental path.
    func updateScene(preserveCamera: Bool) {
        guard let mapDocument = document as? MapDocument else { return }
        // F-FOC (find): the rendering model may temporarily unfold the
        // current match's folded ancestors — a view-level value copy,
        // never the document's model (FocusFindCoordinator).
        var model = focusFind.renderingModel(base: mapDocument.store.model)
        // F-STY-4: a live theme preview (hover) overrides the stored
        // selection for this build only — the model is untouched.
        previewThemeOverride(for: &model)
        let previousCamera = canvas.camera
        let variant = currentVariant()
        // F-LAY-12: the user-level spacing rhythm (the inspector's
        // Layout pane is its editor).
        let spacing = effectiveLayoutSpacing
        let cache: SceneBuildCache
        if let existing = sceneCache, existing.variant == variant, existing.spacing == spacing {
            cache = existing
        } else {
            cache = SceneBuildCache(variant: variant, spacing: spacing)
            sceneCache = cache
        }
        // M3 media: the document's thumbnail/SF-glyph/math lookup
        // (MediaCoordinator) and the hide-mode filter's pruned ids.
        mediaCoordinator.configureSceneMedia(cache)
        let scene = SceneGeometry.build(
            model: model,
            cache: cache,
            variant: variant,
            measurer: SceneRenderer.sharedMeasurer,
            spacing: spacing,
            showsTagPills: showsTagPills,
            prunedIDs: mediaCoordinator.prunedIDs(model: model),
            editingTitle: editingDraftTitle,
            theme: ThemeCatalog.shared.theme(for: model))
        canvas.scene = scene
        // F-CAN-6: the minimap mirrors the rebuilt scene (its cached
        // image re-renders here, on scene change only).
        minimap?.scene = scene
        // The scene's source model, for drag-target resolution (F-EDT-5).
        canvas.dragModel = model
        if preserveCamera {
            canvas.camera = previousCamera
        } else {
            canvas.zoomToFit()
        }
    }

    /// Live typing growth (F-EDT-8): the draft title re-measures one node
    /// and relayouts through the incremental path — the §11.8 keystroke
    /// budget. Falls back to a full rebuild when no matching cache exists
    /// (first scene, appearance flip).
    private func updateDraftScene() {
        guard let mapDocument = document as? MapDocument,
            let cache = sceneCacheFor(
                variant: currentVariant(), spacing: effectiveLayoutSpacing),
            let id = editingDraftTitle?.id
        else {
            updateScene(preserveCamera: true)
            return
        }
        let model = mapDocument.store.model
        let scene = SceneGeometry.update(
            model: model,
            cache: cache,
            variant: currentVariant(),
            measurer: SceneRenderer.sharedMeasurer,
            spacing: effectiveLayoutSpacing,
            dirty: [id],
            editingTitle: editingDraftTitle,
            theme: ThemeCatalog.shared.theme(for: model))
        canvas.scene = scene
        canvas.dragModel = model
    }

    /// The document's scene cache when it matches the current variant
    /// and spacing, else nil — the caller falls back to a full rebuild.
    private func sceneCacheForCurrentVariant() -> SceneBuildCache? {
        sceneCacheFor(variant: currentVariant(), spacing: effectiveLayoutSpacing)
    }

    /// After any store change (perform, undo, redo): rebuild the scene —
    /// through the incremental path when the change set is small (SPEC
    /// §11.3's `Layout.update(dirty:)`), in full otherwise — keeping the
    /// camera, dropping selection ids that fell out of the scene, and
    /// keeping the window title on the auto-derived display name
    /// (F-EDT-14).
    func modelDidChange(origin: MapStore.ChangeOrigin) {
        guard let mapDocument = document as? MapDocument else { return }
        let model = mapDocument.store.model
        // F-AI-2: the expansion target may have been deleted or folded
        // away — drop the ghosts instead of accepting into a void.
        ai.modelDidChange()
        let command: MapCommand
        switch origin {
        case .perform(let performed), .undo(let performed), .redo(let performed),
            .nonUndoable(let performed):
            command = performed
        }
        let dirty = SceneGeometry.dirtyIDs(for: command, in: model)
        // F-TAG-3: hide mode prunes child lists, which the dirty path
        // cannot see — every change takes the full rebuild while a
        // hide-mode filter is active (a documented contract).
        if let dirty, mediaCoordinator.prunedIDs(model: model) == nil,
            let cache = sceneCacheForCurrentVariant(),
            dirty.count <= Self.incrementalDirtyLimit
        {
            let scene = SceneGeometry.update(
                model: model,
                cache: cache,
                variant: currentVariant(),
                measurer: SceneRenderer.sharedMeasurer,
                spacing: effectiveLayoutSpacing,
                dirty: dirty,
                editingTitle: editingDraftTitle,
                theme: ThemeCatalog.shared.theme(for: model))
            canvas.scene = scene
            canvas.dragModel = model
        } else {
            updateScene(preserveCamera: true)
        }
        canvas.pruneSelection()
        outlineController.reloadPreservingSelection()
        // F-TAG-3: the filter bar's document-driven popups (tags,
        // types, saved filters) follow the change.
        mediaCoordinator.refreshFilterBar()
        // The inspector follows every store change (theme, appearance,
        // structure, style edits included).
        inspector.refresh()
        // §6.3: the bar repositions against the rebuilt scene.
        contextualBar.reposition()
        // F-FOC: refresh the find matches and the dimming against the
        // post-change model.
        focusFind.sceneDidChange()
        // F-STD-6: a live mastery overlay recolors after every change
        // (a grading moves a card's retrievability bucket).
        applyMasteryOverlay()
        // F-STD-5: recall is view state over the scene; a real edit
        // (the shield blocks canvas gestures, but menus still fire)
        // ends the mode so the overlay can never go stale against the
        // tree. A grading write (ADR-0015, keys 1/2) keeps it alive.
        if case .nonUndoable = origin {
        } else {
            recallSessionBox?.stop()
        }
        window?.title = document?.displayName ?? window?.title ?? ""
        // M6 (F-PRE-2): authored slide changes rebuild the sidebar.
        refreshSlidesSidebar()
        // F-ONB-4: a map crossing the fold-tip threshold gets (at most)
        // the session's one tip.
        showMapGrewTipIfNeeded(nodeCount: model.nodes.count)
    }

    // MARK: view state (F-CAN-8, ADR-0005)

    /// Debounces a view-state save after camera/selection moves — the
    /// state is comfort data, a pan is not a mutation, so it persists
    /// off the document and never touches the change count.
    func scheduleViewStateSave() {
        viewStateSaveTask?.cancel()
        let delay = viewStateSaveDelay
        viewStateSaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.saveViewStateNow()
        }
    }

    /// Flushes the current camera + selection to the sidecar. A write
    /// failure is deliberately non-fatal: view state can never block the
    /// app (ADR-0005's "missing sidecar = fresh default" reads the same).
    func saveViewStateNow() {
        viewStateSaveTask?.cancel()
        guard let mapDocument = document as? MapDocument else { return }
        let state = CanvasViewState(
            camera: canvas.camera, selection: canvas.selection.sorted(), activeView: activeViewMode)
        try? viewStateStore.save(state, docID: mapDocument.model.docID)
    }

    /// Window close (which every document close funnels through): flush
    /// immediately — a debounced save could otherwise be cancelled by
    /// teardown before firing. (The delegate method isn't exposed to
    /// Swift through NSWindowController, hence no `override`.)
    func windowWillClose(_ notification: Notification) {
        saveViewStateNow()
        contextualBar.dismiss()
    }

    /// Reopen restore: the stored camera and selection come back as they
    /// were, selection sanitized against the freshly built scene (ids
    /// deleted or folded away since the last session drop out).
    private func restoreViewState() -> Bool {
        guard let mapDocument = document as? MapDocument,
            let scene = canvas.scene,
            let stored = viewStateStore.load(docID: mapDocument.model.docID)
        else { return false }
        let state = stored.sanitized(for: scene)
        canvas.camera = state.camera
        canvas.setSelection(Set(state.selection))
        // M4 (F-OUT-1): the restored view mode (⌘1/⌘2/⌘3) comes back
        // with the camera; the default for a fresh sidecar is ⌘1.
        if state.activeView != activeViewMode {
            applyViewMode(state.activeView)
        }
        return true
    }
}

/// First-responder editing actions (SPEC §6.1). The menu items and their
/// key equivalents route here through the responder chain (the canvas is
/// first responder, this controller and the document follow); every
/// mutation goes through the document's `MapStore`, and the scene
/// rebuild + selection repair run through `modelDidChange`.
extension DocumentWindowController {
    /// The document's editing gateway. Internal: the M3 content surface
    /// (DocumentWindowController+Content.swift) performs its commands
    /// through the same one-undo-step path as every other action.
    var store: MapStore? {
        (document as? MapDocument)?.store
    }

    /// The selection, sorted for deterministic command order.
    var selectedIDs: [String] {
        canvas.selection.sorted()
    }

    /// One grouped command from `commands`, or nil when empty.
    func grouped(_ name: String, _ commands: [MapCommand]) -> MapCommand? {
        switch commands.count {
        case 0:
            nil
        case 1:
            commands[0]
        default:
            .group(name: name, commands: commands)
        }
    }

    /// Selection ids no other selected id is an ancestor of, so
    /// duplicate and delete-promote never act on a node twice.
    func topmostSelectedIDs(in model: MapModel) -> [String] {
        selectedIDs.filter { id in
            var parent = model.nodes[id]?.parent
            while let parentID = parent {
                if canvas.selection.contains(parentID) { return false }
                parent = model.nodes[parentID]?.parent
            }
            return true
        }
    }

    /// Builds one grouped add command over the selection, selects the
    /// fresh nodes afterwards and — when exactly one was created, the
    /// keyboard case — opens the new node in the editor (F-EDT-1).
    private func addCommand(_ make: (String, Node) -> MapCommand) {
        let anchors = selectedIDs
        let nodes = anchors.map { _ in Node(id: UUID().uuidString) }
        var commands: [MapCommand] = []
        for (anchor, node) in zip(anchors, nodes) {
            commands.append(make(anchor, node))
        }
        let created = Set(nodes.map(\.id))
        if let command = grouped("Add Node", commands) {
            perform(command) { _ in created }
            if created.count == 1, let newID = created.first {
                canvas.beginEditing(nodeID: newID)
            }
        }
    }

    // MARK: inline editing (SPEC §11.4, F-EDT-1/2)

    /// One editing commit: ONE `editText` command through the store
    /// (F-DOC-2), the session closed so the next edit of the same node is
    /// its own undo step, then the post-commit create (if any) with the
    /// new node selected and in edit mode. Internal: the hosted tests
    /// drive the real commit path (the M3 smart-typing suites).
    func handleEditingCommit(id: String, title: NodeTitle, next: NodeTextEditor.PostCommitAction) {
        editingDraftTitle = nil
        guard let store else { return }
        if store.model.nodes[id]?.title != title {
            // F-EDT-10 smart typing: one grouped command carries the
            // whole parse — `#tag` tokens, the task prefixes, `$$math$$`,
            // ``` code fences and the `--` note split — so the entire
            // commit is one undo step.
            let parse = SmartTyping.parseCommit(in: title)
            if parse == SmartTyping.CommitParse(title: title) {
                try? store.perform(.editText(id: id, title: title))
            } else {
                try? store.perform(
                    .smartCommit(id: id, parse: parse, in: store.model))
            }
        }
        // One undo step per edit session (F-DOC-2): close the typing
        // session so a second session on this node registers separately.
        store.closeEditSession()
        canvas.setSelection([id])

        switch next {
        case .none:
            break
        case .child:
            createAfterCommit(anchor: id) { .addChild(parent: $0, index: nil, node: $1) }
        case .siblingBelow:
            createAfterCommit(anchor: id) { .addSibling(anchor: $0, before: false, node: $1) }
        case .siblingAbove:
            createAfterCommit(anchor: id) { .addSibling(anchor: $0, before: true, node: $1) }
        case .insertParent:
            createAfterCommit(anchor: id) { .insertParent(anchor: $0, node: $1) }
        }
    }

    /// The create half of commit-and-create (F-EDT-1): one add command
    /// relative to the just-committed node, then edit the fresh node.
    private func createAfterCommit(anchor: String, _ make: (String, Node) -> MapCommand) {
        let node = Node(id: UUID().uuidString)
        perform(make(anchor, node)) { _ in [node.id] }
        canvas.beginEditing(nodeID: node.id)
    }

    /// F-CAN-5: double-click on empty canvas creates a floating root
    /// centered at that point. Roots carry no absolute position, so the
    /// click point is stored as the root's manual `offset` from its auto
    /// slot (SPEC §8.2); `SceneGeometry` applies offsets after auto
    /// layout (also the F-LAY-11 groundwork). One undoable grouped
    /// command, then edit mode.
    private func createFloatingNode(at modelPoint: CGPoint) {
        guard let store else { return }
        let node = Node(id: UUID().uuidString)
        // Probe the post-add layout for the new root's auto slot.
        var probe = store.model
        try? MapCommand.addRoot(index: nil, node: node).apply(to: &probe)
        let probeScene = SceneGeometry.build(
            model: probe, variant: currentVariant(), measurer: SceneRenderer.sharedMeasurer,
            theme: ThemeCatalog.shared.theme(for: probe))
        let autoFrame = probeScene.nodes[node.id]?.frame ?? .zero
        let offset = ModelOffset(
            x: modelPoint.x - autoFrame.midX,
            y: modelPoint.y - autoFrame.midY)
        let command = MapCommand.group(
            name: "Add Node",
            commands: [
                .addRoot(index: nil, node: node),
                .setOffset(id: node.id, offset: offset),
            ])
        do {
            try store.perform(command)
        } catch {
            return
        }
        canvas.setSelection([node.id])
        canvas.beginEditing(nodeID: node.id)
    }

    // MARK: create (F-EDT-1)

    /// ⏎/⌘⏎/F2 on a single selected node edits it instead (F-EDT-2);
    /// while editing, the create keys commit and create (F-EDT-1).
    @objc func editTitleAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.nodeTextEditor.selectAllText()
            return
        }
        guard canvas.selection.count == 1, let id = canvas.selection.first else { return }
        canvas.beginEditing(nodeID: id)
    }

    @objc func addChildAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .child)
            return
        }
        // F-AI-2: ⇥ with ghosts presented accepts ALL suggestions —
        // one grouped command, one undo step, author .ai.
        if ai.presentingGhosts {
            ai.acceptAll()
            return
        }
        addCommand { .addChild(parent: $0, index: nil, node: $1) }
    }

    @objc func addSiblingBelowAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .siblingBelow)
            return
        }
        if canvas.selection.count == 1, let id = canvas.selection.first {
            // F-EDT-2: ⏎ on a selected node enters edit mode.
            canvas.beginEditing(nodeID: id)
            return
        }
        addCommand { .addSibling(anchor: $0, before: false, node: $1) }
    }

    /// Always creates a sibling below the selection, without ⏎'s
    /// enter-edit rule — for callers with no keyboard context, such as
    /// VoiceOver's Add Sibling action and the toolbar button.
    @objc func addSiblingBelow(_ sender: Any?) {
        addCommand { .addSibling(anchor: $0, before: false, node: $1) }
    }

    @objc func addSiblingAboveAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .siblingAbove)
            return
        }
        addCommand { .addSibling(anchor: $0, before: true, node: $1) }
    }

    @objc func insertParentAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .insertParent)
            return
        }
        addCommand { .insertParent(anchor: $0, node: $1) }
    }

    @objc func addRootAction(_ sender: Any?) {
        if canvas.isEditing {
            // ⇧⏎ inside the text is a line break, not a new root (F-EDT-1).
            canvas.nodeTextEditor.insertLineBreak()
            return
        }
        let node = Node(id: UUID().uuidString)
        perform(.addRoot(index: nil, node: node)) { _ in [node.id] }
        canvas.beginEditing(nodeID: node.id)
    }

    // MARK: delete (F-EDT-4)

    @objc func deleteSubtreeAction(_ sender: Any?) {
        if canvas.isEditing {
            // ⌫/⌦ during editing edit the text; the Delete menu key
            // equivalents must never delete the node being edited.
            let forwardDelete = (sender as? NSMenuItem)?.keyEquivalent == "\u{f728}"
            canvas.nodeTextEditor.deleteInEditor(forward: forwardDelete)
            return
        }
        // F-REL-1: ⌫ on a selected connection deletes the connection,
        // not a node.
        if deleteConnectionSelection() { return }
        guard let store, !canvas.selection.isEmpty else { return }
        let ids = topmostSelectedIDs(in: store.model)
        guard !ids.isEmpty else { return }
        let replacement = MapStore.selectionAfterDelete(
            model: store.model, deletedIDs: ids, selection: canvas.selection)
        perform(.deleteSubtrees(ids: ids)) { _ in replacement }
    }

    @objc func deleteNodeOnlyAction(_ sender: Any?) {
        if canvas.isEditing {
            let forwardDelete = (sender as? NSMenuItem)?.keyEquivalent == "\u{f728}"
            canvas.nodeTextEditor.deleteInEditor(forward: forwardDelete)
            return
        }
        guard let store, !canvas.selection.isEmpty else { return }
        let ids = topmostSelectedIDs(in: store.model)
        guard !ids.isEmpty else { return }
        let commands = ids.map { MapCommand.deleteNodePromotingChildren(id: $0) }
        let replacement = MapStore.selectionAfterDelete(
            model: store.model, deletedIDs: ids, selection: canvas.selection)
        if let command = grouped("Delete Node", commands) {
            perform(command) { _ in replacement }
        }
    }

    // MARK: move (F-EDT-6)

    @objc func duplicateAction(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        var commands: [MapCommand] = []
        var copyRoots: [String] = []
        for id in topmostSelectedIDs(in: store.model) {
            guard let command = try? MapCommand.duplicate(id: id, in: store.model) else { continue }
            if case .insertSubtrees(_, let anchors) = command, let anchor = anchors.first {
                copyRoots.append(anchor.id)
            }
            commands.append(command)
        }
        if let command = grouped("Duplicate Node", commands) {
            perform(command) { _ in Set(copyRoots) }
        }
    }

    @objc func detachAction(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        // Roots have nothing to detach from; the rest become new roots.
        let detachable = selectedIDs.filter { store.model.nodes[$0]?.parent != nil }
        let commands = detachable.map { MapCommand.detach(id: $0) }
        if let command = grouped("Move Node", commands) {
            performKeepingSelection(command)
        }
    }

    @objc func reorderUpAction(_ sender: Any?) {
        reorder(delta: -1)
    }

    @objc func reorderDownAction(_ sender: Any?) {
        reorder(delta: 1)
    }

    private func reorder(delta: Int) {
        guard !canvas.isEditing, let store else { return }
        var moves: [(id: String, slot: Int)] = []
        for id in selectedIDs {
            guard let node = store.model.nodes[id] else { continue }
            let siblings = node.parent.flatMap { store.model.nodes[$0]?.children } ?? store.model.roots
            guard let slot = siblings.firstIndex(of: id) else { continue }
            // Skip nodes already at the target edge: a clamped reorder
            // would register a no-op undo step.
            guard min(max(slot + delta, 0), siblings.count - 1) != slot else { continue }
            moves.append((id, slot))
        }
        // Move the node nearest the target edge first, so adjacent
        // selected siblings shift together instead of swapping places.
        moves.sort { delta < 0 ? $0.slot < $1.slot : $0.slot > $1.slot }
        let commands = moves.map { MapCommand.reorderSibling(id: $0.id, delta: delta) }
        if let command = grouped("Move Node", commands) {
            performKeepingSelection(command)
        }
    }

    /// ⌘← promotes (outdents) and ⌘→ demotes — mirrored on the left
    /// side of a balanced map, where the arrow meaning flips
    /// (F-EDT-6, F-CAN-4).
    @objc func promoteAction(_ sender: Any?) {
        restructure(promote: true)
    }

    @objc func demoteAction(_ sender: Any?) {
        restructure(promote: false)
    }

    private func restructure(promote: Bool) {
        guard !canvas.isEditing, let store else { return }
        var commands: [MapCommand] = []
        for id in selectedIDs {
            guard let node = store.model.nodes[id], let parentID = node.parent else { continue }
            let outdent = promote != canvas.isOnLeftSide(id)
            // Demotion needs a previous sibling; skip nodes without one.
            if !outdent {
                let siblings = store.model.nodes[parentID]?.children ?? []
                guard let slot = siblings.firstIndex(of: id), slot > 0 else { continue }
            }
            commands.append(outdent ? .promote(id: id) : .demote(id: id))
        }
        if let command = grouped("Move Node", commands) {
            performKeepingSelection(command)
        }
    }

    // MARK: select (F-CAN-4)

    @objc func selectAllAction(_ sender: Any?) {
        if canvas.isEditing {
            // ⌘A during editing selects the text, not the map.
            canvas.nodeTextEditor.selectAllText()
            return
        }
        canvas.setSelection(canvas.scene.map { Set($0.nodes.keys) } ?? [])
    }

    @objc func selectChildrenAction(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        let children = Set(
            canvas.selection.flatMap { store.model.nodes[$0]?.children ?? [] })
        canvas.setSelection(children)
    }

    /// The root of the selected node's tree.
    @objc func selectRootAction(_ sender: Any?) {
        guard !canvas.isEditing, let store, let primary = selectedIDs.first else { return }
        var current = primary
        while let parent = store.model.nodes[current]?.parent {
            current = parent
        }
        canvas.setSelection([current])
    }

    @objc func deselectAction(_ sender: Any?) {
        if canvas.isEditing {
            // ⎋ commits; ⎋ again (this action, reached when nothing is
            // editing) deselects (F-EDT-1).
            canvas.commitEditing(next: .none)
            return
        }
        // F-STD-5: while a recall run is live, ⎋ exits it first. The
        // bare-⎋ "Deselect" menu equivalent is how AppKit delivers Esc
        // at the map level (the same route F-FOC's overlays take
        // below) — the shield's performKeyEquivalent usually consumes
        // the key first; this is the menu-item half of the same exit.
        if recallSessionBox != nil {
            recallSessionBox?.stop()
            return
        }
        // F-AI-2: ⎋ with ghosts presented dismisses them first —
        // without touching the document (no undo step, not even dirty).
        if ai.presentingGhosts {
            ai.dismissGhosts()
            return
        }
        // F-FOC: ⎋ first serves the open overlays — the quick-open
        // palette, then the find bar, then Zen, then Focus mode; then
        // the M3 highlight modes (F-TAG-2/F-TSK-5); only when none of
        // them is active does it deselect.
        if focusFind.handleEscape() {
            return
        }
        if canvas.exitHighlightIfActive() {
            return
        }
        canvas.setSelection([])
    }
}
