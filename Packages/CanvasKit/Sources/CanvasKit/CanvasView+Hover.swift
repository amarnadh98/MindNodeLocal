import AppKit
import CoreGraphics
import MapCore
import MapLayout

/// The hover half of the Node Well (SPEC §6.2): the node under the
/// pointer shows its "+" buttons without a click, so a child can be
/// added from *any* node — the previous box, not just the selected
/// one. A grace band around the node's frame keeps its buttons alive
/// while the pointer travels from the node out to its "+" (the button
/// sits a fixed screen distance outside the edge, so the band is
/// measured in screen points, not model points).
///
/// Nothing here runs on the keystroke path: the buttons re-resolve on
/// selection, scene and hover changes — `mouseMoved` never fires while
/// typing — and one resolve is a couple of pure resolver calls over
/// already-realized layers.
extension CanvasView {
    /// The Node Well buttons for the single selected node plus the
    /// hovered one (SPEC §6.2), resolved against the scene and the
    /// model's declared root structure, then handed to the layer tree.
    /// Idempotent: an unchanged handle set only repositions layers, and
    /// a gated-out call (editing, dragging — e.g. every live-typing
    /// scene apply) is one boolean check, never a resolve.
    func updateAddHandles() {
        guard addHandlesAllowed, let scene else {
            if !layerTree.addHandles.isEmpty {
                layerTree.setAddHandles([], camera: camera, color: selectionColor)
            }
            return
        }
        var ids: [String] = []
        if selection.count == 1, let selected = selection.first {
            ids.append(selected)
        }
        if let hovered = hoverNodeID, hovered != ids.first {
            ids.append(hovered)
        }
        var wanted: [AddHandle] = []
        for id in ids where layerTree.nodeLayers[id] != nil {
            wanted += AddHandleResolver.handles(
                for: id, in: scene, rootStructure: declaredStructure(of: id))
        }
        layerTree.setAddHandles(wanted, camera: camera, color: selectionColor)
    }

    /// `id`'s declared structure when it is a root (nil for non-roots
    /// and unset roots — the resolver treats both as balanced).
    private func declaredStructure(of id: String) -> LayoutStructure? {
        guard let node = dragModel?.nodes[id], node.parent == nil else { return nil }
        return LayoutStructure(rawValue: node.structure ?? "")
    }

    /// One pointer move (mouseMoved/mouseExited, CanvasView+Decorations):
    /// the node under the point claims the hover; the previous node
    /// keeps it inside its grace band, so the pointer can travel from
    /// the node to its "+" without the button vanishing first. Only a
    /// real change re-resolves the buttons.
    func hoverMoved(to point: CGPoint) {
        if let id = nodeID(at: point) {
            if hoverNodeID != id {
                hoverNodeID = id
                updateAddHandles()
            }
            return
        }
        if let id = hoverNodeID, let frame = scene?.nodes[id]?.frame,
            Self.hoverGraceRect(around: frame, camera: camera).contains(point)
        {
            return
        }
        if hoverNodeID != nil {
            hoverNodeID = nil
            updateAddHandles()
        }
    }

    /// The node's frame in view space, grown to cover its "+" buttons:
    /// they sit `AddHandle.offset` from the edge with `radius` of their
    /// own, at any zoom, plus a few points of slack.
    static func hoverGraceRect(around frame: CGRect, camera: Camera) -> CGRect {
        let viewRect = CGRect(
            origin: camera.screenPoint(for: frame.origin),
            size: CGSize(width: frame.width * camera.scale, height: frame.height * camera.scale))
        let margin = AddHandle.offset + AddHandle.radius + 6
        return viewRect.insetBy(dx: -margin, dy: -margin)
    }
}
