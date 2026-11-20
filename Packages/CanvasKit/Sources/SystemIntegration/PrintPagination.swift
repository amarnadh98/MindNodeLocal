import CoreGraphics
import Foundation
import MapCore
import MapRender
import SceneExport

/// The F-INT-9 print modes.
public enum PrintMode: String, Sendable, CaseIterable {
    /// The whole map scaled onto a single page.
    case fit
    /// The map at its natural size across a grid of pages, with
    /// overlap marks where pages share content.
    case tile
    /// The text outline (one indented line block per node), paginated.
    case outline
}

/// The user's print choices (the accessory panel's state): the mode
/// plus the header/footer toggles.
public struct PrintOptions: Sendable, Equatable {
    public var mode: PrintMode = .fit
    public var includeBackground = true
    /// Tile overlap in points: content each page repeats from its
    /// neighbour, so a cut through a node can be re-read on the next
    /// page.
    public var tileOverlap: CGFloat = 12
    public var showHeaderTitle = true
    public var showHeaderDate = true
    public var showPageNumbers = true

    public init(mode: PrintMode = .fit) {
        self.mode = mode
    }

    /// Whether any header/footer band is wanted at all.
    public var wantsBands: Bool {
        showHeaderTitle || showHeaderDate || showPageNumbers
    }

    /// Whether the header strip itself has anything to show.
    public var wantsHeader: Bool {
        showHeaderTitle || showHeaderDate
    }
}

/// The print pagination math (F-INT-9), pure and testable: the fit
/// scale, the tile grid with overlap, and the outline's line-block
/// pagination. `PrintComposer` and the hosted print tests both consume
/// these — the composer draws pages the same functions count.
public enum PrintPagination {
    /// The header band's height above the content area.
    public static let headerHeight: CGFloat = 18
    /// The footer band's height below the content area.
    public static let footerHeight: CGFloat = 18
    /// The gap between the bands and the content area.
    public static let bandGap: CGFloat = 8
    /// Fit never upscales a small map beyond this factor, so a
    /// one-node map does not become a full page of background.
    public static let fitScaleCeiling: CGFloat = 2

    /// The content rectangle inside the printable area once the
    /// header/footer bands are reserved (only when the options want
    /// them): the header eats the top, the footer the bottom.
    public static func contentRect(printableRect: CGRect, options: PrintOptions) -> CGRect {
        var rect = printableRect
        guard options.wantsBands else { return rect }
        if options.wantsHeader {
            rect.size.height -= headerHeight + bandGap
        }
        if options.showPageNumbers {
            rect.origin.y += footerHeight + bandGap
            rect.size.height -= footerHeight + bandGap
        }
        return rect
    }

    /// The scale that fits `contentBounds` inside `contentRect`:
    /// `min(w/W, h/H)`, capped at `fitScaleCeiling`, never negative.
    public static func fitScale(contentBounds: CGRect, into contentRect: CGRect) -> CGFloat {
        guard contentBounds.width > 0, contentBounds.height > 0,
            contentRect.width > 0, contentRect.height > 0
        else { return 1 }
        let scale = min(
            contentRect.width / contentBounds.width, contentRect.height / contentBounds.height)
        return min(max(scale, 0), fitScaleCeiling)
    }

    /// A tile grid: the pages' slices of the content, in print order
    /// (rows top→bottom, columns left→right).
    public struct TileGrid: Sendable, Equatable {
        public let columns: Int
        public let rows: Int
        /// The content-space rect each page shows, clipped to the
        /// content's own extent.
        public let pageRects: [CGRect]

        public var pageCount: Int { pageRects.count }
    }

    /// The tile grid for `contentSize` over pages of `pageSize`
    /// (both the content area per page, after bands), where adjacent
    /// pages repeat `overlap` points of content. The first page starts
    /// at the content's origin; every further page advances by
    /// `pageSize - overlap`. Overlap must leave positive advance; a
    /// degenerate overlap is clamped to half the page.
    public static func tileGrid(
        contentSize: CGSize, pageSize: CGSize, overlap: CGFloat
    ) -> TileGrid {
        guard contentSize.width > 0, contentSize.height > 0,
            pageSize.width > 0, pageSize.height > 0
        else {
            return TileGrid(columns: 0, rows: 0, pageRects: [])
        }
        let safeOverlap = min(overlap, pageSize.width / 2, pageSize.height / 2)
        let advanceX = pageSize.width - safeOverlap
        let advanceY = pageSize.height - safeOverlap

        func pages(along content: CGFloat, page: CGFloat, advance: CGFloat) -> Int {
            guard content > page else { return 1 }
            return Int(ceil((content - page) / advance)) + 1
        }
        let columns = pages(along: contentSize.width, page: pageSize.width, advance: advanceX)
        let rows = pages(along: contentSize.height, page: pageSize.height, advance: advanceY)

        var rects: [CGRect] = []
        rects.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let pageRect = CGRect(
                    x: CGFloat(column) * advanceX,
                    y: CGFloat(row) * advanceY,
                    width: pageSize.width,
                    height: pageSize.height)
                let clipped = pageRect.intersection(
                    CGRect(origin: .zero, size: contentSize))
                rects.append(clipped.isNull ? pageRect : clipped)
            }
        }
        return TileGrid(columns: columns, rows: rows, pageRects: rects)
    }

    // MARK: outline pagination

    /// One node's outline block: the measured line height plus where it
    /// sits in the tree.
    public struct OutlineBlock: Sendable, Equatable {
        public let id: String
        public let depth: Int
        /// The block's height including its line gap (the vertical
        /// budget a page must fit it in).
        public let height: CGFloat

        public init(id: String, depth: Int, height: CGFloat) {
            self.id = id
            self.depth = depth
            self.height = height
        }
    }

    /// The outline's line blocks in document order, measured through the
    /// shared `TextMeasurer` (the same measurement the canvas and
    /// OutlinePDFExporter use). Roots get the extra breathing room the
    /// outline exporter gives a top-level branch.
    public static func outlineBlocks(
        model: MapModel, printableWidth: CGFloat, measurer: TextMeasurer
    ) -> [OutlineBlock] {
        let indentStep: CGFloat = 18
        let lineGap: CGFloat = 3
        var blocks: [OutlineBlock] = []
        for id in ExportGeometry.orderedNodeIDs(model: model, content: .wholeMap) {
            guard let node = model.nodes[id] else { continue }
            let depth = depth(of: id, in: model)
            let font = outlineFont(forDepth: depth)
            let maxWidth = printableWidth - CGFloat(depth) * indentStep
            let textSize = measurer.nodeTitleSize(node.title, font: font, maxWidth: maxWidth)
            var height = max(textSize.height + 2, 16) + lineGap
            if depth == 0 { height += lineGap }
            blocks.append(OutlineBlock(id: id, depth: depth, height: height))
        }
        return blocks
    }

    /// Greedy pagination: each page takes whole blocks top-down; a
    /// block taller than the page still gets its own page rather than
    /// vanishing.
    public static func paginateOutline(
        _ blocks: [OutlineBlock], contentHeight: CGFloat
    ) -> [[OutlineBlock]] {
        guard !blocks.isEmpty, contentHeight > 0 else { return blocks.isEmpty ? [] : [blocks] }
        var pages: [[OutlineBlock]] = []
        var current: [OutlineBlock] = []
        var used: CGFloat = 0
        for block in blocks {
            if !current.isEmpty, used + block.height > contentHeight {
                pages.append(current)
                current = []
                used = 0
            }
            current.append(block)
            used += block.height
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// The outline's fonts (mirroring `OutlinePDFExporter`, so the
    /// printed outline matches the exported one).
    public static func outlineFont(forDepth depth: Int) -> FontSpec {
        switch depth {
        case 0: FontSpec(size: 13, weight: 0.4)
        case 1: FontSpec(size: 12, weight: 0.23)
        default: FontSpec(size: 11)
        }
    }

    /// The node's depth: 0 for roots, parent's + 1 otherwise. A
    /// malformed parent cycle (already a validator offense) is cut off
    /// at the node count rather than looping.
    static func depth(of id: String, in model: MapModel) -> Int {
        var depth = 0
        var visited: Set<String> = [id]
        var current = model.nodes[id]?.parent
        while let parentID = current, model.nodes[parentID] != nil, visited.insert(parentID).inserted {
            depth += 1
            current = model.nodes[parentID]?.parent
        }
        return depth
    }
}
