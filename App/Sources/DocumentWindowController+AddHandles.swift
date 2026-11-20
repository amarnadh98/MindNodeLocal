import AppKit
import CanvasKit
import MapCore

extension DocumentWindowController {
    /// A click on a Node Well "+" (SPEC §6.2): one new child under the
    /// node, selected and open for typing — one undo step, like ⇥. A root
    /// that fans both ways pins the child to the side that was clicked.
    /// A click can arrive with an edit session still open (a menu path
    /// or a commit the click itself will mediate): commit it first — a
    /// half-open session must never silently swallow the add.
    func addChildFromHandle(_ id: String, side: AddHandleSide) {
        guard let store, store.model.nodes[id] != nil else { return }
        if canvas.isEditing {
            canvas.commitEditing()
        }
        canvas.setSelection([id])
        var node = Node(id: UUID().uuidString)
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
