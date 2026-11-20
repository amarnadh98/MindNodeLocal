import CoreGraphics
import Foundation
import MapCore
import MapRender
import SystemIntegration
import Testing

/// F-INT-9's pagination math: the fit scale, the tile grid with
/// overlap, and the outline's line-block pagination — the pure
/// functions `PrintComposer` draws from.
@Suite
struct PrintPaginationTests {
    // MARK: bands

    @Test func contentRectReservesOnlyWantedBands() {
        let printable = CGRect(x: 18, y: 18, width: 576, height: 756)
        // Nothing wanted: the full printable area is the content area.
        var options = PrintOptions()
        options.showHeaderTitle = false
        options.showHeaderDate = false
        options.showPageNumbers = false
        #expect(PrintPagination.contentRect(printableRect: printable, options: options) == printable)

        // All bands on: header + gap off the top, footer + gap off the
        // bottom.
        let all = PrintPagination.contentRect(printableRect: printable, options: PrintOptions())
        #expect(all.minY == printable.minY + PrintPagination.footerHeight + PrintPagination.bandGap)
        #expect(all.maxY == printable.maxY - PrintPagination.headerHeight - PrintPagination.bandGap)
        #expect(
            all.height
                == printable.height
                - PrintPagination.headerHeight - PrintPagination.footerHeight
                - 2 * PrintPagination.bandGap)

        // Only page numbers: no header band even though title/date are
        // off — the header disappears with its content.
        var footerOnly = PrintOptions()
        footerOnly.showHeaderTitle = false
        footerOnly.showHeaderDate = false
        let footerRect = PrintPagination.contentRect(printableRect: printable, options: footerOnly)
        #expect(footerRect.maxY == printable.maxY)
    }

    // MARK: fit scale

    @Test func fitScaleScalesDownAndCapsUpscale() {
        // Landscape map into portrait page: the binding dimension is
        // width.
        let content = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let page = CGRect(x: 0, y: 0, width: 576, height: 672)
        #expect(PrintPagination.fitScale(contentBounds: content, into: page) ~= 576.0 / 1200.0)

        // A small map upscales, but never past the ceiling.
        let small = CGRect(x: 0, y: 0, width: 100, height: 60)
        #expect(
            PrintPagination.fitScale(contentBounds: small, into: page)
                == PrintPagination.fitScaleCeiling)

        // Degenerate input never divides by zero.
        #expect(PrintPagination.fitScale(contentBounds: .zero, into: page) == 1)
        #expect(PrintPagination.fitScale(contentBounds: content, into: .zero) == 1)
    }

    // MARK: tile grid

    @Test func tileGridSinglePageWhenContentFits() {
        let grid = PrintPagination.tileGrid(
            contentSize: CGSize(width: 400, height: 300),
            pageSize: CGSize(width: 500, height: 400),
            overlap: 12)
        #expect(grid.columns == 1)
        #expect(grid.rows == 1)
        #expect(grid.pageRects == [CGRect(x: 0, y: 0, width: 400, height: 300)])
    }

    @Test func tileGridCountsColumnsAndRows() {
        // 1000 pt wide over 400 pt pages with 50 pt overlap: advances of
        // 350 → columns cover 1000 at ceil(600/350)+1 = 3.
        let grid = PrintPagination.tileGrid(
            contentSize: CGSize(width: 1000, height: 900),
            pageSize: CGSize(width: 400, height: 400),
            overlap: 50)
        #expect(grid.columns == 3)
        #expect(grid.rows == 3)
        #expect(grid.pageCount == 9)
        // Page order: rows top→bottom, columns left→right; each rect is
        // clipped to the content's own extent.
        #expect(grid.pageRects[0] == CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(grid.pageRects[1] == CGRect(x: 350, y: 0, width: 400, height: 400))
        #expect(grid.pageRects[3] == CGRect(x: 0, y: 350, width: 400, height: 400))
        #expect(grid.pageRects[8] == CGRect(x: 700, y: 700, width: 300, height: 200))
    }

    @Test func overlapAddsRepetitionNotMissedContent() {
        let size = CGSize(width: 2000, height: 500)
        let page = CGSize(width: 500, height: 400)
        let noOverlap = PrintPagination.tileGrid(contentSize: size, pageSize: page, overlap: 0)
        let overlap = PrintPagination.tileGrid(contentSize: size, pageSize: page, overlap: 100)
        // Overlap repeats content on each page, so the advance per page
        // shrinks and the grid needs MORE columns — the price of cuts
        // that can be re-read.
        #expect(noOverlap.columns == 4)
        #expect(overlap.columns == 5)
        // Every page still advances: the grid never stalls.
        let advances = zip(overlap.pageRects, overlap.pageRects.dropFirst())
            .prefix(overlap.columns - 1)
        for (left, right) in advances {
            #expect(right.minX - left.minX == 400)
        }
    }

    @Test func degenerateOverlapIsClampedNotInfinite() {
        // Overlap ≥ page size would divide by a non-positive advance;
        // it clamps to half the page and still paginates.
        let grid = PrintPagination.tileGrid(
            contentSize: CGSize(width: 2000, height: 2000),
            pageSize: CGSize(width: 500, height: 500),
            overlap: 5000)
        #expect(grid.columns > 1)
        #expect(grid.rows > 1)
        #expect(grid.pageCount == grid.columns * grid.rows)

        // Degenerate sizes: an empty grid, never a crash.
        let empty = PrintPagination.tileGrid(
            contentSize: .zero, pageSize: CGSize(width: 500, height: 500), overlap: 12)
        #expect(empty.pageCount == 0)
    }

    // MARK: outline pagination

    private func block(_ id: String, height: CGFloat, depth: Int = 0)
        -> PrintPagination.OutlineBlock
    {
        PrintPagination.OutlineBlock(id: id, depth: depth, height: height)
    }

    @Test func paginateOutlinePacksWholeBlocks() {
        let blocks = (0..<10).map { block("n\($0)", height: 20) }
        // 95 pt fits 4 blocks per page (5 × 20 = 100 > 95).
        let pages = PrintPagination.paginateOutline(blocks, contentHeight: 95)
        #expect(pages.count == 3)
        #expect(pages.map(\.count) == [4, 4, 2])
        // A block is never split across pages.
        for page in pages {
            #expect(page.reduce(0) { $0 + $1.height } <= 95 || page.count == 1)
        }
    }

    @Test func paginateOutlineKeepsAnOversizedBlockVisible() {
        // A block taller than the page still appears, on its own page.
        let blocks = [block("huge", height: 500), block("small", height: 10)]
        let pages = PrintPagination.paginateOutline(blocks, contentHeight: 100)
        #expect(pages.count == 2)
        #expect(pages[0].map(\.id) == ["huge"])
        #expect(pages[1].map(\.id) == ["small"])
    }

    @Test func outlineBlocksMeasureEveryNodeInDocumentOrder() {
        let measurer = TextMeasurer()
        let model = outlineModel()
        let blocks = PrintPagination.outlineBlocks(
            model: model, printableWidth: 500, measurer: measurer)
        #expect(blocks.map(\.id) == ["root", "alpha", "alpha-child", "beta"])
        // Depths: root 0, children 1, grandchild 2.
        #expect(blocks.map(\.depth) == [0, 1, 2, 1])
        // Every block has a sane, positive height.
        for block in blocks {
            #expect(block.height >= 19)
        }
        // Roots carry the outline exporter's extra breathing room.
        #expect(blocks[0].height > blocks[2].height)
    }

    /// Root → (Alpha → Alpha Child), Beta — the canonical small map.
    private func outlineModel() -> MapModel {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var model = MapModel.emptyDocument()
        func add(_ id: String, _ text: String, parent: String? = nil) {
            var node = Node(id: id, title: NodeTitle(text: text), created: date, modified: date)
            node.parent = parent
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
            model.nodes[id] = node
        }
        add("root", "Trip")
        add("alpha", "Pack", parent: "root")
        add("alpha-child", "Passport", parent: "alpha")
        add("beta", "Budget", parent: "root")
        return model
    }
}
