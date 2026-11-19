import CanvasKit
import CoreGraphics
import CoreText
import Foundation
import MapCore
import MapRender
import SceneExport

/// Composes the print job (F-INT-9) as a paper-sized vector PDF through
/// the SAME shared `ScenePainter`/`TextMeasurer` primitives the canvas
/// and every export use — so print == export (ADR-0014). The App hands
/// the bytes to `PDFView.printOperation`, which honors the paper size
/// and printable area the user chose in the Print panel and Page Setup.
///
/// Print always renders the LIGHT appearance: the destination is white
/// paper, and a dark canvas background would waste a sheet of ink. The
/// decision (and the whole composed-PDF pipeline) is recorded in
/// ADR-0014.
public enum PrintComposer {
    /// Everything the composer needs from the AppKit side (NSPrintInfo
    /// distilled): paper size, the printable area inside it (in paper
    /// coordinates, y-up, origin at the paper's bottom-left), the user's
    /// options, and the header text.
    public struct Spec: Sendable, Equatable {
        public var paperSize: CGSize
        public var printableRect: CGRect
        public var options: PrintOptions
        public var title: String
        public var date: Date

        public init(
            paperSize: CGSize, printableRect: CGRect, options: PrintOptions, title: String,
            date: Date = Date()
        ) {
            self.paperSize = paperSize
            self.printableRect = printableRect
            self.options = options
            self.title = title
            self.date = date
        }
    }

    /// The number of pages the composed job will have, without
    /// rendering: 1 for fit, the tile grid's count, the outline's
    /// paginated count. The composer draws "page x of y" from this, and
    /// the tests assert the real PDF against it.
    public static func pageCount(
        model: MapModel, spec: Spec, measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) -> Int {
        switch spec.options.mode {
        case .fit:
            return 1
        case .tile:
            let bounds = mapBounds(model: model, measurer: measurer)
            let area = PrintPagination.contentRect(
                printableRect: spec.printableRect, options: spec.options)
            return PrintPagination.tileGrid(
                contentSize: bounds.size, pageSize: area.size,
                overlap: spec.options.tileOverlap
            ).pageCount
        case .outline:
            let area = PrintPagination.contentRect(
                printableRect: spec.printableRect, options: spec.options)
            let blocks = PrintPagination.outlineBlocks(
                model: model, printableWidth: area.width, measurer: measurer)
            return PrintPagination.paginateOutline(blocks, contentHeight: area.height).count
        }
    }

    /// The composed print job: one CGPDF page per printed page at
    /// `spec.paperSize`, header/footer bands inside the printable area,
    /// the map (fit/tile) or the text outline inside the rest.
    public static func compose(
        model: MapModel, spec: Spec, measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) throws -> Data {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: spec.paperSize)
        guard
            let consumer = CGDataConsumer(data: output as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw SceneExportError.pdfContextCreationFailed
        }
        let info: [CFString: Any] = [
            kCGPDFContextTitle: spec.title,
            kCGPDFContextCreator: "Arbor",
        ]

        switch spec.options.mode {
        case .fit:
            let export = try wholeMapExport(model: model, measurer: measurer)
            try composeFitPage(export, spec: spec, context: context, measurer: measurer, info: info)
        case .tile:
            let export = try wholeMapExport(model: model, measurer: measurer)
            let grid = tileGrid(for: export, spec: spec)
            guard grid.pageCount > 0 else { throw SceneExportError.emptyScene }
            for (index, pageRect) in grid.pageRects.enumerated() {
                composeTilePage(
                    export, pageRect: pageRect, index: index, grid: grid, spec: spec,
                    context: context, measurer: measurer, info: info)
            }
        case .outline:
            try composeOutline(model: model, spec: spec, context: context, measurer: measurer, info: info)
        }

        context.closePDF()
        return output as Data
    }

    // MARK: shared geometry

    /// The whole-map export scene (margin included) every mode renders.
    private static func wholeMapExport(
        model: MapModel, measurer: TextMeasurer
    ) throws -> ExportScene {
        guard model.roots.contains(where: { model.nodes[$0] != nil }) else {
            throw SceneExportError.emptyScene
        }
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: measurer)
        let export = ExportGeometry.content(
            scene: scene, model: model, content: .wholeMap, margin: 24)
        guard !export.nodes.isEmpty else { throw SceneExportError.emptyScene }
        return export
    }

    /// The content bounds the fit/tile math works against (without
    /// rendering the scene).
    private static func mapBounds(model: MapModel, measurer: TextMeasurer) -> CGRect {
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: measurer)
        return ExportGeometry.content(
            scene: scene, model: model, content: .wholeMap, margin: 24
        ).bounds
    }

    private static func tileGrid(for export: ExportScene, spec: Spec) -> PrintPagination.TileGrid {
        let area = PrintPagination.contentRect(
            printableRect: spec.printableRect, options: spec.options)
        return PrintPagination.tileGrid(
            contentSize: export.bounds.size, pageSize: area.size, overlap: spec.options.tileOverlap)
    }

    // MARK: page furniture

    /// Header/footer bands and the page number line, drawn in unflipped
    /// (y-up) PDF page space before the map.
    private static func drawBands(
        spec: Spec, pageIndex: Int, pageCount: Int, context: CGContext, measurer: TextMeasurer
    ) {
        let options = spec.options
        guard options.wantsBands else { return }
        let font = FontSpec(size: 9, weight: 0.23)
        let color = PaperTheme.color(fromHex: 0x1C1C1E)
        if options.wantsHeader {
            let band = CGRect(
                x: spec.printableRect.minX,
                y: spec.printableRect.maxY - PrintPagination.headerHeight,
                width: spec.printableRect.width,
                height: PrintPagination.headerHeight)
            if options.showHeaderTitle {
                drawPlain(
                    spec.title, font: font, color: color, in: band, alignment: .left,
                    context: context, measurer: measurer)
            }
            if options.showHeaderDate {
                drawPlain(
                    spec.date.formatted(date: .abbreviated, time: .omitted), font: font,
                    color: color, in: band, alignment: .right,
                    context: context, measurer: measurer)
            }
        }
        if options.showPageNumbers {
            let band = CGRect(
                x: spec.printableRect.minX,
                y: spec.printableRect.minY,
                width: spec.printableRect.width,
                height: PrintPagination.footerHeight)
            drawPlain(
                "Page \(pageIndex + 1) of \(pageCount)", font: font, color: color, in: band,
                alignment: .center, context: context, measurer: measurer)
        }
    }

    /// One plain string as a single CTLine, aligned inside `rect`
    /// (unflipped PDF space, y-up).
    private static func drawPlain(
        _ text: String, font: FontSpec, color: CGColor, in rect: CGRect,
        alignment: CTTextAlignment, context: CGContext, measurer: TextMeasurer
    ) {
        guard !text.isEmpty else { return }
        let attributed = measurer.attributed(
            NodeTitle(text: text), font: font, color: color, lineHeight: 1.25)
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x: CGFloat
        switch alignment {
        case .right: x = rect.maxX - width
        case .center: x = rect.midX - width / 2
        default: x = rect.minX
        }
        let ascent = font.lineHeightAscent
        context.textMatrix = CGAffineTransform.identity
        context.textPosition = CGPoint(
            x: x, y: rect.minY + max(0, (rect.height - ascent) / 2))
        CTLineDraw(line, context)
    }

    // MARK: fit page

    /// The whole map scaled (down, or up to at most `fitScaleCeiling`)
    /// onto one page, centered in the content area.
    private static func composeFitPage(
        _ export: ExportScene, spec: Spec, context: CGContext,
        measurer: TextMeasurer, info: [CFString: Any]
    ) throws {
        let content = PrintPagination.contentRect(
            printableRect: spec.printableRect, options: spec.options)
        let scale = PrintPagination.fitScale(contentBounds: export.bounds, into: content)
        let target = CGRect(
            origin: CGPoint(
                x: content.midX - export.bounds.width * scale / 2,
                y: content.midY - export.bounds.height * scale / 2),
            size: CGSize(
                width: export.bounds.width * scale, height: export.bounds.height * scale))

        context.beginPDFPage(info as CFDictionary)
        if spec.options.includeBackground {
            context.setFillColor(export.canvasColor)
            context.fill(target)
        }
        // The canvas y-down convention after placing the surface's
        // top-left at `target`'s top-left corner (PDF space is y-up).
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        ScenePainter.draw(
            export, measurer: measurer, in: context, background: nil)
        drawBands(spec: spec, pageIndex: 0, pageCount: 1, context: context, measurer: measurer)
        context.endPDFPage()
    }

    // MARK: tile pages

    /// One tile page: the content-space `pageRect` at 1:1 (the natural
    /// print size), clipped to the content area, with dashed overlap
    /// marks where this page repeats its neighbours' content.
    private static func composeTilePage(
        _ export: ExportScene, pageRect: CGRect, index: Int,
        grid: PrintPagination.TileGrid, spec: Spec, context: CGContext,
        measurer: TextMeasurer, info: [CFString: Any]
    ) {
        let content = PrintPagination.contentRect(
            printableRect: spec.printableRect, options: spec.options)
        let page = pageScene(export, pageRect: pageRect)
        let background: CGColor? =
            spec.options.includeBackground ? export.canvasColor : nil

        context.beginPDFPage(info as CFDictionary)
        context.saveGState()
        context.clip(to: content)
        // Content-space (0,0) is the content area's top-left; the
        // page's own rect then lands inside it after the painter's
        // internal -bounds translation.
        context.translateBy(x: content.minX, y: content.maxY)
        context.scaleBy(x: 1, y: -1)
        ScenePainter.draw(page, measurer: measurer, in: context, background: background)
        context.restoreGState()

        drawOverlapMarks(
            pageRect: pageRect, index: index, grid: grid, content: content,
            overlap: spec.options.tileOverlap, context: context)
        drawBands(
            spec: spec, pageIndex: index, pageCount: grid.pageCount, context: context,
            measurer: measurer)
        context.endPDFPage()
    }

    /// Dashed guides at the overlap strips: a vertical mark where this
    /// page repeats the left neighbour's tail, a horizontal one for the
    /// top neighbour. Cut along the dashes and the strips match up.
    private static func drawOverlapMarks(
        pageRect: CGRect, index: Int, grid: PrintPagination.TileGrid, content: CGRect,
        overlap: CGFloat, context: CGContext
    ) {
        let column = index % grid.columns
        let row = index / grid.columns
        guard column > 0 || row > 0, overlap > 0 else { return }
        // Content-space coordinates → page space: (0,0) at the content
        // area's top-left, y down.
        func pagePoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: content.minX + x, y: content.maxY - y)
        }
        context.saveGState()
        context.setStrokeColor(PaperTheme.color(fromHex: 0x8E8E93))
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.setLineWidth(0.8)
        if column > 0 {
            let x = pageRect.minX + overlap
            let top = pagePoint(x, pageRect.minY)
            let bottom = pagePoint(x, pageRect.maxY)
            context.move(to: top)
            context.addLine(to: bottom)
            context.strokePath()
        }
        if row > 0 {
            let y = pageRect.minY + overlap
            let left = pagePoint(pageRect.minX, y)
            let right = pagePoint(pageRect.maxX, y)
            context.move(to: left)
            context.addLine(to: right)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The export filtered down to one tile page (nodes/branches whose
    /// geometry intersects `pageRect`, with `pageRect` as bounds) — the
    /// per-page working set stays bounded on huge maps.
    private static func pageScene(_ export: ExportScene, pageRect: CGRect) -> ExportScene {
        let fuzz: CGFloat = 8
        let visible = pageRect.insetBy(dx: -fuzz, dy: -fuzz)
        var nodes: [SceneNode] = []
        nodes.reserveCapacity(export.nodes.count)
        for node in export.nodes where node.frame.intersects(visible) {
            nodes.append(node)
        }
        var branches: [SceneBranch] = []
        branches.reserveCapacity(export.branches.count)
        for branch in export.branches {
            let rect = CGRect(
                x: min(branch.from.x, branch.to.x), y: min(branch.from.y, branch.to.y),
                width: abs(branch.to.x - branch.from.x), height: abs(branch.to.y - branch.from.y)
            ).insetBy(
                dx: -max(branch.startWidth, branch.endWidth) - fuzz,
                dy: -max(branch.startWidth, branch.endWidth) - fuzz)
            if rect.intersects(visible) {
                branches.append(branch)
            }
        }
        return ExportScene(
            nodes: nodes, branches: branches, bounds: pageRect, canvasColor: export.canvasColor)
    }

    // MARK: outline pages

    /// The text outline (one indented line block per node, roots bold),
    /// paginated like the outline PDF export, with the header/footer
    /// bands the map pages carry.
    private static func composeOutline(
        model: MapModel, spec: Spec, context: CGContext, measurer: TextMeasurer,
        info: [CFString: Any]
    ) throws {
        let content = PrintPagination.contentRect(
            printableRect: spec.printableRect, options: spec.options)
        let blocks = PrintPagination.outlineBlocks(
            model: model, printableWidth: content.width, measurer: measurer)
        guard !blocks.isEmpty else { throw SceneExportError.emptyScene }
        let pages = PrintPagination.paginateOutline(blocks, contentHeight: content.height)

        let indentStep: CGFloat = 18
        for (pageIndex, pageBlocks) in pages.enumerated() {
            context.beginPDFPage(info as CFDictionary)
            var top = content.maxY
            for block in pageBlocks {
                guard let node = model.nodes[block.id] else { continue }
                let font = PrintPagination.outlineFont(forDepth: block.depth)
                let indent = CGFloat(block.depth) * indentStep
                let maxWidth = content.width - indent
                let textSize = measurer.nodeTitleSize(node.title, font: font, maxWidth: maxWidth)
                let blockHeight = max(textSize.height + 2, 16)
                top -= blockHeight
                drawTitle(
                    node.title, font: font,
                    color: block.depth == 0
                        ? PaperTheme.color(fromHex: 0x1C1C1E)
                        : PaperTheme.textColor(for: .light),
                    in: CGRect(
                        x: content.minX + indent, y: top, width: maxWidth, height: blockHeight),
                    context: context, measurer: measurer)
                top -= block.height - blockHeight
            }
            drawBands(
                spec: spec, pageIndex: pageIndex, pageCount: pages.count, context: context,
                measurer: measurer)
            context.endPDFPage()
        }
    }

    /// One node title as a single CTFrame in unflipped (y-up) page
    /// space — the same drawing `OutlinePDFExporter` uses.
    private static func drawTitle(
        _ title: NodeTitle, font: FontSpec, color: CGColor, in rect: CGRect,
        context: CGContext, measurer: TextMeasurer
    ) {
        guard !title.text.isEmpty else { return }
        let attributed = measurer.attributed(title, font: font, color: color, lineHeight: 1.25)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        context.textMatrix = CGAffineTransform.identity
        CTFrameDraw(frame, context)
    }
}
