import AppKit
import CanvasKit
import Foundation
import MapCore
import MapRender
import SystemIntegration

/// F-INT-3: every real save (not autosave) regenerates the package's
/// Quick Look previews — `QuickLook/Thumbnail.png` (512 px long edge)
/// and `QuickLook/Preview.pdf` (whole-map vector). The rendering itself
/// lives in `SystemIntegration.ArborPreviewRenderer` (ADR-0014): the
/// SAME one implementation behind the app's save, the Quick Look
/// extension targets' fallback, and the tests.
enum DocumentQuickLook {
    static let thumbnailEntryName = "Thumbnail.png"
    static let previewEntryName = "Preview.pdf"

    /// Attaches freshly rendered previews into the package wrapper's
    /// Quick Look directory, replacing yesterday's entries. Failure is
    /// deliberately non-fatal: a save must never fail because a preview
    /// could not be drawn.
    @MainActor
    static func attachPreviews(
        to root: FileWrapper, model: MapModel, variant: ThemeVariant,
        measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) {
        guard
            let directory = root.fileWrappers?[ArborPackage.quickLookEntryName]
                ?? root.fileWrappers?[ArborPackage.quickLookEntryName.lowercased()],
            directory.isDirectory
        else { return }
        guard
            let payloads = try? ArborPreviewRenderer.renderPayloads(
                model: model, variant: variant, measurer: measurer,
                theme: ThemeCatalog.shared.theme(for: model))
        else {
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
}
