import AppKit
import CanvasKit
import MapCore
import MapIO

/// The M3 media actions (F-CNT-2/3/7/8, F-TAG-3): the menu/keyboard
/// surface behind the MediaCoordinator. Every mutation is ONE
/// `MapCommand` through the document's `MapStore`; the heavy work
/// (decodes, math typesetting) lives behind the coordinator's caches,
/// never on the keystroke path.
@MainActor
extension DocumentWindowController {
    /// ⇧⌘M (Media): the picker popover — Image, SF Symbols, Emoji,
    /// Stickers (F-CNT-2/3).
    @objc func mediaAction(_ sender: Any?) {
        mediaCoordinator.presentMediaPicker()
    }

    /// Format ▸ Image…: pick an image file directly (SPEC's "Media ▸
    /// Image" entry path, alongside drag/drop and paste).
    @objc func imageAction(_ sender: Any?) {
        guard !canvas.isEditing, !canvas.selection.isEmpty else { return }
        mediaCoordinator.pickImageFile()
    }

    /// Format ▸ Source… (F-CNT-8): the source sheet over the
    /// selection — one grouped `setSource`, nil clears it.
    @objc func sourceAction(_ sender: Any?) {
        guard let store = contentStore, let window,
            let id = canvas.selection.sorted().first
        else { return }
        let current = store.model.nodes[id]?.source
        SourceSheet.present(over: window, current: current) { [weak self] source in
            guard let self, let store = self.contentStore else { return }
            let ids = self.canvas.selection.sorted()
            var commands = ids.map { MapCommand.setSource(id: $0, source: source) }
            // A group stays one undo step; every node that did not
            // carry the value still gets it (the selection reads as
            // one intent).
            commands.removeAll { command in
                guard case .setSource(let target, let value) = command else { return false }
                return source == nil && store.model.nodes[target]?.source == nil
            }
            if let command = self.groupedCommands("Set Source", commands) {
                self.performKeepingSelection(command)
            }
        }
    }

    /// ⇧⌥⌘F (F-TAG-3): the filter bar. Dim mode is view state; hide
    /// mode prunes the scene (a full rebuild per change, documented
    /// in MediaCoordinator); saved filters are the one undoable
    /// `setFilters`.
    @objc func filterBarAction(_ sender: Any?) {
        mediaCoordinator.toggleFilterBar()
    }

    /// An async image decode landed: bump the scene media revision so
    /// exactly the image-carrying nodes re-raster (the placeholder
    /// swaps for the real thumbnail).
    func refreshMediaRevision() {
        sceneCache?.media?.revision = mediaCoordinator.assetStore.revision
        updateScene(preserveCamera: true)
    }

    /// Menu validation for the media actions; chained into
    /// `validateMenuItem`'s default arm.
    func validateMediaMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        mediaCoordinator.validateMenuItem(menuItem)
    }

    // MARK: clipboard (F-EDT-9; moved to keep DocumentWindowController.swift under the lint file budget)

    /// ⌘V / ⇧⌥⌘V: reads the richest available flavour (internal payload
    /// first, then OPML, Markdown, plain text) and performs ONE
    /// `insertSubtrees` command — fresh ids and timestamps, one undo
    /// step — landing under the first selected node as its last children,
    /// or as new roots when nothing is selected. The pasted top-level
    /// nodes become the selection. ⇧⌥⌘V keeps per-node style overrides;
    /// the plain paste adopts the target's theme (F-EDT-9).
    @objc func paste(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        // F-CNT-2: an image on the pasteboard becomes the selection's
        // node image (one grouped `setImage`) before the text flavors.
        if mediaCoordinator.pasteImageIfPresent(clipboard) {
            return
        }
        let keepStyle =
            (sender as? NSMenuItem)?.keyEquivalentModifierMask.contains(.option) == true
        let anchor = PasteboardParser.pasteAnchor(selection: canvas.selection.sorted(), in: store.model)
        guard
            let command = try? pasteCommand(
                from: clipboard, parent: anchor.parent, index: anchor.index, keepStyle: keepStyle)
        else { return }
        let pasted: Set<String>
        if case .insertSubtrees(_, let anchors) = command {
            pasted = Set(anchors.map(\.id))
        } else {
            pasted = []
        }
        perform(command) { _ in pasted }
        canvas.scrollSelectionIntoView()
    }

    /// Builds the paste command from the richest flavour on `pasteboard`
    /// — the internal payload when present, else the first surviving text
    /// flavour. Only the first pasteboard item is considered; foreign
    /// multi-item copies paste their first snippet.
    func pasteCommand(
        from pasteboard: NSPasteboard,
        parent: String?,
        index: Int,
        keepStyle: Bool
    ) throws -> MapCommand? {
        guard let store, let item = pasteboard.pasteboardItems?.first else { return nil }
        if let data = item.data(forType: Self.payloadType) {
            return try PasteboardParser.pasteCommand(
                fromPayload: data, parent: parent, index: index, keepStyle: keepStyle, in: store.model)
        }
        let textFlavours: [NSPasteboard.PasteboardType] = [Self.opmlType, Self.markdownType, .string]
        for type in textFlavours {
            guard let text = item.string(forType: type), !text.isEmpty else { continue }
            return try PasteboardParser.pasteCommand(
                fromText: text, parent: parent, index: index, keepStyle: keepStyle, in: store.model)
        }
        return nil
    }
}
