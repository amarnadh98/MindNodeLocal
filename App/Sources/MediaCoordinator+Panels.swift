import AppKit
import CanvasKit
import MapCore
import MapStudy
@preconcurrency import Quartz
import UniformTypeIdentifiers

/// The MediaCoordinator's user-facing half (F-CNT-7/8, F-TAG-3):
/// attachments and Quick Look, the source anchor's deep link, the
/// filter bar and menu validation — split out to keep each file under
/// the lint budgets.
extension MediaCoordinator {
    // MARK: attachments & sources (F-CNT-7/8)

    /// Finder/file drops: images become node images, everything else
    /// attachments — onto the dropped node, or a fresh root on empty
    /// canvas (SPEC §6.2).
    func dropFiles(_ urls: [URL], onto nodeID: String?) {
        guard let controller else { return }
        let imageTypes: [String] = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"]
        var imageCount = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if imageTypes.contains(ext) {
                insertImage(at: url)
                imageCount += 1
            }
        }
        let others = urls.filter { !imageTypes.contains($0.pathExtension.lowercased()) }
        guard !others.isEmpty else { return }

        let attachments = others.compactMap { url -> Attachment? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let document = controller.document as? MapDocument else { return nil }
            let asset = document.addAsset(data, ext: url.pathExtension.isEmpty ? "bin" : url.pathExtension)
            return asset.isEmpty ? nil : Attachment(asset: asset, name: url.lastPathComponent)
        }
        guard !attachments.isEmpty else { return }

        if let nodeID {
            var existing = controller.contentStore?.model.nodes[nodeID]?.attachments ?? []
            existing.append(contentsOf: attachments)
            controller.perform(.setAttachments(id: nodeID, attachments: existing)) { _ in [nodeID] }
        } else if imageCount == 0 {
            // Empty canvas: a fresh node carrying the attachments (the
            // image path already created its own root above).
            let node = Node(
                id: UUID().uuidString, title: NodeTitle(text: ""), attachments: attachments)
            controller.perform(.addRoot(index: nil, node: node)) { model in
                Set(model.roots.last.map { [$0] } ?? [])
            }
        } else if let lastRoot = controller.contentStore?.model.roots.last {
            // Files + images on empty canvas: the attachments ride on
            // the image node that was just created.
            var existing = controller.contentStore?.model.nodes[lastRoot]?.attachments ?? []
            existing.append(contentsOf: attachments)
            controller.perform(.setAttachments(id: lastRoot, attachments: existing)) { _ in [lastRoot] }
        }
    }

    /// ⌘V with an image on the pasteboard (F-CNT-2): one grouped
    /// `setImage` on the selection. Never hijacks an Arbor node copy —
    /// the internal payload wins when present.
    func pasteImageIfPresent(_ pasteboard: NSPasteboard) -> Bool {
        guard let controller else { return false }
        guard controller.contentStore != nil else { return false }
        guard let item = pasteboard.pasteboardItems?.first else { return false }
        if item.data(forType: DocumentWindowController.payloadType) != nil {
            return false
        }
        let data =
            item.data(forType: .png)
            ?? item.data(forType: .tiff).flatMap(Self.pngFromTIFF)
            ?? item.data(forType: NSPasteboard.PasteboardType("public.heic"))
        guard let data else { return false }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        insertImageData(data, pixels: CGSize(width: image.width, height: image.height))
        return true
    }

    /// TIFF pasteboard data → PNG bytes (the asset store is PNG).
    private static func pngFromTIFF(_ tiff: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Double-click on the attachment badge: Quick Look of the
    /// extracted files.
    func quickLookAttachments(id: String) {
        guard let controller, let document = controller.document as? MapDocument,
            let attachments = controller.contentStore?.model.nodes[id]?.attachments
        else { return }
        let urls = attachments.compactMap { document.extractedAssetURL($0) }
        guard !urls.isEmpty else { return }
        presentQuickLook(urls: urls)
    }

    /// Space on a selected node with an image: Quick Look of it
    /// (F-CNT-2).
    func quickLookNodeImage(id: String) {
        guard let controller, let document = controller.document as? MapDocument,
            let asset = controller.contentStore?.model.nodes[id]?.image?.asset
        else { return }
        guard let data = document.assetData(asset) else { return }
        let ext = (asset as NSString).pathExtension.isEmpty ? "png" : (asset as NSString).pathExtension
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborQuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(asset)
        _ = ext
        try? data.write(to: url, options: .atomic)
        presentQuickLook(urls: [url])
    }

    private func presentQuickLook(urls: [URL]) {
        quickLookURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURLs.count }
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, previewItemAt index: Int
    ) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard index < quickLookURLs.count else { return nil }
            let url = quickLookURLs[index]
            return QuickLookItem(url: url, title: url.lastPathComponent)
        }
    }

    // MARK: sources (F-CNT-8)

    /// Opens the citation chip's URL (a YouTube/Vimeo URL with a
    /// stored time opens at that time — SPEC F-CNT-8).
    func openSource(id: String) {
        guard let controller, let source = controller.contentStore?.model.nodes[id]?.source,
            var url = URL(string: source.url)
        else { return }
        if let time = source.time, let host = url.host?.lowercased(),
            host.contains("youtube.com") || host.contains("vimeo.com")
        {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var query = components?.queryItems ?? []
            query.append(URLQueryItem(name: "t", value: String(Int(time))))
            components?.queryItems = query
            if let withTime = components?.url {
                url = withTime
            }
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: filter bar (F-TAG-3)

    /// ⇧⌥⌘F: toggles the bar; hiding it clears the filter (the scene
    /// rebuilds unpruned).
    func toggleFilterBar() {
        guard let controller else { return }
        if let bar = filterBar {
            bar.removeFromSuperview()
            filterBar = nil
            apply(filter: NodeFilter(), hide: false)
            return
        }
        guard let window = controller.window else { return }
        let bar = FilterBarView(frame: .zero)
        bar.onChange = { [weak self] filter, hide in
            self?.apply(filter: filter, hide: hide)
        }
        bar.onSaveFilter = { [weak self, weak controller] filter in
            guard let self, let controller, let store = controller.contentStore else { return }
            let name =
                (self.promptFilterName() ?? "Filter").trimmingCharacters(in: .whitespaces)
            let saved = SavedFilter(
                id: UUID().uuidString,
                name: name.isEmpty ? "Filter" : name,
                query: filter.query)
            controller.performKeepingSelection(
                .setFilters((store.model.filters ?? []) + [saved]))
            self.refreshFilterBar()
        }
        bar.onApplySaved = { [weak self, weak controller] query in
            guard let self, let controller else { return }
            self.apply(filter: NodeFilter(query: query), hide: self.filterHides)
        }
        window.contentView?.addSubview(bar)
        filterBar = bar
        refreshFilterBar()
        positionFilterBar()
        window.makeFirstResponder(bar)
    }

    /// Rebuilds the bar's document-driven popups after tags/types or
    /// saved filters change.
    func refreshFilterBar() {
        guard let bar = filterBar, let model = controller?.contentStore?.model else { return }
        bar.refresh(model: model)
    }

    private func positionFilterBar() {
        guard let bar = filterBar, let container = bar.superview else { return }
        let height = FilterBarView.barHeight
        bar.frame = NSRect(x: 0, y: container.bounds.height - height, width: container.bounds.width, height: height)
        bar.autoresizingMask = [.width, .minYMargin]
    }

    private func promptFilterName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Filter"
        alert.informativeText = "Name this filter. It is saved in the document (undoable)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        guard let window = controller?.window else { return nil }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: validation (chained into validateMenuItem's default)

    /// Menu validation for the media surface; nil = not mine.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        guard let controller else { return nil }
        switch menuItem.action {
        case #selector(DocumentWindowController.mediaAction(_:)):
            return !controller.canvas.isEditing && !controller.canvas.selection.isEmpty
        case #selector(DocumentWindowController.filterBarAction(_:)):
            menuItem.state = filterBar != nil ? .on : .off
            return true
        case #selector(DocumentWindowController.sourceAction(_:)):
            return !controller.canvas.isEditing && !controller.canvas.selection.isEmpty
        default:
            return nil
        }
    }
}

/// The QLPreviewPanel item wrapper (file URL + display title).
@MainActor
private final class QuickLookItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}
