import AppKit
import CoreGraphics
import MapCore

/// The editing-facing surface of the canvas (SPEC §11.4, F-EDT-1/2). The
/// stored `nodeTextEditor` lives on `CanvasView` itself; this extension
/// is the API the host drives: begin/commit, host callbacks and overlay
/// sync.
extension CanvasView {
    /// True while a node's title is being edited inline.
    public var isEditing: Bool { nodeTextEditor.editingNodeID != nil }

    /// The node being edited, if any.
    public var editingNodeID: String? { nodeTextEditor.editingNodeID }

    /// Host hook for every commit: perform the one `editText` command and
    /// the post-commit create (F-EDT-1).
    public var onEditingCommit: ((String, NodeTitle, NodeTextEditor.PostCommitAction) -> Void)? {
        get { nodeTextEditor.onCommit }
        set { nodeTextEditor.onCommit = newValue }
    }

    /// Host hook for the live draft: rebuild the scene with it so the
    /// node grows while typing (F-EDT-8).
    public var onEditingDraftChange: ((String, NodeTitle) -> Void)? {
        get { nodeTextEditor.onDraftChange }
        set { nodeTextEditor.onDraftChange = newValue }
    }

    /// Enter edit mode on a node, all text selected (⏎/⌘⏎/F2/double-click,
    /// F-EDT-2). `placeholder` shows a hint while the text is empty — a
    /// hint, never committed text (F-CAN-3).
    public func beginEditing(nodeID: String, placeholder: String? = nil) {
        nodeTextEditor.beginEditing(nodeID: nodeID, placeholder: placeholder)
    }

    /// Enter edit mode replacing the text with `prefill` — the
    /// spreadsheet-style typing-replaces rule (F-EDT-2).
    public func beginEditing(nodeID: String, prefill: String) {
        nodeTextEditor.beginEditing(nodeID: nodeID, prefill: prefill)
    }

    /// Commits the session (one `editText` command via `onEditingCommit`)
    /// and asks for the post-commit create.
    public func commitEditing(next: NodeTextEditor.PostCommitAction = .none) {
        nodeTextEditor.commit(next: next)
    }

    /// Re-positions the overlay at the editing node's current screen rect
    /// (camera or scene changed under it).
    public func syncEditingOverlay() {
        nodeTextEditor.syncPosition()
    }

    /// The editing session's live draft title, if any.
    public var editingDraftTitle: NodeTitle? {
        nodeTextEditor.currentTitle()
    }

    // MARK: keyboard entry points (reached when the canvas itself is
    // first responder and no menu key equivalent claimed the event)

    /// ⏎/⌘⏎/F2 on a single selected node: edit it (F-EDT-2).
    func beginEditingSelection() {
        guard selection.count == 1, let id = selection.first else { return }
        beginEditing(nodeID: id)
    }

    /// Typing a printable character on a single selected node replaces its
    /// text (F-EDT-2).
    func beginEditingSelection(prefill: String) {
        guard selection.count == 1, let id = selection.first else { return }
        beginEditing(nodeID: id, prefill: prefill)
    }

    /// F-EDT-2: a key event that should begin a replace-edit — a single
    /// printable character with no ⌘/⌃ modifier. Plain PUA-range scalars
    /// (⏎/⇥/⎋/⌫ and the function keys) don't qualify.
    func replaceEditText(for event: NSEvent) -> String? {
        guard !isEditing, selection.count == 1 else { return nil }
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return nil }
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        for scalar in characters.unicodeScalars {
            guard scalar.value >= 32, !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        }
        return characters
    }
}
