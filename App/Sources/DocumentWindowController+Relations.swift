import AppKit
import CanvasKit
import MapCore
import MapRender

/// The relation surface of the document window (F-REL-1/2/3 + F-REL-5's
/// Copy Node Link): every menu action performs exactly ONE command
/// through the document's `MapStore` (SPEC §11.3 — one undo step), and
/// the canvas's interaction callbacks land on the same paths.
extension DocumentWindowController {
    /// Wired once at controller init (the canvas's host hooks).
    func installRelationHandlers() {
        canvas.onCreateConnection = { [weak self] from, to in
            self?.createConnection(from: from, to: to)
        }
        canvas.onMutateConnection = { [weak self] command in
            self?.performRelationCommand(command)
        }
        canvas.accessibility.relationValueText = { [weak self] id in
            self?.relationValueText(for: id)
        }
        canvas.accessibility.connectionPeers = { [weak self] id in
            self?.connectionPeers(for: id) ?? []
        }
        canvas.accessibility.onSelectConnectionPeer = { [weak self] peerID in
            self?.selectAndReveal(peerID)
        }
    }

    // MARK: connections (F-REL-1)

    /// ⌘L (Insert ▸ Connection): with one node selected, the next node
    /// click makes the connection (the canvas's pending mode); with two
    /// nodes selected, they connect right away.
    @objc func addConnectionAction(_ sender: Any?) {
        guard let store, !canvas.isEditing else { return }
        if canvas.selection.count == 2 {
            let pair = canvas.selection.sorted()
            createConnection(from: pair[0], to: pair[1])
            return
        }
        canvas.beginConnectionMode()
    }

    /// One `addConnection` through the store — one undo step; the new
    /// connection joins the connection selection so ⌫ / ⌃⌘L / ⇧⌘L work
    /// on it.
    func createConnection(from: String, to: String) {
        guard let store else { return }
        guard let command = RelationCommands.connect(model: store.model, from: from, to: to)
        else { return }
        let connectionID: String
        if case .addConnection(let connection) = command {
            connectionID = connection.id
        } else {
            connectionID = from
        }
        performRelationCommand(command, selecting: connectionID)
    }

    /// A connection mutation produced by a canvas interaction (label
    /// commit, handle move/reset): one command, one undo step. The
    /// scene rebuild rides the store's `onChange` like every other
    /// mutation; this only repairs the selection.
    func performRelationCommand(_ command: MapCommand, selecting connectionID: String? = nil) {
        guard let store else { return }
        do {
            try store.perform(command)
        } catch {
            return
        }
        if let connectionID {
            canvas.setConnectionSelection([connectionID])
        }
    }

    /// The ⌫ path (deleteSubtreeAction) consults the connection
    /// selection first: selected connections delete as one grouped
    /// removal; node deletion is unchanged.
    func deleteConnectionSelection() -> Bool {
        guard !canvas.selectedConnectionIDs.isEmpty else { return false }
        if let command = RelationCommands.deleteConnections(ids: Array(canvas.selectedConnectionIDs)) {
            performRelationCommand(command)
        }
        return true
    }

    // MARK: boundaries (F-REL-2)

    /// ⌥⌘G (Insert ▸ Boundary): one grouped-subtree boundary from the
    /// selection. No-op (no command, no undo step) when the selection
    /// isn't one family.
    @objc func addBoundaryAction(_ sender: Any?) {
        guard let store, !canvas.isEditing else { return }
        let selection = canvas.selection.sorted()
        guard let command = RelationCommands.boundary(selection: selection, in: store.model)
        else { return }
        performRelationCommand(command)
    }

    // MARK: summaries (F-REL-3)

    /// ⇧⌘] (Insert ▸ Summary): a summary node over the selection's
    /// span, selected and opened for editing — the natural next step is
    /// typing what it all means.
    @objc func addSummaryAction(_ sender: Any?) {
        guard let store, !canvas.isEditing else { return }
        let summaryNodeID = UUID().uuidString
        let selection = canvas.selection.sorted()
        guard
            let command = RelationCommands.summary(
                selection: selection, in: store.model, summaryNodeID: summaryNodeID)
        else { return }
        do {
            try store.perform(command)
        } catch {
            return
        }
        canvas.setConnectionSelection([])
        canvas.setSelection([summaryNodeID])
        canvas.scrollSelectionIntoView()
        canvas.beginEditing(nodeID: summaryNodeID)
    }

    // MARK: copy node link (F-REL-5)

    /// ⌃⌘C (Edit ▸ Copy Node Link): the selected node's cross-map link
    /// (`x-arbor://open?doc=<docID>&node=<nodeID>`, SPEC §8.2) on the
    /// pasteboard, as its own pasteboard item so a ⌘V paste of nodes is
    /// untouched.
    @objc func copyNodeLinkAction(_ sender: Any?) {
        guard let store, !canvas.isEditing, canvas.selection.count == 1,
            let nodeID = canvas.selection.first
        else { return }
        let link = "x-arbor://open?doc=\(store.model.docID)&node=\(nodeID)"
        clipboard.clearContents()
        clipboard.setString(link, forType: .string)
    }

    // MARK: accessibility (SPEC §11.6, ADR-0007)

    /// The relation value text of a node row: boundary membership and
    /// summary participation.
    func relationValueText(for id: String) -> String? {
        guard let model = store?.model else { return nil }
        var parts: [String] = []
        for boundary in model.boundaries ?? [] where boundary.nodes.contains(id) {
            parts.append(
                boundary.title.map { "in boundary \($0)" } ?? "in boundary")
        }
        for summary in model.summaries ?? [] {
            if summary.node == id {
                parts.append("summary")
            } else if summary.range.contains(id) {
                parts.append("summarized")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The node's connection peers, for the row's "Connected to" jump
    /// actions (F-REL-1's VoiceOver rotor entry).
    func connectionPeers(for id: String) -> [(id: String, title: String)] {
        guard let model = store?.model else { return [] }
        var peers: [(id: String, title: String)] = []
        for connection in model.connections ?? [] {
            let peerID: String?
            if connection.from == id {
                peerID = connection.to
            } else if connection.to == id {
                peerID = connection.from
            } else {
                peerID = nil
            }
            if let peerID, let peer = model.nodes[peerID] {
                let title = peer.title.text
                peers.append((id: peerID, title: title.isEmpty ? "Empty node" : title))
            }
        }
        return peers
    }

    /// The "Connected to" jump (F-REL-1): select and reveal the peer.
    func selectAndReveal(_ nodeID: String) {
        canvas.setConnectionSelection([])
        canvas.setSelection([nodeID])
        canvas.scrollSelectionIntoView()
    }
}

extension DocumentWindowController {
    /// Menu validation for the relation actions (F-REL-1/2/3, F-REL-5),
    /// chained from the one `validateMenuItem`; nil = not a relation item.
    func validateRelationMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(deleteSubtreeAction(_:)):
            // F-REL-1: Delete also works on a selected connection.
            return canvas.isEditing || !canvas.selection.isEmpty
                || !canvas.selectedConnectionIDs.isEmpty
        case #selector(addConnectionAction(_:)):
            // One selection enters ⌘L's connect mode; two connect.
            return canvas.selection.count == 1 || canvas.selection.count == 2
        case #selector(addBoundaryAction(_:)), #selector(addSummaryAction(_:)):
            return !canvas.selection.isEmpty
        case #selector(copyNodeLinkAction(_:)):
            return canvas.selection.count == 1
        default:
            return nil
        }
    }
}
