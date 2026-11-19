import AppKit
import Foundation
import PDFKit
import QuickLookUI
import SystemIntegration

/// F-INT-3: the Quick Look preview app extension for `.arbor` packages
/// (view-based `QLPreviewingController`): shows the package's stored
/// `QuickLook/Preview.pdf` when it is fresh, else renders one on the
/// fly through the shared scene exporters, in a `PDFView` scaled to
/// the preview pane.
///
/// `QLPreviewingController` is an unannotated Objective-C protocol the
/// system invokes on the main thread (per its own header docs), so the
/// `@preconcurrency` conformance lets this @MainActor view controller
/// satisfy it with the dynamic MainActor dispatch that call already
/// guarantees.
final class PreviewProvider: NSViewController, @preconcurrency QLPreviewingController {
    override func loadView() {
        // The system sizes the preview pane; the PDF view fills it and
        // resizes with it.
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.backgroundColor = .white
        view = pdfView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        guard let data = ArborPreviewRenderer.previewPDF(at: url) else {
            handler(QuickLookPreviewError.renderFailed)
            return
        }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            handler(QuickLookPreviewError.unreadablePDF)
            return
        }
        (view as? PDFView)?.document = document
        handler(nil)
    }
}

enum QuickLookPreviewError: LocalizedError {
    case renderFailed
    case unreadablePDF

    var errorDescription: String? {
        switch self {
        case .renderFailed: "The map package has no renderable content."
        case .unreadablePDF: "The map's preview could not be read."
        }
    }
}
