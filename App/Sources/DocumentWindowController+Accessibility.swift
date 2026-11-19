import AppKit
import CanvasKit

/// Host wiring for the canvas's accessibility hooks (SPEC §11.6): the
/// container label follows the document's display name, and each of
/// VoiceOver's custom actions routes through the same first-responder
/// actions the keyboard and menus use — one `MapStore` command, one
/// undo step. The view never mutates the model; it only forwards node
/// ids (SPEC §11.3).
///
/// "Add Sibling" creates below, like ⏎ on an editing node; it bypasses
/// ⏎'s enter-edit rule for a selected node (F-EDT-2), since the
/// accessibility action always creates.
@MainActor
extension DocumentWindowController {
    func setupAccessibility() {
        let hooks = canvas.accessibility
        hooks.containerLabel = { [weak self] in
            (self?.document as? NSDocument)?.displayName ?? self?.window?.title ?? "Mind Map"
        }
        hooks.onAddChild = { [weak self] id in
            guard let self else { return }
            self.canvas.setSelection([id])
            self.addChildAction(nil)
        }
        hooks.onAddSibling = { [weak self] id in
            guard let self else { return }
            self.canvas.setSelection([id])
            self.addSiblingBelow(nil)
        }
        hooks.onToggleFold = { [weak self] id in
            guard let self else { return }
            self.canvas.setSelection([id])
            self.toggleFoldAction(nil)
        }
        hooks.onEdit = { [weak self] id in
            guard let self else { return }
            self.canvas.setSelection([id])
            self.editTitleAction(nil)
        }
    }
}
