import AppKit
import CanvasKit
import MapCore
import MapRender

@MainActor
final class DocumentWindowController: NSWindowController {
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

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

        canvas.onEffectiveAppearanceChange = { [weak self] in
            self?.updateScene(preserveCamera: true)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The document is only wired up after `addWindowController` returns,
    /// and the window reaches its real content size once shown — so the
    /// first scene build and fit run here, not in `init`.
    override func showWindow(_ sender: Any?) {
        if canvas.scene == nil {
            updateScene(preserveCamera: false)
        }
        super.showWindow(sender)
        if canvas.needsInitialFit {
            canvas.zoomToFit()
            canvas.needsInitialFit = false
        }
    }

    /// Rebuilds the scene from the store's model at the view's effective
    /// appearance. The document's explicit override wins; `auto` follows
    /// the system (and re-renders when it changes).
    func updateScene(preserveCamera: Bool) {
        guard let mapDocument = document as? MapDocument else { return }
        let model = mapDocument.store.model
        let variant: ThemeVariant
        switch model.appearance {
        case .dark:
            variant = .dark
        case .light:
            variant = .light
        case .auto, .none:
            variant = canvas.effectiveVariant
        }
        let previousCamera = canvas.camera
        let scene = SceneGeometry.build(
            model: model,
            variant: variant,
            measurer: SceneRenderer.sharedMeasurer)
        canvas.scene = scene
        if preserveCamera {
            canvas.camera = previousCamera
        } else {
            canvas.zoomToFit()
        }
    }

    /// After any store change (perform, undo, redo): rebuild the scene
    /// keeping the camera, and drop selection ids that fell out of it.
    func modelDidChange() {
        updateScene(preserveCamera: true)
        canvas.pruneSelection()
    }
}

/// First-responder editing actions (SPEC §6.1). The menu items and their
/// key equivalents route here through the responder chain (the canvas is
/// first responder, this controller and the document follow); every
/// mutation goes through the document's `MapStore`, and the scene
/// rebuild + selection repair run through `modelDidChange`.
extension DocumentWindowController {
    private var store: MapStore? {
        (document as? MapDocument)?.store
    }

    /// The selection, sorted for deterministic command order.
    private var selectedIDs: [String] {
        canvas.selection.sorted()
    }

    /// Performs `command`; on success the canvas selects `replacement`
    /// in the rebuilt scene. A throwing command is a no-op (the store
    /// leaves the model untouched).
    private func perform(_ command: MapCommand, selecting replacement: (MapModel) -> Set<String>) {
        guard let store else { return }
        do {
            try store.perform(command)
        } catch {
            return
        }
        canvas.setSelection(replacement(store.model))
    }

    private func performKeepingSelection(_ command: MapCommand) {
        perform(command) { [canvas] _ in canvas.selection }
    }

    /// One grouped command from `commands`, or nil when empty.
    private func grouped(_ name: String, _ commands: [MapCommand]) -> MapCommand? {
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
    private func topmostSelectedIDs(in model: MapModel) -> [String] {
        selectedIDs.filter { id in
            var parent = model.nodes[id]?.parent
            while let parentID = parent {
                if canvas.selection.contains(parentID) { return false }
                parent = model.nodes[parentID]?.parent
            }
            return true
        }
    }

    /// Builds one grouped add command over the selection and selects the
    /// fresh nodes afterwards.
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
        }
    }

    // MARK: create (F-EDT-1)

    @objc func addChildAction(_ sender: Any?) {
        addCommand { .addChild(parent: $0, index: nil, node: $1) }
    }

    @objc func addSiblingBelowAction(_ sender: Any?) {
        addCommand { .addSibling(anchor: $0, before: false, node: $1) }
    }

    @objc func addSiblingAboveAction(_ sender: Any?) {
        addCommand { .addSibling(anchor: $0, before: true, node: $1) }
    }

    @objc func insertParentAction(_ sender: Any?) {
        addCommand { .insertParent(anchor: $0, node: $1) }
    }

    @objc func addRootAction(_ sender: Any?) {
        let node = Node(id: UUID().uuidString)
        perform(.addRoot(index: nil, node: node)) { _ in [node.id] }
    }

    // MARK: delete (F-EDT-4)

    @objc func deleteSubtreeAction(_ sender: Any?) {
        guard let store, !canvas.selection.isEmpty else { return }
        let ids = topmostSelectedIDs(in: store.model)
        guard !ids.isEmpty else { return }
        let replacement = MapStore.selectionAfterDelete(
            model: store.model, deletedIDs: ids, selection: canvas.selection)
        perform(.deleteSubtrees(ids: ids)) { _ in replacement }
    }

    @objc func deleteNodeOnlyAction(_ sender: Any?) {
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
        guard let store else { return }
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
        guard let store else { return }
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
        guard let store else { return }
        var commands: [MapCommand] = []
        for id in selectedIDs {
            guard let node = store.model.nodes[id] else { continue }
            let siblings = node.parent.flatMap { store.model.nodes[$0]?.children } ?? store.model.roots
            guard let slot = siblings.firstIndex(of: id) else { continue }
            // Skip nodes already at the target edge: a clamped reorder
            // would register a no-op undo step.
            guard min(max(slot + delta, 0), siblings.count - 1) != slot else { continue }
            commands.append(.reorderSibling(id: id, delta: delta))
        }
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
        guard let store else { return }
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

    // MARK: fold (F-LAY-14)

    @objc func toggleFoldAction(_ sender: Any?) {
        guard let store else { return }
        var commands: [MapCommand] = []
        for id in selectedIDs {
            guard let node = store.model.nodes[id] else { continue }
            commands.append(.setFolded(id: id, folded: !node.folded))
        }
        if let command = grouped("Fold Node", commands) {
            performKeepingSelection(command)
        }
    }

    // MARK: select (F-CAN-4)

    @objc func selectAllAction(_ sender: Any?) {
        canvas.setSelection(canvas.scene.map { Set($0.nodes.keys) } ?? [])
    }

    @objc func selectChildrenAction(_ sender: Any?) {
        guard let store else { return }
        let children = Set(
            canvas.selection.flatMap { store.model.nodes[$0]?.children ?? [] })
        canvas.setSelection(children)
    }

    /// The root of the selected node's tree.
    @objc func selectRootAction(_ sender: Any?) {
        guard let store, let primary = selectedIDs.first else { return }
        var current = primary
        while let parent = store.model.nodes[current]?.parent {
            current = parent
        }
        canvas.setSelection([current])
    }

    @objc func deselectAction(_ sender: Any?) {
        canvas.setSelection([])
    }
}
