import AppKit
import CanvasKit
import MapCore

/// The F-FOC state machine (SPEC §5.10): find & replace, Focus mode,
/// Zen mode and Quick Open / Command Palette for one document window.
/// All state is view-level and lives here; every MODEL mutation still
/// goes through the document's `MapStore` as one `MapCommand` — the
/// temporary unfold of a folded find match is a value-copy passed to
/// the scene build only (never a command, never persisted, never an
/// undo step), while Quick Open's reveal DOES commit a grouped
/// `setFolded` — but only when the user commits the jump (ADR-0013).
@MainActor
final class FocusFindCoordinator {
    weak var controller: DocumentWindowController?

    // MARK: find state (F-FOC-3)

    private(set) var findQuery = ""
    private(set) var includesTags = false
    private(set) var matches: [FindMatch] = []
    private(set) var currentMatchIndex: Int?
    private(set) var isFindBarVisible = false
    private(set) var isReplaceVisible = false
    private var findBar: FindBarView?

    // MARK: focus state (F-FOC-1)

    private(set) var focusAnchorID: String?
    private var preFocusCamera: Camera?

    // MARK: zen state (F-FOC-2)

    private(set) var isZenActive = false
    /// Injectable so hosted tests skip a real full-screen transition.
    var zenUsesFullScreen = true
    private var enteredFullScreenForZen = false
    private var zenChrome: ZenChromeSnapshot?
    private(set) var zenTimer: BrainstormTimer?
    private var zenTimerOverlay: ZenTimerOverlay?

    // MARK: quick open state (F-FOC-4)

    private(set) var quickOpen: QuickOpenPanelController?

    private let cameraTween = CameraTween()

    /// The find bar's dedicated field editor (see
    /// `windowWillReturnFieldEditor` in DocumentWindowController+FocusFind).
    private(set) lazy var fieldEditor = FindFieldEditor(frame: .zero)

    private var canvas: CanvasView? { controller?.canvas }
    private var model: MapModel? { controller?.focusFindModel }

    var isFindActive: Bool { isFindBarVisible }

    // MARK: the rendering model (temporary unfold, view-level only)

    /// The model the scene is built from: the store's model, with the
    /// current find match's folded ancestors temporarily unfolded.
    /// A pure value copy — the document's model, the undo stack and
    /// the saved file are never touched (F-FOC-3).
    func renderingModel(base: MapModel) -> MapModel {
        guard isFindBarVisible, let index = currentMatchIndex, matches.indices.contains(index)
        else { return base }
        return FindEngine.modelUnfoldingAncestors(of: matches[index].nodeID, in: base)
    }

    // MARK: Escape routing

    /// The one Esc handler, tried before the Deselect action runs:
    /// quick open → find bar → zen → focus; false lets the press fall
    /// through to deselect.
    func handleEscape() -> Bool {
        if quickOpen != nil {
            closeQuickOpen()
            return true
        }
        if isFindBarVisible {
            hideFindBar()
            return true
        }
        if isZenActive {
            exitZenMode()
            return true
        }
        if focusAnchorID != nil {
            exitFocusMode()
            return true
        }
        return false
    }

    // MARK: scene & selection sync (called by the controller's hooks)

    /// After any store change: refresh the search against the new
    /// model, re-pin the overlays, and exit modes whose anchor died.
    func sceneDidChange() {
        if let model {
            if isFindBarVisible {
                refreshMatches(in: model)
            }
            refreshFocusAnchors(in: model)
        }
        refreshDimming()
    }

    /// After a canvas selection change: inside Focus (and Zen), the
    /// focus follows the selection (F-FOC-1: "navigation inside focus
    /// moves the focus").
    func selectionDidChange() {
        guard focusAnchorID != nil || isZenActive else { return }
        guard let model, let canvas else { return }
        guard let anchor = canvas.selection.first else { return }
        guard anchor != focusAnchorID else { return }
        focusAnchorID = anchor
        applyFocusDimming(around: anchor, in: model, animated: true)
        if !isZenActive {
            fitCameraToFocus()
        }
    }

    // MARK: Find (F-FOC-3)

    func showFindBar(replace: Bool) {
        guard let controller, let window = controller.window else { return }
        controller.canvas.commitEditing(next: .none)

        if findBar == nil {
            let bar = FindBarView()
            wireFindBar(bar)
            findBar = bar
        }
        guard let bar = findBar else { return }
        isFindBarVisible = true
        isReplaceVisible = replace
        bar.setReplaceVisible(replace)
        if window.contentView !== bar, bar.superview == nil {
            window.contentView?.addSubview(bar)
        }
        positionFindBar()
        if replace {
            bar.query = ""
            setFindQuery("")
        }
        bar.focusFindField()
    }

    func hideFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        isReplaceVisible = false
        findBar?.removeFromSuperview()
        if let canvas {
            canvas.overlays.clearFindHighlights()
        }
        // Rebuild from the true model: any temporarily-unfolded match
        // collapses again (F-FOC-3).
        controller?.focusFindRebuildScene()
    }

    /// Live search on every keystroke: recompute the matches, select
    /// the first, follow it with the camera, ring every match.
    func setFindQuery(_ query: String) {
        guard let model else { return }
        findQuery = query
        matches = FindEngine.matches(
            query: query, options: FindOptions(includeTags: includesTags), in: model)
        currentMatchIndex = matches.isEmpty ? nil : 0
        ensureCurrentMatchVisible()
        updateFindOverlays()
        announceFindStatus()
    }

    /// ⌘G / ⇧⌘G: step with wrap-around (F-FOC-3).
    func findNext() {
        stepMatch(forwards: true)
    }

    func findPrevious() {
        stepMatch(forwards: false)
    }

    func toggleTagSearch(_ include: Bool) {
        includesTags = include
        setFindQuery(findQuery)
    }

    /// ⌘E: the selection's title becomes the query.
    func useSelectionForFind() {
        guard let model, let canvas, let selected = canvas.selection.first,
            model.nodes[selected] != nil
        else { return }
        let title = model.nodes[selected]?.title.text ?? ""
        guard !title.isEmpty else { return }
        showFindBar(replace: false)
        findBar?.query = title
        setFindQuery(title)
    }

    /// Replace (⌥⌘F bar): rewrites every occurrence inside the current
    /// match's field as ONE command (one undo step), then re-searches
    /// and advances.
    func replaceCurrent(with replacement: String) {
        guard let model, let index = currentMatchIndex, matches.indices.contains(index) else {
            return
        }
        let match = matches[index]
        let command = replaceCommand(for: match, with: replacement, in: model)
        guard let command else { return }
        controller?.focusFindPerform(command, selecting: [match.nodeID])
        // The store change rebuilt the scene and `sceneDidChange`
        // refreshed the matches; advance from there.
        stepMatch(forwards: true)
    }

    /// Replace All: ONE grouped command over every title and note —
    /// one undo step (F-FOC-3) — runs preserved around the ranges.
    func replaceAll(with replacement: String) {
        guard let model else { return }
        guard
            let command = FindEngine.replaceAllCommand(
                query: findQuery, replacement: replacement,
                options: FindOptions(includeTags: includesTags), in: model)
        else { return }
        controller?.focusFindPerform(command, selecting: [])
        // sceneDidChange re-ran the search against the replaced model.
        updateFindOverlays()
        announce("Replaced all occurrences")
    }
}

// MARK: - Focus & Zen (F-FOC-1/2)

extension FocusFindCoordinator {
    // MARK: Focus mode (F-FOC-1)

    /// ⇧⌘F: dims everything outside the selected node's subtree +
    /// ancestor path to 15% and animates a zoom-to-fit of it.
    func toggleFocusMode() {
        if focusAnchorID != nil {
            exitFocusMode()
        } else {
            enterFocusMode()
        }
    }

    func enterFocusMode() {
        guard let model, let canvas else { return }
        canvas.commitEditing(next: .none)
        closeQuickOpen()
        let anchor = canvas.selection.first ?? model.roots.first
        guard let anchor, model.nodes[anchor] != nil else { return }
        if isZenActive {
            // Zen owns the dimming; leave it and let focus take over.
            exitZenMode()
        }
        focusAnchorID = anchor
        preFocusCamera = canvas.camera
        applyFocusDimming(around: anchor, in: model, animated: true)
        fitCameraToFocus()
        if let title = model.nodes[anchor]?.title.text, !title.isEmpty {
            announce("Focus mode, \(title)")
        } else {
            announce("Focus mode")
        }
    }

    func exitFocusMode() {
        guard focusAnchorID != nil, let canvas else { return }
        focusAnchorID = nil
        canvas.overlays.clearDimming(canvas, animated: true)
        if let preFocusCamera {
            animateCamera(to: preFocusCamera)
        }
        preFocusCamera = nil
        announce("Focus mode off")
    }

    // MARK: Zen mode (F-FOC-2)

    /// ⌃⌘F: full screen, chrome hidden, current branch dimmed in,
    /// brainstorm timer available.
    func toggleZenMode() {
        if isZenActive {
            exitZenMode()
        } else {
            enterZenMode()
        }
    }

    func enterZenMode() {
        guard let controller, let window = controller.window, let canvas else { return }
        canvas.commitEditing(next: .none)
        closeQuickOpen()
        isZenActive = true

        // Chrome: captured generically, tolerated when absent (no
        // toolbar, no split view, no minimap yet — see
        // ZenChromeSnapshot).
        let snapshot = ZenChromeSnapshot.capture(window: window, protectedView: canvas)
        zenChrome = snapshot
        snapshot.applyHidden()

        enteredFullScreenForZen = false
        if zenUsesFullScreen, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            enteredFullScreenForZen = true
        }

        // Dim all but the current branch (the selection's focus set).
        if let model {
            let anchor = canvas.selection.first ?? model.roots.first
            if let anchor {
                focusAnchorID = anchor
                applyFocusDimming(around: anchor, in: model, animated: true)
            }
        }

        // The brainstorm timer corner overlay.
        let overlay = ZenTimerOverlay()
        overlay.onPick = { [weak self] minutes in
            self?.startBrainstormTimer(minutes: minutes)
        }
        zenTimerOverlay = overlay
        if window.contentView !== overlay, overlay.superview == nil {
            window.contentView?.addSubview(overlay)
        }
        positionZenTimerOverlay()
        announce("Zen mode")
    }

    func exitZenMode() {
        guard isZenActive, let window = controller?.window else { return }
        isZenActive = false
        zenChrome?.restore()
        zenChrome = nil
        if enteredFullScreenForZen, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        enteredFullScreenForZen = false
        cancelBrainstormTimer()
        zenTimerOverlay?.removeFromSuperview()
        zenTimerOverlay = nil
        if let canvas {
            canvas.overlays.clearDimming(canvas, animated: true)
        }
        focusAnchorID = nil
        announce("Zen mode off")
    }

    func startBrainstormTimer(minutes: Int) {
        guard isZenActive else { return }
        zenTimerOverlay?.startTimer(minutes)
        zenTimer = zenTimerOverlay?.timer
    }

    func cancelBrainstormTimer() {
        zenTimerOverlay?.cancelTimer()
        zenTimer = nil
    }
}

// MARK: - Quick Open / Command Palette (F-FOC-4)

extension FocusFindCoordinator {
    // MARK: Quick Open / Command Palette (F-FOC-4)

    /// ⇧⌘O: fuzzy-jump to any node; ⇧⌘P: every enabled menu command.
    func openQuickOpen(mode: QuickOpenMode) {
        guard let controller else { return }
        controller.canvas.commitEditing(next: .none)
        closeQuickOpen()

        let items: [QuickOpenItem]
        switch mode {
        case .nodes:
            items = nodeItems()
        case .commands:
            items = commandItems()
        }
        let panelController = QuickOpenPanelController(mode: mode, items: items)
        panelController.model.onCommit = { [weak self] item in
            guard let self else { return }
            self.closeQuickOpen()
            switch item.kind {
            case .node(let id):
                self.jump(toNodeID: id)
            case .command(let entry):
                MenuCommandListing.perform(entry)
            }
        }
        panelController.model.onCancel = { [weak self] in
            self?.closeQuickOpen()
        }
        quickOpen = panelController
        panelController.show(relativeTo: controller.window)
    }

    func closeQuickOpen() {
        quickOpen?.close()
        quickOpen = nil
    }

    /// The ⇧⌘O commit: select and reveal the node. Folded ancestors on
    /// the node's path expand via ONE grouped `setFolded` command —
    /// a real, undoable, persisted change, but issued only when the
    /// user commits the jump, never while browsing results (ADR-0013).
    func jump(toNodeID id: String) {
        guard let model, let controller else { return }
        let canvas = controller.canvas

        let foldedAncestors = FindEngine.foldedAncestors(of: id, in: model)
        if !foldedAncestors.isEmpty {
            let commands = foldedAncestors.map { MapCommand.setFolded(id: $0, folded: false) }
            let grouped =
                commands.count == 1
                ? commands[0] : MapCommand.group(name: "Reveal Node", commands: commands)
            controller.focusFindPerform(grouped, selecting: [id])
        } else {
            canvas.setSelection([id])
            controller.focusFindRebuildScene()
        }
        canvas.scrollSelectionIntoView()
        if let title = model.nodes[id]?.title.text, !title.isEmpty {
            announce("Jumped to \(title)")
        }
    }
}

// MARK: - scene/camera sync & find internals

extension FocusFindCoordinator {
    /// After a camera change (the controller's onCameraChange hook): the
    /// canvas's find rings re-pin at the new camera and dimming re-applies
    /// to whatever the new viewport realized.
    func cameraDidChange() {
        guard let canvas else { return }
        canvas.overlays.cameraDidChange(canvas)
    }

    // MARK: internals — find

    private func wireFindBar(_ bar: FindBarView) {
        bar.onQueryChange = { [weak self] query in
            self?.setFindQuery(query)
        }
        bar.onNext = { [weak self] in
            self?.findNext()
        }
        bar.onPrevious = { [weak self] in
            self?.findPrevious()
        }
        bar.onTagsToggle = { [weak self] include in
            self?.toggleTagSearch(include)
        }
        bar.onCancel = { [weak self] in
            self?.hideFindBar()
        }
        bar.onReplace = { [weak self] replacement in
            self?.replaceCurrent(with: replacement)
        }
        bar.onReplaceAll = { [weak self] replacement in
            self?.replaceAll(with: replacement)
        }
        bar.setCount("")
    }

    private func stepMatch(forwards: Bool) {
        guard !matches.isEmpty, let model else { return }
        currentMatchIndex = FindEngine.step(
            index: currentMatchIndex, count: matches.count, forwards: forwards)
        ensureCurrentMatchVisible()
        updateFindOverlays()
        announceFindStatus()
    }

    /// Rebuild the scene when the current match sits behind a fold, so
    /// the temporary unfold path (`renderingModel`) shows it, then
    /// select it and follow with the camera.
    private func ensureCurrentMatchVisible() {
        guard let canvas else { return }
        if let index = currentMatchIndex, matches.indices.contains(index) {
            let nodeID = matches[index].nodeID
            if canvas.scene?.nodes[nodeID] == nil {
                controller?.focusFindRebuildScene()
            }
            canvas.setSelection([nodeID])
            canvas.scrollSelectionIntoView()
        } else if matches.isEmpty {
            // Keep whatever selection the user had; the count label
            // tells the story.
            findBar?.setCount(findQuery.isEmpty ? "" : "No matches")
        }
    }

    /// Rings for every match in the scene, the current one emphasized,
    /// plus the counter label.
    private func updateFindOverlays() {
        guard let canvas else { return }
        let currentID = currentMatchIndex.flatMap { index in
            matches.indices.contains(index) ? matches[index].nodeID : nil
        }
        let visibleMatches = Set(matches.map(\.nodeID).filter { canvas.scene?.nodes[$0] != nil })
        canvas.overlays.showFindHighlights(canvas, matchIDs: visibleMatches, currentID: currentID)
        findBar?.setCount(countLabel())
    }

    private func countLabel() -> String {
        guard !matches.isEmpty, let index = currentMatchIndex else {
            return findQuery.isEmpty ? "" : "No matches"
        }
        return "\(index + 1) of \(matches.count)"
    }

    private func refreshMatches(in model: MapModel) {
        matches = FindEngine.matches(
            query: findQuery, options: FindOptions(includeTags: includesTags), in: model)
        if matches.isEmpty {
            currentMatchIndex = nil
        } else if currentMatchIndex == nil || !matches.indices.contains(currentMatchIndex!) {
            currentMatchIndex = 0
            ensureCurrentMatchVisible()
        }
        updateFindOverlays()
    }

    /// One command replacing every occurrence inside `match`'s field
    /// (titles through `editText` with runs preserved, notes through
    /// `setNote`) — a single undo step per Replace press.
    private func replaceCommand(for match: FindMatch, with replacement: String, in model: MapModel)
        -> MapCommand?
    {
        guard let node = model.nodes[match.nodeID] else { return nil }
        switch match.field {
        case .title:
            let replaced = FindEngine.replacedTitle(
                node.title, replacing: match.ranges, with: replacement)
            guard replaced != node.title else { return nil }
            return .editText(id: match.nodeID, title: replaced)
        case .note:
            guard let note = node.note else { return nil }
            let replaced = FindEngine.replacedNote(note, replacing: match.ranges, with: replacement)
            guard replaced != note else { return nil }
            return .setNote(id: match.nodeID, note: replaced)
        case .tag:
            return nil
        }
    }

    private func announceFindStatus() {
        if matches.isEmpty {
            if !findQuery.isEmpty {
                announce("No matches")
            }
        } else if let index = currentMatchIndex {
            let text = matches[index].text
            let trimmed = text.count > 60 ? String(text.prefix(60)) + "…" : text
            announce("\(countLabel()), \(trimmed)")
        }
    }
}

// MARK: - dimming, camera, item building & announcements

extension FocusFindCoordinator {
    // MARK: internals — dimming & camera

    private func refreshDimming() {
        guard let canvas, let anchor = focusAnchorID else { return }
        canvas.overlays.applyDimming(canvas, focusIDs: dimmingIDs(around: anchor), animated: false)
    }

    private func applyFocusDimming(around anchor: String, in model: MapModel, animated: Bool) {
        guard let canvas else { return }
        canvas.overlays.applyDimming(
            canvas, focusIDs: dimmingIDs(around: anchor), animated: animated)
    }

    private func dimmingIDs(around anchor: String) -> Set<String> {
        guard let model else { return [] }
        return FocusSet.ids(around: anchor, in: model)
    }

    /// Modes whose anchor vanished from the model (undo of a delete,
    /// etc.) exit instead of dimming a ghost set.
    private func refreshFocusAnchors(in model: MapModel) {
        if let anchor = focusAnchorID, model.nodes[anchor] == nil {
            if isZenActive {
                exitZenMode()
            } else {
                exitFocusMode()
            }
        }
    }

    /// The camera that fits the focus set (40 pt padding, §7.6's
    /// camera band via `CameraTween`), or nil when nothing of it is on
    /// screen.
    private func fitCameraToFocus() {
        guard let model, let canvas, let scene = canvas.scene, let anchor = focusAnchorID
        else { return }
        let ids = FocusSet.ids(around: anchor, in: model)
        var content = CGRect.null
        for id in ids {
            if let node = scene.nodes[id] {
                content = content.union(node.frame)
            }
        }
        guard !content.isNull else { return }
        let padded = content.insetBy(dx: -40, dy: -40)
        let scale = min(
            canvas.bounds.width / max(padded.width, 1),
            canvas.bounds.height / max(padded.height, 1),
            4)
        let clamped = min(max(scale, 0.1), 4)
        let target = Camera(
            origin: CGPoint(
                x: padded.midX - canvas.bounds.midX / clamped,
                y: padded.midY - canvas.bounds.midY / clamped),
            scale: clamped)
        animateCamera(to: target)
    }

    private func animateCamera(to target: Camera) {
        guard let canvas else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cameraTween.run(
            from: canvas.camera, to: target, reduceMotion: reduceMotion,
            step: { [weak canvas] camera in
                canvas?.camera = camera
            })
    }

    // MARK: internals — quick open items

    private func nodeItems() -> [QuickOpenItem] {
        guard let model else { return [] }
        var items: [QuickOpenItem] = []
        for id in FindEngine.documentOrder(in: model) {
            guard let node = model.nodes[id] else { continue }
            let title = node.title.text.isEmpty ? "Empty node" : node.title.text
            let path = FocusSet.ancestorPath(of: id, in: model)
                .compactMap { model.nodes[$0]?.title.text }
                .filter { !$0.isEmpty }
            items.append(
                QuickOpenItem(
                    id: "node-\(id)", title: title, subtitle: path.joined(separator: " › "),
                    shortcut: "", kind: .node(id: id)))
        }
        // Seam for the Library (F-FOC-4's "any map in the library",
        // M5): once the library exists, its maps append here.
        return items
    }

    private func commandItems() -> [QuickOpenItem] {
        MenuCommandListing.entries(from: NSApp.mainMenu).map { entry in
            QuickOpenItem(
                id: "command-\(entry.id)", title: entry.path, subtitle: "",
                shortcut: entry.shortcut, kind: .command(entry))
        }
    }

    // MARK: internals — overlays & announcements

    private func positionFindBar() {
        guard let bar = findBar, let container = bar.superview else { return }
        let replaceHeight: CGFloat = isReplaceVisible ? FindBarView.replaceRowHeight : 0
        let barHeight = FindBarView.findRowHeight + replaceHeight
        let width = container.bounds.width
        bar.frame = NSRect(
            x: 0, y: container.bounds.height - barHeight, width: width, height: barHeight)
        bar.autoresizingMask = [.width, .minYMargin]
        bar.needsLayout = true
    }

    private func positionZenTimerOverlay() {
        guard let overlay = zenTimerOverlay, let container = overlay.superview else { return }
        let size = ZenTimerOverlay.diameter
        overlay.frame = NSRect(
            x: container.bounds.width - size - 16, y: 16, width: size, height: size)
        overlay.autoresizingMask = [.minXMargin, .maxYMargin]
    }

    private func announce(_ text: String) {
        guard let canvas else { return }
        NSAccessibility.post(
            element: canvas, notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: text])
    }
}
