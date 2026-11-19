import Foundation
import MapCore
import PDFKit
import Testing

@testable import SceneExport

/// Structural tests for the vector PDF export (SPEC §5.17): page count,
/// extractable text, and the document outline mirroring the tree.
struct PDFExporterTests {
    @Test func wholeMapPDFHasOnePageTextAndTreeMirroringBookmarks() throws {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)

        let data = try PDFExporter.export(
            scene: scene, model: model,
            options: PDFExportOptions(content: .map(.wholeMap), title: "Trip"))

        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount == 1)
        let pageText = try #require(document.page(at: 0)?.string)
        #expect(pageText.contains("Root Idea"))
        #expect(pageText.contains("Alpha Child"))

        let outline = try #require(document.outlineRoot)
        #expect(outline.numberOfChildren == 1)
        let rootOutline = try #require(outline.child(at: 0))
        #expect(rootOutline.label == "Root Idea")
        #expect(rootOutline.numberOfChildren == 2)
        #expect(rootOutline.child(at: 0)?.label == "Alpha")
        #expect(rootOutline.child(at: 0)?.numberOfChildren == 1)
        #expect(rootOutline.child(at: 0)?.child(at: 0)?.label == "Alpha Child")
        #expect(rootOutline.child(at: 1)?.label == "Beta")
    }

    @Test func backgroundOptionBothProduceValidPDFs() throws {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)

        for includeBackground in [true, false] {
            let data = try PDFExporter.export(
                scene: scene, model: model,
                options: PDFExportOptions(
                    content: .map(.wholeMap), includeBackground: includeBackground))
            let document = try #require(PDFDocument(data: data))
            #expect(document.pageCount == 1)
        }
    }

    @Test func selectionSubtreePDFContainsOnlyTheSelectedBranch() throws {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)

        let data = try PDFExporter.export(
            scene: scene, model: model,
            options: PDFExportOptions(content: .map(.subtree(["alpha-node"]))))

        let document = try #require(PDFDocument(data: data))
        let pageText = try #require(document.page(at: 0)?.string)
        #expect(pageText.contains("Alpha"))
        #expect(pageText.contains("Alpha Child"))
        #expect(!pageText.contains("Beta"))
        // The bookmark tree follows the exported subtree root.
        let outline = try #require(document.outlineRoot)
        #expect(outline.numberOfChildren == 1)
        #expect(outline.child(at: 0)?.label == "Alpha")
    }

    @Test func oversizedMapScalesDownToPDFsPageLimit() throws {
        var model = MapModel.emptyDocument()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let root = Node(id: "wide-root", title: NodeTitle(text: "Wide"), created: timestamp, modified: timestamp)
        var child = Node(id: "far-child", title: NodeTitle(text: "Far"), created: timestamp, modified: timestamp)
        child.parent = "wide-root"
        child.offset = ModelOffset(x: 20_000, y: 0)
        model.nodes["wide-root"] = root
        model.nodes["far-child"] = child
        model.roots = ["wide-root"]
        model.nodes["wide-root"]?.children = ["far-child"]

        let scene = ExportFixtures.scene(for: model)
        let data = try PDFExporter.export(
            scene: scene, model: model, options: PDFExportOptions(content: .map(.wholeMap)))

        let document = try #require(PDFDocument(data: data))
        let pageBounds = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(pageBounds.width <= 14_400)
        #expect(pageBounds.height <= 14_400)
    }

    @Test func outlinePDFPaginatesAndMirrorsTheTree() throws {
        let model = ExportFixtures.canonicalMap()

        let data = try PDFExporter.export(
            scene: ExportFixtures.scene(for: model), model: model,
            options: PDFExportOptions(content: .outline, title: "Outline"))

        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount >= 1)
        var allText = ""
        for index in 0..<document.pageCount {
            allText += document.page(at: index)?.string ?? ""
        }
        #expect(allText.contains("Root Idea"))
        #expect(allText.contains("Alpha Child"))

        let outline = try #require(document.outlineRoot)
        #expect(outline.numberOfChildren == 1)
        #expect(outline.child(at: 0)?.label == "Root Idea")
        #expect(outline.child(at: 0)?.numberOfChildren == 2)
    }

    @Test func emptySceneThrowsInsteadOfRenderingNothing() {
        let model = MapModel.emptyDocument()
        let scene = ExportFixtures.scene(for: model)
        #expect(throws: SceneExportError.emptyScene) {
            _ = try PDFExporter.export(
                scene: scene, model: model, options: PDFExportOptions(content: .map(.wholeMap)))
        }
    }
}
