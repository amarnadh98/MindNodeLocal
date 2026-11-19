import AppKit
import CanvasKit
import MapCore

/// F-STD-5's window hooks: the ⌥⌘R *Recall* menu action and its
/// validation. The mode itself (shield, HUD, overlay, grading) lives
/// in App/Sources/Study/RecallSession.swift; the branch selection and
/// model-change lifecycle stay here with the other document actions.
@MainActor
extension DocumentWindowController {
    /// Study ▸ Recall (⌥⌘R, F-STD-5): the selected branch's
    /// descendants hide behind blurred placeholders on the canvas.
    /// A live run exits instead (one key, both directions — the same
    /// trick ⌥⌘⏎ plays with presenting).
    ///
    /// Pure view state: no `MapCommand` ever runs to enter or exit
    /// (grading inside the mode goes through the document's own
    /// non-undoable path), so recall never dirties the document and
    /// never appears on the undo stack.
    @objc func recallAction(_ sender: Any?) {
        if let session = recallSessionBox {
            session.stop()
            return
        }
        guard let mapDocument = document as? MapDocument,
            !canvas.isEditing,
            !canvas.selection.isEmpty,
            let branchID = canvas.selection.sorted().first,
            let session = RecallSession(controller: self, branchID: branchID)
        else { return }
        recallSessionBox = session
        session.start()
    }

    /// Menu validation (reached from the ONE `validateMenuItem` in
    /// DocumentWindowController+Toolbar.swift): checkmarked and live
    /// while a run is active; otherwise the selection needs a branch
    /// with descendants worth hiding.
    func validateRecallMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard document is MapDocument else { return false }
        if recallSessionBox != nil {
            menuItem.state = .on
            return true
        }
        menuItem.state = .off
        guard !canvas.isEditing, !canvas.selection.isEmpty else { return false }
        guard let mapDocument = document as? MapDocument,
            let branchID = canvas.selection.sorted().first,
            let node = mapDocument.model.nodes[branchID]
        else { return false }
        return !node.children.isEmpty
    }
}
