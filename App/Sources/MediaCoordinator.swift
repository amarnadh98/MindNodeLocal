import AppKit
import CanvasKit
import MapCore
import MapRender
import MapStudy
@preconcurrency import Quartz
import UniformTypeIdentifiers

/// The M3 media surface (F-CNT-2/3/7/8, F-TAG-3): one coordinator per
/// document window owning the asset thumbnail store, the media picker,
/// the source sheet, the filter bar and Quick Look. Every mutation is
/// ONE `MapCommand` through the document's store; view state (the
/// filter, the picker) never touches the model (SPEC §11.3).
@MainActor
final class MediaCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private weak var controller: DocumentWindowController?

    /// The document's decoded image thumbnails (off-main decode).
    private(set) var assetStore = MediaAssetStore()
    /// The ⇧⌘M picker popover.
    private let picker = MediaPickerController()
    /// The F-TAG-3 bar (nil while hidden).
    private(set) var filterBar: FilterBarView?
    /// The active filter + mode (view state; hide mode forces full
    /// rebuilds because pruning changes child lists — a documented
    /// contract of `SceneGeometry.prunedIDs`).
    private(set) var filter: NodeFilter?
    private(set) var filterHides = false

    /// What Quick Look currently shows (F-CNT-2/7).
    private var quickLookURLs: [URL] = []

    func attach(_ controller: DocumentWindowController) {
        self.controller = controller
        assetStore.onDecoded = { [weak controller] in
            // The decode landed: bump the media revision and re-raster
            // exactly the image nodes (a cheap full scene rebuild).
            controller?.refreshMediaRevision()
        }
        let canvas = controller.canvas
        canvas.registerFileDrop()
        canvas.onCycleMarker = { [weak self] id in
            self?.cycleMarker(id: id)
        }
        canvas.onOpenSource = { [weak self] id in
            self?.openSource(id: id)
        }
        canvas.onQuickLookAttachments = { [weak self] id in
            self?.quickLookAttachments(id: id)
        }
        canvas.onQuickLookImage = { [weak self] id in
            self?.quickLookNodeImage(id: id)
        }
        canvas.onResizeImage = { [weak self] id, size in
            self?.resizeImage(id: id, to: size)
        }
        canvas.onDropFiles = { [weak self] urls, nodeID in
            self?.dropFiles(urls, onto: nodeID)
        }
    }

    // MARK: scene media (the provider behind SceneBuildCache.media)

    /// Configures the per-document scene cache's media lookup. Called
    /// whenever the cache is (re)created — the closures capture the
    /// store, never the cache, so a variant flip re-wires cleanly.
    func configureSceneMedia(_ cache: SceneBuildCache) {
        guard let controller, let document = controller.document as? MapDocument else { return }
        let store = assetStore
        cache.media = SceneMediaProvider(
            image: { asset in
                store.thumbnail(named: asset) { document.assetData(asset) }
            },
            marker: { token, tint in
                SFSymbolGlyphCache.image(token: token, tint: tint)
            },
            math: { latex, font, tint in
                MathImageCache.glyph(latex: latex, font: font, tint: tint)
            },
            revision: store.revision)
    }

    /// The ids hide mode prunes from the scene, nil when the filter is
    /// off or in dim mode.
    func prunedIDs(model: MapModel) -> Set<String>? {
        guard filterHides, let filter, !filter.isEmpty else { return nil }
        return FilterEngine.hiddenIDs(
            model: model, filter: filter, mastery: controller?.canvas.filterMastery,
            now: controller?.canvas.filterNow ?? Date())
    }

    /// A filter change: dim mode is pure overlay state, hide mode
    /// needs the pruned rebuild (the caller performs it).
    func apply(filter: NodeFilter, hide: Bool) {
        self.filter = filter.isEmpty ? nil : filter
        filterHides = hide && self.filter != nil
        if let controller, let document = controller.document as? MapDocument {
            // Dim mode reads the highlight channel (matching ids stay
            // lit); hide mode prunes the build.
            controller.canvas.filterMastery = MapStudy.MasteryReport.compute(
                map: document.model, now: Date())
            controller.canvas.filterNow = Date()
            controller.canvas.highlight =
                (self.filter != nil && !filterHides) ? .filter(self.filter!) : nil
            controller.updateScene(preserveCamera: true)
        }
    }

    // MARK: ⇧⌘M media picker (F-CNT-2/3)

    func presentMediaPicker() {
        guard let controller, !controller.canvas.selection.isEmpty,
            let id = controller.canvas.selection.sorted().first
        else { return }
        picker.present(
            anchor: controller.canvas.viewRect(of: id) ?? controller.canvas.bounds,
            of: controller.canvas,
            tags: controller.contentStore?.model.tags ?? [],
            onPickImage: { [weak self] in
                self?.pickImageFile()
            },
            onToggleMarker: { [weak self] token in
                self?.toggleMarker(token)
            },
            onClearMarkers: { [weak self] in
                self?.clearMarkers()
            })
    }

    // MARK: images (F-CNT-2)

    /// The image-open panel: Insert ▸ Image's file path (drag, drop
    /// and paste are the other three).
    func pickImageFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertImage(at: url)
    }

    /// Inserts the image file into every selected node (or a fresh
    /// root when nothing is selected): import-downscale → package
    /// asset → display size capped to the node's max width → ONE
    /// grouped `setImage`.
    func insertImage(at url: URL) {
        guard let controller else { return }
        guard let raw = try? Data(contentsOf: url),
            let data = MediaAssetStore.downscaledImagePNG(raw),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            NSSound.beep()
            return
        }
        insertImageData(data, pixels: CGSize(width: image.width, height: image.height))
    }

    /// The shared insert path: store the bytes, compute the display
    /// size (long edge capped at 320 pt — a node image, not a wall),
    /// apply to the selection as one grouped command.
    func insertImageData(_ data: Data, pixels: CGSize) {
        guard let controller, let document = controller.document as? MapDocument else { return }
        let ext = "png"
        let asset = document.addAsset(data, ext: ext)
        guard !asset.isEmpty else { return }

        let longEdge = max(pixels.width, pixels.height)
        let displayLong: CGFloat = 320
        let scale = longEdge > 0 ? min(1, displayLong / longEdge) : 1
        let size = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let nodeImage = NodeImage(
            asset: asset, size: [Double(size.width), Double(size.height)], placement: .above)

        let ids = controller.canvas.selection.sorted()
        if !ids.isEmpty {
            let commands = ids.map { MapCommand.setImage(id: $0, image: nodeImage) }
            if let command = controller.groupedCommands("Set Image", commands) {
                controller.performKeepingSelection(command)
            }
            return
        }
        // Nothing selected: a fresh image root.
        let node = Node(
            id: UUID().uuidString, title: NodeTitle(text: ""), image: nodeImage)
        controller.perform(.addRoot(index: nil, node: node)) { model in
            Set(model.roots.last.map { [$0] } ?? [])
        }
    }

    /// The resize handle's commit (aspect already resolved by the
    /// drag): one `setImage` with the new display size.
    func resizeImage(id: String, to size: CGSize) {
        guard let controller, var image = controller.contentStore?.model.nodes[id]?.image,
            image.size.count >= 2
        else { return }
        image.size = [Double(size.width), Double(size.height)]
        controller.perform(.setImage(id: id, image: image)) { _ in [id] }
    }

    // MARK: markers (F-CNT-3)

    /// A picker pick: toggle the token on the selection — a priority
    /// or progress family member replaces its sibling first (one
    /// marker of a family at a time).
    func toggleMarker(_ token: String) {
        guard let controller, let store = controller.contentStore else { return }
        let ids = controller.canvas.selection.sorted()
        guard !ids.isEmpty else { return }
        var commands: [MapCommand] = []
        for id in ids {
            guard let node = store.model.nodes[id] else { continue }
            let family = MarkerCycler.family(of: token) ?? []
            var markers = (node.markers ?? []).filter { !family.contains($0) }
            if markers.contains(token) {
                markers.removeAll { $0 == token }
            } else {
                markers.append(token)
            }
            commands.append(.setMarkers(id: id, markers: markers.isEmpty ? nil : markers))
        }
        if let command = controller.groupedCommands("Set Marker", commands) {
            controller.performKeepingSelection(command)
        }
    }

    /// The picker's clear action.
    func clearMarkers() {
        guard let controller else { return }
        let ids = controller.canvas.selection.sorted()
        let commands = ids.compactMap { id -> MapCommand? in
            guard controller.contentStore?.model.nodes[id]?.markers != nil else { return nil }
            return .setMarkers(id: id, markers: nil)
        }
        if let command = controller.groupedCommands("Set Marker", commands) {
            controller.performKeepingSelection(command)
        }
    }

    /// A canvas click on a priority/progress marker: one cycling
    /// `setMarkers` (the last click clears the family — stored as
    /// cleared, `nil`, not an empty list).
    func cycleMarker(id: String) {
        guard let controller, let node = controller.contentStore?.model.nodes[id],
            let markers = node.markers,
            let family = markers.compactMap({ MarkerCycler.family(of: $0) }).first
        else { return }
        let cycled = MarkerCycler.cycled(markers, in: family) ?? []
        let value = cycled.isEmpty ? nil : cycled
        controller.perform(.setMarkers(id: id, markers: value)) { _ in [id] }
    }

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
