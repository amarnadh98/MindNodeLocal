import CanvasKit
import CoreGraphics
import Foundation
import MapCore
import MapRender

/// F-CAN-5's floating node, split out of the (lint-budgeted) main
/// controller file: the only creation path that never consults the
/// ADR-0034 shape defaults — a floating root starts at its theme's
/// root style, like any new root.
@MainActor
extension DocumentWindowController {
    /// F-CAN-5: double-click on empty canvas creates a floating root
    /// centered at that point. Roots carry no absolute position, so the
    /// click point is stored as the root's manual `offset` from its auto
    /// slot (SPEC §8.2); `SceneGeometry` applies offsets after auto
    /// layout (also the F-LAY-11 groundwork). One undoable grouped
    /// command, then edit mode.
    func createFloatingNode(at modelPoint: CGPoint) {
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
}
