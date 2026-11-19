import AppKit
import CanvasKit
import Foundation
import ImageIO
import MapCore
import MapIO
import PDFKit
import SceneExport
import SwiftUI
import Testing

@testable import Arbor

/// F-IO UI wiring (M5 slice 2): ⌥⌘E presents the export sheet; the
/// sheet's export path round-trips OPML through the importer; opening a
/// foreign `.opml` file lands as a NEW untitled Arbor document; and a
/// real save writes the F-INT-3 Quick Look previews into the package.
@MainActor
struct ExportImportTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// Root → (Alpha → Alpha Child), Beta, plus a note and a done task.
    private static func canonicalModel() -> MapModel {
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
        model.nodes["alpha-child"]?.note = "Check expiry date"
        model.nodes["beta"]?.task = NodeTask(done: true)
        return model
    }

    private func makeDocument() throws -> MapDocument {
        try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
    }

    // MARK: the export sheet (⌥⌘E)

    @Test func exportActionPresentsTheSheet() throws {
        let document = try makeDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)

        controller.exportAction(nil)

        let sheet = try #require(controller.window?.attachedSheet)
        let hosting = try #require(
            sheet.contentViewController as? NSHostingController<ExportSheetView>)
        // The format picker offers every exportable registry entry except
        // the native package; PDF is the default format.
        let offered = hosting.rootView.formats.map(\.id)
        #expect(offered.contains(DocumentFormats.opml.id))
        #expect(offered.contains(DocumentFormats.pdf.id))
        #expect(offered.contains(DocumentFormats.svg.id))
        #expect(!offered.contains(DocumentFormats.arbor.id))
        #expect(!offered.contains(DocumentFormats.xmind.id))

        controller.window?.endSheet(sheet)
    }

    // MARK: the export path round-trips

    @Test func opmlExportThroughTheSheetPathRoundTripsThroughTheImporter() throws {
        let model = Self.canonicalModel()
        var choice = ExportChoice(formatID: DocumentFormats.opml.id)

        let data = try ExportCoordinator.exportData(
            choice: choice, model: model, scene: nil, selection: [], variant: .light,
            documentTitle: "Trip")
        let imported = try DocumentIO.importDocument(data, format: DocumentFormats.opml)

        // Importers assign fresh ids (like every paste/import), so the
        // round trip is compared structurally, from the roots down.
        #expect(imported.nodes.count == model.nodes.count)
        #expect(imported.roots.count == model.roots.count)
        try compareTrees(model, imported)

        // Markdown honors the sheet's heading-depth option.
        choice.formatID = DocumentFormats.markdown.id
        choice.markdownHeadingDepth = 0
        let flatMarkdown =
            String(
                data: try ExportCoordinator.exportData(
                    choice: choice, model: model, scene: nil, selection: [], variant: .light,
                    documentTitle: "Trip"), encoding: .utf8) ?? ""
        #expect(!flatMarkdown.contains("#"))

        // PNG export carries the scale option and the right UTType.
        choice.formatID = DocumentFormats.png.id
        choice.imageScale = 2
        let png = try ExportCoordinator.exportData(
            choice: choice, model: model, scene: nil, selection: [], variant: .light,
            documentTitle: "Trip")
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width > 200)
        #expect(ExportCoordinator.utType(for: DocumentFormats.png) == .png)
    }

    // MARK: opening foreign files

    @Test func openingAnOPMLFileCreatesAnUntitledArborDocument() throws {
        let opml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head><title>Groceries</title></head>
              <body>
                <outline text="Grocery Run">
                  <outline text="Produce"/>
                  <outline text="Dairy" _note="Get oat milk"/>
                </outline>
              </body>
            </opml>
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-\(UUID().uuidString).opml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(opml.utf8).write(to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: "org.opml.opml") as? MapDocument)

        // A NEW untitled Arbor document: the source file is untouched,
        // the file URL is dropped, and the next save asks for a location.
        #expect(document.fileURL == nil)
        #expect(document.fileType == AppIdentity.documentUTI)
        #expect(document.model.nodes.count == 3)
        #expect(document.model.roots.count == 1)
        // The OPML head title became the document title, which F-EDT-14
        // says wins over the root-derived name.
        #expect(document.displayName == "Groceries")
        // Saving the import writes a native package, never back over the
        // OPML source.
        let saved = FileManager.default.temporaryDirectory
            .appendingPathComponent("imported-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: saved) }
        try document.write(to: saved, ofType: AppIdentity.documentUTI)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(
            FileManager.default.fileExists(atPath: url.path), "the OPML source must survive")
    }

    @Test func importPanelPathCreatesTheSameUntitledDocument() throws {
        let opml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0"><head/><body>
              <outline text="Single"/>
            </body></opml>
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panel-\(UUID().uuidString).opml")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(opml.utf8).write(to: url)

        let document = try DocumentImporter.openForeignDocument(at: url)
        #expect(document.fileURL == nil)
        #expect(document.model.nodes.count == 1)
        #expect(document.model.roots.count == 1)
    }

    // MARK: Quick Look previews on save (F-INT-3)

    @Test func saveWritesQuickLookThumbnailAndPDFPreview() throws {
        let document = try makeDocument()
        document.adoptImportedModel(Self.canonicalModel())

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.write(to: url, ofType: AppIdentity.documentUTI)

        let thumbnailURL = url.appendingPathComponent("QuickLook/Thumbnail.png")
        let previewURL = url.appendingPathComponent("QuickLook/Preview.pdf")
        #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
        #expect(FileManager.default.fileExists(atPath: previewURL.path))

        // The thumbnail fits 512 px on its long edge.
        let thumbnailData = try Data(contentsOf: thumbnailURL)
        let source = try #require(CGImageSourceCreateWithData(thumbnailData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == DocumentQuickLook.thumbnailLongEdgePixels)

        // The preview is the whole-map vector PDF.
        let preview = try #require(PDFDocument(url: previewURL))
        #expect(preview.pageCount == 1)
        let text = try #require(preview.page(at: 0)?.string)
        #expect(text.contains("Trip"))
        #expect(text.contains("Passport"))
    }

    // MARK: save cost (5k fixture)

    /// The QL render happens inside a real save, so this measures the
    /// whole explicit-save cost on the 5k fixture the SPEC budgets
    /// against (§11.8: PDF export < 1 s, autosave < 2 ms — autosaves
    /// skip previews by design). Timings are printed for the record;
    /// Debug-build numbers are ~an order above release.
    @Test func explicitSaveWithQuickLookPreviewsStaysReasonable() throws {
        let document = try makeDocument()
        document.adoptImportedModel(Self.bigMap(nodeCount: 5_000))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-ql-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }

        let start = CFAbsoluteTimeGetCurrent()
        let previewStart = CFAbsoluteTimeGetCurrent()
        let payloads = try DocumentQuickLook.renderPayloads(
            model: document.model, variant: .light)
        let previewSeconds = CFAbsoluteTimeGetCurrent() - previewStart
        try document.write(to: url, ofType: AppIdentity.documentUTI)
        let totalSeconds = CFAbsoluteTimeGetCurrent() - start

        print(
            String(
                format: "5k save timings: QuickLook render %.0f ms, full save %.0f ms",
                previewSeconds * 1_000, totalSeconds * 1_000))
        #expect(!payloads.thumbnail.isEmpty)
        #expect(!payloads.preview.isEmpty)
        #expect(previewSeconds < 10, "pathological Quick Look cost regression")
    }

    /// Walks both trees root-by-root, matching by position: titles,
    /// notes and task state round-trip through OPML (per the F-IO
    /// matrix), children keep their order.
    private func compareTrees(_ original: MapModel, _ roundTripped: MapModel) throws {
        func walk(originalID: String, importedID: String) throws {
            let originalNode = try #require(original.nodes[originalID])
            let importedNode = try #require(roundTripped.nodes[importedID])
            #expect(originalNode.title.text == importedNode.title.text)
            #expect(originalNode.note == importedNode.note)
            #expect(originalNode.task?.done == importedNode.task?.done)
            #expect(originalNode.children.count == importedNode.children.count)
            for (childIndex, originalChild) in originalNode.children.enumerated() {
                guard childIndex < importedNode.children.count else { return }
                try walk(originalID: originalChild, importedID: importedNode.children[childIndex])
            }
        }
        #expect(original.roots.count == roundTripped.roots.count)
        for (rootIndex, rootID) in original.roots.enumerated() {
            guard rootIndex < roundTripped.roots.count else { return }
            try walk(originalID: rootID, importedID: roundTripped.roots[rootIndex])
        }
    }

    /// 1 root → 8 level-1 branches → `nodeCount` leaves total.
    private static func bigMap(nodeCount: Int) -> MapModel {
        var model = MapModel.emptyDocument()
        let rootID = "big-root"
        model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: "Big"), created: date, modified: date)
        model.roots = [rootID]
        let branchCount = 8
        let leafCount = max(0, nodeCount - 1 - branchCount)
        for branchIndex in 0..<branchCount {
            let branchID = "branch-\(branchIndex)"
            model.nodes[branchID] = Node(
                id: branchID, parent: rootID, title: NodeTitle(text: "Branch \(branchIndex)"),
                created: date, modified: date)
            model.nodes[rootID]?.children.append(branchID)
        }
        let perBranch = leafCount / branchCount
        let remainder = leafCount % branchCount
        for branchIndex in 0..<branchCount {
            let leaves = perBranch + (branchIndex == 0 ? remainder : 0)
            for leafIndex in 0..<leaves {
                let leafID = "leaf-\(branchIndex)-\(leafIndex)"
                model.nodes[leafID] = Node(
                    id: leafID, parent: "branch-\(branchIndex)",
                    title: NodeTitle(text: "Leaf \(leafIndex)"), created: date, modified: date)
                model.nodes["branch-\(branchIndex)"]?.children.append(leafID)
            }
        }
        return model
    }
}
