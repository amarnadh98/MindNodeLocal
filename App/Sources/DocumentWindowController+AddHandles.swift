import AppKit
import CanvasKit
import MapCore

extension DocumentWindowController {
    /// A click on a Node Well "+" (SPEC §6.2): one new child under the
    /// node, selected and open for typing — one undo step, like ⇥. A root
    /// that fans both ways pins the child to the side that was clicked.
    func addChildFromHandle(_ id: String, side: AddHandleSide) {
        guard let store, store.model.nodes[id] != nil, !canvas.isEditing else { return }
        canvas.setSelection([id])
        var node = Node(id: UUID().uuidString)
        // ADR-0034: the new child copies the last sibling's explicit
        // shape, so lines stay lines and boxes stay boxes.
        if let shape = childCreationShape(parent: id) {
            node.style = NodeStylePatch(shape: shape)
        }
        if store.model.nodes[id]?.parent == nil {
            switch side {
            case .left: node.side = .left
            case .right: node.side = .right
            case .above, .below: break
            }
        }
        perform(.addChild(parent: id, index: nil, node: node)) { _ in [node.id] }
        canvas.beginEditing(nodeID: node.id)
    }
}
