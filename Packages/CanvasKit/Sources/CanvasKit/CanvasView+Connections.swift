import AppKit
import CoreGraphics
import MapCore
import MapRender

/// One live midpoint-handle drag (F-REL-1): the connection being bent
/// and the handle's current model-space point.
struct RelationHandleDrag {
    let connectionID: String
    var handleModel: CGPoint
}

/// Connection interactions on the canvas (F-REL-1): selection and
/// hit-testing on the sampled curves, the ⌘L connection mode, the
/// draggable midpoint handle (double-click resets), inline label
/// editing, and the ⌃⌘L / ⇧⌘L jumps to the endpoint nodes. The view
/// never mutates the model (SPEC §11.3) — every finished interaction
/// hands the host one command.
///
/// Boundaries and summaries (F-REL-2/3) have no canvas interaction of
/// their own: they are created from the node selection through the
/// Insert menu and follow the layout as pure scene geometry.
extension CanvasView {
    // MARK: ⌘L connection mode

    /// F-REL-1's ⌘L: the single selected node becomes the connection
    /// source; the next node click creates the connection. Returns
    /// false (no mode) without exactly one selected node.
    @discardableResult
    public func beginConnectionMode() -> Bool {
        guard selection.count == 1, let source = selection.first,
            scene?.nodes[source] != nil
        else { return false }
        pendingConnectionSource = source
        return true
    }

    /// Cancels a pending ⌘L mode (the host's ⎋ path can call it when
    /// the menu equivalent swallowed the key).
    public func cancelConnectionMode() {
        pendingConnectionSource = nil
    }

    /// The pending mode's next click, resolved at a view point: a click
    /// on another node creates the connection; anything else cancels
    /// the mode without performing anything.
    public func completeConnectionMode(at point: CGPoint) {
        guard let source = pendingConnectionSource else { return }
        pendingConnectionSource = nil
        if let target = nodeID(at: point), target != source {
            onCreateConnection?(source, target)
        }
    }

    // MARK: selection

    /// The connection under a view point, with the stroke hit tolerance
    /// (§6.2-scale aware) — pure geometry through `RelationGeometry`.
    public func connectionID(at viewPoint: CGPoint) -> String? {
        guard let scene else { return nil }
        return RelationGeometry.connectionID(
            at: camera.modelPoint(for: viewPoint),
            tolerance: RelationGeometry.hitTolerance / camera.scale,
            in: scene.connections)
    }

    /// The connection whose midpoint handle sits under a view point
    /// (only a *selected* connection offers its handle — the selection
    /// is what makes the handle visible/interactive, F-REL-1).
    public func connectionWithHandle(at viewPoint: CGPoint) -> String? {
        guard let scene else { return nil }
        return RelationGeometry.connectionWithHandle(
            at: camera.modelPoint(for: viewPoint),
            radius: RelationGeometry.handleRadius / camera.scale,
            in: scene.connections.filter { selectedConnectionIDs.contains($0.id) })
    }

    /// Sets the connection selection (⌘-click toggles), refreshing the
    /// affected rasters' halos.
    public func setConnectionSelection(_ ids: Set<String>) {
        selectedConnectionIDs = ids.filter { id in
            scene?.connections.contains { $0.id == id } ?? false
        }
        syncRelationRasters()
    }

    /// Drops connection ids whose endpoints left the scene.
    func pruneConnectionSelection() {
        let valid = selectedConnectionIDs.filter { id in
            scene?.connections.contains { $0.id == id } ?? false
        }
        guard valid != selectedConnectionIDs else { return }
        selectedConnectionIDs = valid
        syncRelationRasters()
    }

    /// Re-applies the current scene with the new connection selection —
    /// a selection change is a raster change for the affected overlays
    /// only (the halo), never a rebuild.
    func syncRelationRasters() {
        layerTree.selectedConnections = selectedConnectionIDs
        layerTree.realizeRelations(
            camera: camera, viewport: bounds.size, backingScale: backingScale)
    }

    // MARK: mouse interactions

    /// Connection-side mouse-down handling (F-REL-1). Returns true when
    /// consumed. Order: a double-click resets the handle (or edits the
    /// label when it lands on the label); a grab of a selected
    /// connection's handle starts the handle drag; a stroke hit
    /// selects the connection.
    func handleRelationMouseDown(_ point: CGPoint, clickCount: Int) -> Bool {
        guard let scene else { return false }
        guard connectionID(at: point) != nil || connectionWithHandle(at: point) != nil else {
            return false
        }
        if clickCount == 2 {
            if let connection = connectionUnder(point) {
                if labelFrame(of: connection).contains(point) {
                    beginLabelEditing(connection)
                    return true
                }
                // F-REL-1: double-click resets the dragged handle.
                if let stored = storedConnection(connection.id) {
                    onMutateConnection?(RelationCommands.resetHandle(connection: stored))
                }
            }
            return true
        }
        if let handleOwner = connectionWithHandle(at: point),
            let connection = scene.connections.first(where: { $0.id == handleOwner })
        {
            relationDrag = RelationHandleDrag(
                connectionID: connection.id,
                handleModel: connection.handlePosition)
            updateRelationPreview(connection, handle: connection.handlePosition)
            return true
        }
        if let hit = connectionID(at: point) {
            if commandKeyDown {
                if selectedConnectionIDs.contains(hit) {
                    selectedConnectionIDs.remove(hit)
                } else {
                    selectedConnectionIDs.insert(hit)
                }
            } else {
                selectedConnectionIDs = [hit]
                setSelection([])
            }
            syncRelationRasters()
            return true
        }
        return false
    }

    /// A defensive seam: the ⌘-flag of the mouse-down event is not
    /// carried into `handleRelationMouseDown`, so the modifier state is
    /// read from the current event when one is being processed
    /// (headless tests pass `false` — selection toggling is covered by
    /// `setConnectionSelection`).
    private var commandKeyDown: Bool {
        NSEvent.modifierFlags.contains(.command)
    }

    /// The connection (scene value) under a view point.
    func connectionUnder(_ point: CGPoint) -> SceneConnection? {
        guard let hit = connectionID(at: point) else { return nil }
        return scene?.connections.first { $0.id == hit }
    }

    /// The model connection record with `id` (the scene value carries
    /// resolved geometry; the record is what a mutation command edits).
    func storedConnection(_ id: String) -> Connection? {
        dragModel?.connections?.first { $0.id == id }
    }

    /// The label's screen-space frame (the inline editor's target).
    func labelFrame(of connection: SceneConnection) -> CGRect {
        let measurer = SceneRenderer.sharedMeasurer
        let size = measurer.nodeTitleSize(
            NodeTitle(text: connection.label ?? ""),
            font: RelationRenderer.connectionLabelFont, maxWidth: 400)
        let center = camera.screenPoint(for: connection.labelPosition)
        return CGRect(
            x: center.x - size.width / 2 - 4, y: center.y - size.height / 2 - 4,
            width: size.width + 8, height: size.height + 8)
    }

    /// A handle-drag move (F-REL-1): the handle follows the cursor and
    /// the preview curve re-strokes. Returns true while a handle drag
    /// is live.
    func updateRelationDrag(at point: CGPoint) -> Bool {
        guard var handleDrag = relationDrag else { return false }
        guard let connection = scene?.connections.first(where: { $0.id == handleDrag.connectionID })
        else {
            relationDrag = nil
            return false
        }
        handleDrag.handleModel = camera.modelPoint(for: point)
        relationDrag = handleDrag
        updateRelationPreview(connection, handle: handleDrag.handleModel)
        return true
    }

    /// A handle-drag drop (F-REL-1): ONE `editConnection` with the new
    /// stored offset — the host performs it and the rebuilt scene
    /// replaces the preview. Returns true while a handle drag is live.
    func finishRelationDrag(at point: CGPoint) -> Bool {
        guard let handleDrag = relationDrag else { return false }
        relationDrag = nil
        clearRelationPreview()
        guard let connection = scene?.connections.first(where: { $0.id == handleDrag.connectionID }),
            let stored = storedConnection(handleDrag.connectionID)
        else { return true }
        let target = camera.modelPoint(for: point)
        onMutateConnection?(
            RelationCommands.moveHandle(
                connection: stored, handlePoint: target,
                anchors: (from: connection.from, to: connection.to)))
        return true
    }

    /// The preview layer's initial setup (called from both `init`s).
    func configureRelationPreviewLayer() {
        relationPreviewLayer.fillColor = nil
        relationPreviewLayer.strokeColor = NSColor.controlAccentColor.cgColor
        relationPreviewLayer.lineWidth = 1.5
        relationPreviewLayer.zPosition = 3
        relationPreviewLayer.isHidden = true
    }

    /// Re-strokes the live curve preview for a handle at `handle`.
    private func updateRelationPreview(_ connection: SceneConnection, handle: CGPoint) {
        let control = RelationPath.controlForHandle(handle, from: connection.from, to: connection.to)
        relationPreviewLayer.path = RelationPath.connectionPath(
            from: connection.from, to: connection.to, control: control,
            straight: connection.straight)
        relationPreviewLayer.transform = CanvasLayerTree.modelSpaceTransform(for: camera)
        relationPreviewLayer.lineWidth = max(connection.style.width, 1) / camera.scale
        relationPreviewLayer.isHidden = false
    }

    private func clearRelationPreview() {
        relationPreviewLayer.isHidden = true
        relationPreviewLayer.path = nil
    }

    // MARK: label editing (F-REL-1)

    /// ⏎ or a double-click on the label: opens the inline editor at the
    /// label's screen rect (the same overlay approach the node editor
    /// uses, ADR-0006 — a real `NSTextView`, camera-scaled).
    func beginConnectionLabelEditing() {
        guard selectedConnectionIDs.count == 1, let id = selectedConnectionIDs.first,
            let connection = scene?.connections.first(where: { $0.id == id })
        else { return }
        beginLabelEditing(connection)
    }

    private func beginLabelEditing(_ connection: SceneConnection) {
        connectionLabelEditor.begin(
            connectionID: connection.id,
            text: connection.label ?? "",
            in: labelFrame(of: connection),
            onCommit: { [weak self] connectionID, text in
                self?.commitLabel(connectionID, text)
            })
    }

    /// One label commit: ONE `editConnection` command through the host
    /// (F-REL-1). A no-op label (unchanged text) registers nothing.
    func commitLabel(_ connectionID: String, _ text: String) {
        guard let stored = storedConnection(connectionID) else { return }
        if let command = RelationCommands.setLabel(connection: stored, label: text) {
            onMutateConnection?(command)
        }
    }

    // MARK: jump actions (F-REL-1: ⌃⌘L / ⇧⌘L)

    /// ⌃⌘L: selects and centers the selected connection's start node.
    @objc public func jumpToConnectionStartAction(_ sender: Any?) {
        jumpToConnectionEndpoint(first: true)
    }

    /// ⇧⌘L: selects and centers the selected connection's end node.
    @objc public func jumpToConnectionEndAction(_ sender: Any?) {
        jumpToConnectionEndpoint(first: false)
    }

    private func jumpToConnectionEndpoint(first: Bool) {
        guard !isEditing, selectedConnectionIDs.count == 1, let scene else { return }
        guard let id = selectedConnectionIDs.first,
            let connection = scene.connections.first(where: { $0.id == id })
        else { return }
        let target = first ? connection.fromID : connection.toID
        // The connection stays selected, so ⌃⌘L and ⇧⌘L alternate
        // between its two endpoints (F-REL-1).
        setSelection([target])
        scrollSelectionIntoView()
    }
}
