import AppKit
import CanvasKit
import MapCore
import MapIO

/// The clipboard surface (F-EDT-9), split out of the shared window
/// controller file to keep it under the lint budgets. ⌘C writes ALL
/// flavours — the internal payload (the only lossless one) plus plain
/// text, Markdown and OPML — as one item; while a node is being edited
/// the overlay's text view is first responder and answers copy: itself.
/// Paste lives with the media paste path (`+Media`).
@MainActor
extension DocumentWindowController {
    /// The pasteboard flavours written by copy/cut (F-EDT-9): the
    /// internal lossless payload plus the three interop texts. The
    /// payload type is readable by the M3 media paste path too
    /// (`DocumentWindowController+Media`).
    static let payloadType = NSPasteboard.PasteboardType(PastePayload.uniformTypeIdentifier)
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")
    static let opmlType = NSPasteboard.PasteboardType("org.opml.opml")

    // MARK: clipboard (F-EDT-9)

    /// ⌘C: writes ALL flavours — the internal payload (the only lossless
    /// one) plus plain text, Markdown and OPML — as one item. While a
    /// node is being edited the overlay's text view is first responder
    /// and answers `copy:` itself; these actions only see map-level
    /// presses. (AppKit's `-copy:` & co. aren't exposed to Swift, hence
    /// plain `@objc` declarations rather than overrides.)
    @objc func copy(_ sender: Any?) {
        guard !canvas.isEditing, let store, !canvas.selection.isEmpty else { return }
        let model = store.model
        let ids = canvas.selection.sorted()
        guard let payload = try? PasteboardSerializer.payload(from: model, selection: ids) else {
            return
        }
        let item = NSPasteboardItem()
        item.setData(payload, forType: Self.payloadType)
        item.setString(PasteboardSerializer.plainText(from: model, selection: ids), forType: .string)
        item.setString(PasteboardSerializer.markdown(from: model, selection: ids), forType: Self.markdownType)
        item.setString(PasteboardSerializer.opml(from: model, selection: ids), forType: Self.opmlType)
        clipboard.clearContents()
        clipboard.writeObjects([item])
    }

    /// ⌘X: copy, then ONE `deleteSubtrees` command — a single undo step
    /// restores the whole cut.
    @objc func cut(_ sender: Any?) {
        guard !canvas.isEditing, let store, !canvas.selection.isEmpty else { return }
        copy(sender)
        let ids = topmostSelectedIDs(in: store.model)
        guard !ids.isEmpty else { return }
        let replacement = MapStore.selectionAfterDelete(
            model: store.model, deletedIDs: ids, selection: canvas.selection)
        perform(.deleteSubtrees(ids: ids)) { _ in replacement }
    }
}
