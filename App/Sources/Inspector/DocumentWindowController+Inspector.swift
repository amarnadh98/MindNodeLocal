import AppKit

/// The inspector's first-responder action (⌥⌘I, View ▸ Inspector): the
/// menu item routes here through the responder chain like every other
/// window action; the pane owns the split item and the persisted
/// visibility (SPEC §4.1, §14.1 "reachable from menus and the
/// keyboard").
@MainActor
extension DocumentWindowController {
    @objc func toggleInspectorAction(_ sender: Any?) {
        inspector.toggleVisibility()
    }
}
