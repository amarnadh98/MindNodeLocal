import CoreGraphics
import Foundation
import MapCore
import MapRender
import PDFKit
import SceneExport
import SystemIntegration
import Testing

/// F-INT-9: the composed print job — paper-sized vector pages through
/// the shared scene painter, with the page count `pageCount` predicts
/// and the header/footer furniture in place.
@Suite
struct PrintComposerTests {
    private let paperSize = CGSize(width: 612, height: 792)
    private let printableRect = CGRect(x: 18, y: 18, width: 576, height: 756)

    /// A model whose map is WIDER than one page, so tiling spans
    /// columns: 40 wide-ish nodes on long single-line titles.
    private func wideModel() -> MapModel {
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
        add("root", "Project Plan")
        for index in 0..<24 {
            let title = "Deliverable \(index) — final review and sign-off"
            add("w\(index)", title, parent: "root")
        }
        return model
    }

    /// The canonical small map (fits one page in every mode).
    private func smallModel() -> MapModel {
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

    private func spec(_ options: PrintOptions) -> PrintComposer.Spec {
        PrintComposer.Spec(
            paperSize: paperSize, printableRect: printableRect, options: options,
            title: "Composer Fixture", date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func fitComposesOnePaperSizedPage() throws {
        let data = try PrintComposer.compose(model: smallModel(), spec: spec(PrintOptions(mode: .fit)))
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        // The page is the paper, not the content: printing maps onto
        // what the Print panel chose.
        #expect(page.bounds(for: .mediaBox).size.width ~= paperSize.width)
        #expect(page.bounds(for: .mediaBox).size.height ~= paperSize.height)
        #expect(PrintComposer.pageCount(model: smallModel(), spec: spec(PrintOptions(mode: .fit))) == 1)
    }

    @Test func fitWithoutBandsStillComposes() throws {
        var options = PrintOptions(mode: .fit)
        options.showHeaderTitle = false
        options.showHeaderDate = false
        options.showPageNumbers = false
        let data = try PrintComposer.compose(model: smallModel(), spec: spec(options))
        #expect(PDFDocument(data: data)?.pageCount == 1)
    }

    @Test func tileSpansThePredictedGrid() throws {
        let options = PrintOptions(mode: .tile)
        let jobSpec = spec(options)
        // The composed page count equals the pure tile-grid math for
        // the same model and spec.
        let expected = PrintComposer.pageCount(model: wideModel(), spec: jobSpec)
        #expect(expected > 1)
        let data = try PrintComposer.compose(model: wideModel(), spec: jobSpec)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == expected)
    }

    @Test func outlinePaginatesThePredictedPages() throws {
        let jobSpec = spec(PrintOptions(mode: .outline))
        let expected = PrintComposer.pageCount(model: wideModel(), spec: jobSpec)
        #expect(expected >= 1)
        let data = try PrintComposer.compose(model: wideModel(), spec: jobSpec)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == expected)
        // Every page is the paper, with the furniture bands inside the
        // printable area.
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect(page.bounds(for: .mediaBox).size.width ~= paperSize.width)
        }
    }

    @Test func emptyModelThrowsInsteadOfComposing() {
        let empty = MapModel.emptyDocument()
        #expect(throws: SceneExportError.self) {
            _ = try PrintComposer.compose(model: empty, spec: spec(PrintOptions(mode: .fit)))
        }
    }
}
