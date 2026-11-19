import CanvasKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import PDFKit

/// Vector PDF export (SPEC §5.17) through the shared `NodeRenderer` +
/// `BranchPath` drawing: one page sized to the content (scaled down when
/// the map exceeds PDF's 14 400 pt page limit), optionally with a
/// background fill and a document outline (bookmarks) mirroring the
/// tree.
///
/// CGPDFContext cannot author document outlines, so when bookmarks are
/// on, the finished CGPDF bytes are reopened with PDFKit purely to graft
/// the outline tree on (the spec allows "document outline via PDFKit…
/// if CG can't"). One PDFKit quirk drives the shape of that step: an
/// outline set on a document *loaded from bytes* is silently dropped on
/// save, so the pages are first copied into a fresh `PDFDocument`, the
/// outline is grafted on that, and its `dataRepresentation` is written.
public enum PDFExporter {
    /// PDF's own hard page limit (Adobe's 200 × 200 in at 72 pt/in).
    static let maxPDFPageEdge: CGFloat = 14_400

    /// Exports the map as a vector PDF.
    public static func export(
        scene: CanvasScene,
        model: MapModel,
        options: PDFExportOptions,
        measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) throws -> Data {
        switch options.content {
        case .outline:
            return try OutlinePDFExporter.export(
                model: model, title: options.title, includeBookmarks: options.includeBookmarks)
        case .map(let content):
            let export = ExportGeometry.content(
                scene: scene, model: model, content: content, margin: options.margin)
            guard !export.nodes.isEmpty else { throw SceneExportError.emptyScene }
            let data = try renderMap(export, options: options, measurer: measurer)
            guard options.includeBookmarks else { return data }
            return addBookmarks(to: data, model: model, content: content, export: export, title: options.title)
        }
    }

    private static func renderMap(
        _ export: ExportScene, options: PDFExportOptions, measurer: TextMeasurer
    ) throws -> Data {
        let renderScale = min(1, maxPDFPageEdge / max(export.bounds.width, export.bounds.height))
        var mediaBox = CGRect(origin: .zero, size: export.bounds.size)
        mediaBox.size.width = max(1, mediaBox.size.width * renderScale)
        mediaBox.size.height = max(1, mediaBox.size.height * renderScale)

        let output = NSMutableData()
        guard
            let consumer = CGDataConsumer(data: output as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw SceneExportError.pdfContextCreationFailed
        }
        let info: [CFString: Any] = [
            kCGPDFContextTitle: options.title,
            kCGPDFContextCreator: "Arbor",
        ]
        context.beginPDFPage(info as CFDictionary)
        context.translateBy(x: 0, y: mediaBox.height)
        context.scaleBy(x: renderScale, y: renderScale)
        // The canvas's y-down convention, applied after the page-scale
        // clamp so `NodeRenderer` draws upright like it does on screen.
        context.scaleBy(x: 1, y: -1)
        ScenePainter.draw(
            export, measurer: measurer, in: context,
            background: options.includeBackground ? export.canvasColor : nil)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    // MARK: bookmarks (PDFKit)

    /// Reopens the CGPDF bytes in a fresh `PDFDocument` (pages copied —
    /// see the class comment for why) and grafts a document outline
    /// mirroring the exported tree. Each bookmark jumps to its node's
    /// page position.
    private static func addBookmarks(
        to data: Data,
        model: MapModel,
        content: ExportContent,
        export: ExportScene,
        title: String
    ) -> Data {
        guard let source = PDFDocument(data: data), source.pageCount > 0 else {
            return data
        }
        let document = copyIntoFreshDocument(source)
        guard let freshPage = document.page(at: 0) else { return data }

        let root = PDFOutline()
        let nodesByID = Dictionary(uniqueKeysWithValues: export.nodes.map { ($0.id, $0) })
        var subtrees: [String: PDFOutline] = [:]
        let renderScale = min(1, maxPDFPageEdge / max(export.bounds.width, export.bounds.height))

        for id in ExportGeometry.orderedNodeIDs(model: model, content: content) {
            guard let node = model.nodes[id], let sceneNode = nodesByID[id] else { continue }
            let outline = PDFOutline()
            outline.label = node.title.text
            let pageHeight = freshPage.bounds(for: .mediaBox).height
            let point = CGPoint(
                x: (sceneNode.frame.minX - export.bounds.minX) * renderScale,
                y: max(0, pageHeight - (sceneNode.frame.minY - export.bounds.minY) * renderScale))
            outline.destination = PDFDestination(page: freshPage, at: point)
            subtrees[id] = outline
            if let parentID = node.parent, let parentOutline = subtrees[parentID] {
                parentOutline.insertChild(outline, at: parentOutline.numberOfChildren)
            } else {
                root.insertChild(outline, at: root.numberOfChildren)
            }
        }
        guard root.numberOfChildren > 0 else { return data }
        root.label = title
        document.outlineRoot = root
        return document.dataRepresentation() ?? data
    }

    /// PDFKit drops an outline set on a document loaded from bytes, so
    /// the pages move into a new document first.
    static func copyIntoFreshDocument(_ source: PDFDocument) -> PDFDocument {
        let document = PDFDocument()
        for index in 0..<source.pageCount {
            if let page = source.page(at: index) {
                document.insert(page, at: index)
            }
        }
        return document
    }
}

/// Failures raised by the scene exporters.
public enum SceneExportError: Error, Sendable, Hashable {
    /// The CGPDFContext could not be created.
    case pdfContextCreationFailed
    /// The bitmap context could not be created (size or memory).
    case bitmapContextCreationFailed(width: Int, height: Int)
    /// `CGImageDestination` refused the format (encoder missing).
    case imageDestinationFailed(String)
    /// The scene had no renderable content.
    case emptyScene
}
