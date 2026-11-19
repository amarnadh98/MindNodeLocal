import AppKit
import CanvasKit
import Foundation
import MapCore
import MapIO
import MapRender
import SceneExport

/// F-INT-3: every real save (not autosave) regenerates the package's
/// Quick Look previews — `QuickLook/Thumbnail.png` (512 px long edge)
/// and `QuickLook/Preview.pdf` (whole-map vector) — through the SAME
/// scene exporters the File ▸ Export… sheet uses. The QL thumbnail
/// provider/preview extension targets are P1 and deliberately not part
/// of this slice; these files let Finder/Quick Look show the map while
/// they land.
enum DocumentQuickLook {
    static let thumbnailEntryName = "Thumbnail.png"
    static let previewEntryName = "Preview.pdf"
    /// The thumbnail's long edge, per SPEC §5.16 F-INT-3.
    static let thumbnailLongEdgePixels = 512

    /// Renders both preview payloads for `model`.
    static func renderPayloads(
        model: MapModel, variant: ThemeVariant,
        measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) throws -> (thumbnail: Data, preview: Data) {
        let scene = SceneGeometry.build(model: model, variant: variant, measurer: measurer)
        var thumbnailOptions = ImageExportOptions(format: .png, targetLongEdgePixels: thumbnailLongEdgePixels)
        thumbnailOptions.margin = 12
        let thumbnail = try ImageExporter.export(scene: scene, model: model, options: thumbnailOptions)
        let preview = try PDFExporter.export(
            scene: scene,
            model: model,
            options: PDFExportOptions(
                content: .map(.wholeMap), includeBackground: true, includeBookmarks: false,
                title: quickLookTitle(for: model)))
        return (thumbnail.data, preview)
    }

    /// Attaches freshly rendered previews into the package wrapper's
    /// Quick Look directory, replacing yesterday's entries. Failure is
    /// deliberately non-fatal: a save must never fail because a preview
    /// could not be drawn.
    static func attachPreviews(
        to root: FileWrapper, model: MapModel, variant: ThemeVariant,
        measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) {
        guard
            let directory = root.fileWrappers?[ArborPackage.quickLookEntryName]
                ?? root.fileWrappers?[ArborPackage.quickLookEntryName.lowercased()],
            directory.isDirectory
        else { return }
        guard let payloads = try? renderPayloads(model: model, variant: variant, measurer: measurer) else {
            return
        }
        replaceEntry(directory, name: thumbnailEntryName, contents: payloads.thumbnail)
        replaceEntry(directory, name: previewEntryName, contents: payloads.preview)
    }

    private static func replaceEntry(_ directory: FileWrapper, name: String, contents: Data) {
        if let existing = directory.fileWrappers?[name] {
            directory.removeFileWrapper(existing)
        }
        let file = FileWrapper(regularFileWithContents: contents)
        file.preferredFilename = name
        directory.addFileWrapper(file)
    }

    private static func quickLookTitle(for model: MapModel) -> String {
        if let title = model.title, !title.isEmpty { return title }
        guard let rootID = model.roots.first, let root = model.nodes[rootID] else { return "Map" }
        let firstLine = root.title.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "Map" : firstLine
    }
}
