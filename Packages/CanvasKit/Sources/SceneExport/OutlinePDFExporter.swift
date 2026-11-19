import CanvasKit
import CoreGraphics
import CoreText
import Foundation
import MapCore
import MapRender
import PDFKit

/// The outline PDF export (SPEC §5.17): a paginated text document —
/// one indented line block per node, roots bold — instead of the map
/// drawing. Bookmarks mirror the tree exactly like the map PDF's.
public enum OutlinePDFExporter {
    static let pageSize = CGSize(width: 595.2, height: 841.9)
    static let pageMargin: CGFloat = 48
    static let indentStep: CGFloat = 18
    static let lineGap: CGFloat = 3

    /// Exports the whole model as an outline text document.
    public static func export(model: MapModel, title: String, includeBookmarks: Bool) throws -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard
            let consumer = CGDataConsumer(data: output as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw SceneExportError.pdfContextCreationFailed
        }

        let measurer = SceneRenderer.sharedMeasurer
        var layout = OutlineLayout()
        for rootID in model.roots {
            layout = layOutNode(rootID, depth: 0, in: model, context: context, layout: layout, measurer: measurer)
        }
        if layout.hasOpenPage {
            context.endPDFPage()
        }
        context.closePDF()
        let data = output as Data

        guard includeBookmarks, !layout.anchors.isEmpty else { return data }
        return addBookmarks(to: data, model: model, layout: layout, title: title)
    }

    // MARK: page layout

    /// Records where each node's line landed so bookmarks can point at
    /// it. `cursorY` is the next free y (PDF space, y-up) on the open
    /// page; `hasOpenPage` tracks whether a CGPDF page is currently open.
    private struct OutlineLayout {
        var pageIndex = 0
        var cursorY: CGFloat?
        var hasOpenPage = false
        /// node id → (page, first-baseline y in PDF space) for bookmarks.
        var anchors: [String: (page: Int, y: CGFloat)] = [:]
    }

    private static func layOutNode(
        _ id: String,
        depth: Int,
        in model: MapModel,
        context: CGContext,
        layout: OutlineLayout,
        measurer: TextMeasurer
    ) -> OutlineLayout {
        guard let node = model.nodes[id] else { return layout }
        var result = layout

        let font = font(forDepth: depth)
        let indent = CGFloat(depth) * indentStep
        let maxWidth = pageSize.width - pageMargin * 2 - indent
        let textSize = measurer.nodeTitleSize(node.title, font: font, maxWidth: maxWidth)
        let blockHeight = max(textSize.height + 2, 16)

        // Paginate before starting a block that would not fit whole.
        if let cursor = result.cursorY, cursor - blockHeight < pageMargin {
            context.endPDFPage()
            result.hasOpenPage = false
            result.pageIndex += 1
            result.cursorY = nil
        }
        if !result.hasOpenPage {
            context.beginPDFPage(nil)
            result.hasOpenPage = true
            result.cursorY = pageSize.height - pageMargin
        }

        let top = result.cursorY ?? pageSize.height - pageMargin
        drawTitle(
            node.title, font: font, color: textColor(forDepth: depth),
            in: CGRect(
                x: pageMargin + indent, y: top - blockHeight, width: maxWidth, height: blockHeight),
            context: context, measurer: measurer)

        result.anchors[id] = (page: result.pageIndex, y: top - font.lineHeightAscent)
        result.cursorY = top - blockHeight - lineGap
        for child in node.children {
            result = layOutNode(
                child, depth: depth + 1, in: model, context: context, layout: result, measurer: measurer)
        }
        // A touch of breathing room after each top-level branch.
        if depth == 0 {
            result.cursorY = (result.cursorY ?? 0) - lineGap
        }
        return result
    }

    /// One title as a single CTFrame in unflipped (y-up) PDF space: the
    /// frame fills from its rect's top downward.
    private static func drawTitle(
        _ title: NodeTitle, font: FontSpec, color: CGColor, in rect: CGRect,
        context: CGContext, measurer: TextMeasurer
    ) {
        guard !title.text.isEmpty else { return }
        let attributed = measurer.attributed(title, font: font, color: color, lineHeight: 1.25)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.textMatrix = CGAffineTransform.identity
        CTFrameDraw(frame, context)
    }

    // MARK: bookmarks (PDFKit)

    /// Grafts the outline tree in document order, every entry jumping to
    /// its node's first line. Like the map PDF, the pages are copied into
    /// a fresh `PDFDocument` first: PDFKit drops outlines grafted onto a
    /// document loaded straight from bytes.
    private static func addBookmarks(
        to data: Data, model: MapModel, layout: OutlineLayout, title: String
    ) -> Data {
        guard let source = PDFDocument(data: data) else { return data }
        let document = PDFExporter.copyIntoFreshDocument(source)
        let root = PDFOutline()

        var byID: [String: PDFOutline] = [:]
        func makeOutline(_ id: String) -> PDFOutline? {
            guard let node = model.nodes[id], let anchor = layout.anchors[id] else { return nil }
            if let cached = byID[id] { return cached }
            let outline = PDFOutline()
            outline.label = node.title.text
            if let page = document.page(at: anchor.page) {
                outline.destination = PDFDestination(
                    page: page, at: CGPoint(x: pageMargin, y: anchor.y))
            }
            byID[id] = outline
            for child in node.children {
                if let childOutline = makeOutline(child) {
                    outline.insertChild(childOutline, at: outline.numberOfChildren)
                }
            }
            return outline
        }
        for rootID in model.roots {
            if let outline = makeOutline(rootID) {
                root.insertChild(outline, at: root.numberOfChildren)
            }
        }
        guard root.numberOfChildren > 0 else { return data }
        root.label = title
        document.outlineRoot = root
        return document.dataRepresentation() ?? data
    }

    private static func font(forDepth depth: Int) -> FontSpec {
        switch depth {
        case 0: FontSpec(size: 13, weight: 0.4)
        case 1: FontSpec(size: 12, weight: 0.23)
        default: FontSpec(size: 11)
        }
    }

    private static func textColor(forDepth depth: Int) -> CGColor {
        depth == 0
            ? PaperTheme.color(fromHex: 0x1C1C1E)
            : PaperTheme.textColor(for: .light)
    }
}
