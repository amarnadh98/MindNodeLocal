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
    weak var controller: DocumentWindowController?

    /// The document's decoded image thumbnails (off-main decode).
    private(set) var assetStore = MediaAssetStore()
    /// The ⇧⌘M picker popover.
    private let picker = MediaPickerController()
    /// The F-TAG-3 bar (nil while hidden).
    var filterBar: FilterBarView?
    /// The active filter + mode (view state; hide mode forces full
    /// rebuilds because pruning changes child lists — a documented
    /// contract of `SceneGeometry.prunedIDs`).
    private(set) var filter: NodeFilter?
    private(set) var filterHides = false

    /// What Quick Look currently shows (F-CNT-2/7).
    var quickLookURLs: [URL] = []

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
}
