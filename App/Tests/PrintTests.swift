import AppKit
import Foundation
import MapCore
import PDFKit
import SystemIntegration
import Testing

@testable import Arbor

/// F-INT-9 (M4's print slice): the print menu binding, the accessory
/// panel's options, the composed job's page count (fit / tile /
/// outline), and the operation run to a PDF FILE (not a printer) — the
/// full NSPrintOperation path, verified headlessly.
@MainActor
struct PrintTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// Root → (Alpha → Alpha Child), Beta, plus a note and a done task.
    private func canonicalModel() -> MapModel {
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

    /// A 24-branch map whose bounds exceed one page, so tiling spans a
    /// grid of pages.
    private func wideModel() -> MapModel {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var model = MapModel.emptyDocument()
        var root = Node(id: "root", title: NodeTitle(text: "Project Plan"), created: date, modified: date)
        model.nodes["root"] = root
        model.roots = ["root"]
        for index in 0..<24 {
            let text = "Deliverable \(index) — final review and sign-off"
            var node = Node(id: "w\(index)", title: NodeTitle(text: text), created: date, modified: date)
            node.parent = "root"
            model.nodes["w\(index)"] = node
            root.children.append("w\(index)")
        }
        model.nodes["root"] = root
        return model
    }

    private func makeDocument() throws -> MapDocument {
        try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
    }

    /// A print info with a fixed paper and a SAVE disposition writing to
    /// `url` — running the operation spools the job to that PDF file
    /// instead of a printer. The modern `NSPrintJobSavingURL` key (the
    /// deprecated `NSPrintSavePath` is ignored by the current print
    /// stack).
    private func filePrintInfo(to url: URL, paper: CGSize) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = paper
        info.jobDisposition = NSPrintInfo.JobDisposition.save
        info.dictionary()[NSPrintInfo.AttributeKey("NSPrintJobSavingURL")] = url as NSURL
        return info
    }

    // MARK: the menu binding (⌘P, ADR-0013)

    @Test func fileMenuBindsPrintAndPageSetup() throws {
        // The test host may launch without the menu installed; drive
        // the app delegate the way launch does.
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("test")))
        let fileMenu = try #require(
            NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu)
        let print = try #require(fileMenu.items.first { $0.title == "Print…" })
        #expect(print.action == #selector(NSDocument.printDocument(_:)))
        #expect(print.keyEquivalent == "p")
        #expect(print.keyEquivalentModifierMask == [.command])
        let pageSetup = try #require(fileMenu.items.first { $0.title == "Page Setup…" })
        #expect(pageSetup.action == #selector(NSDocument.runPageLayout(_:)))
        // ⇧⌘P is the Command Palette's (ADR-0013) — Page Setup carries
        // no shortcut.
        #expect(pageSetup.keyEquivalent.isEmpty)
    }

    // MARK: the accessory panel's options

    @Test func accessoryPanelReflectsItsControls() {
        let accessory = PrintAccessoryController()
        accessory.loadView()
        // Defaults: fit to page, all furniture on.
        var options = accessory.printOptions
        #expect(options.mode == .fit)
        #expect(options.showHeaderTitle)
        #expect(options.showHeaderDate)
        #expect(options.showPageNumbers)
        #expect(options.includeBackground)

        // Switch to tiling: the overlap stepper becomes live and the
        // options read back the tile mode and overlap.
        accessory.selectTileModeForTesting()
        accessory.setTileOverlapForTesting(20)
        options = accessory.printOptions
        #expect(options.mode == .tile)
        #expect(options.tileOverlap == 20)
    }

    // MARK: the composed job

    @Test func operationBuildsWithTheExpectedPageCount() throws {
        let paper = CGSize(width: 612, height: 792)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = paper

        // Fit: one page. (The operation's page range is 1-based; its
        // length is the job's page count.)
        let fit = try PrintCoordinator.makePrintOperation(
            model: canonicalModel(), options: PrintOptions(mode: .fit), printInfo: info,
            title: "Print Fixture")
        #expect(fit.pageRange.length == 1)

        // Tile: the pure grid math's page count, realized as a PDF.
        let tileOptions = PrintOptions(mode: .tile)
        let expectedTiles = PrintCoordinator.pageCount(
            model: wideModel(), options: tileOptions, printInfo: info, title: "Print Fixture")
        #expect(expectedTiles > 1)
        let tile = try PrintCoordinator.makePrintOperation(
            model: wideModel(), options: tileOptions, printInfo: info, title: "Print Fixture")
        #expect(tile.pageRange.length == expectedTiles)

        // Outline: the paginated outline's page count.
        let outlineOptions = PrintOptions(mode: .outline)
        let expectedOutline = PrintCoordinator.pageCount(
            model: wideModel(), options: outlineOptions, printInfo: info, title: "Print Fixture")
        #expect(expectedOutline >= 1)
        let outline = try PrintCoordinator.makePrintOperation(
            model: wideModel(), options: outlineOptions, printInfo: info, title: "Print Fixture")
        #expect(outline.pageRange.length == expectedOutline)
    }

    // MARK: the real operation, run to a file

    @Test func printOperationSpoolsToPDFFileWithExpectedPages() throws {
        let paper = CGSize(width: 612, height: 792)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Fit: the spooled file is a one-page PDF.
        let fitURL = directory.appendingPathComponent("fit.pdf")
        let fitInfo = filePrintInfo(to: fitURL, paper: paper)
        let fitOperation = try PrintCoordinator.makePrintOperation(
            model: canonicalModel(), options: PrintOptions(mode: .fit), printInfo: fitInfo,
            title: "Print Fixture", showsProgressPanel: false)
        fitOperation.run()
        let fitData = try #require(try? Data(contentsOf: fitURL))
        let fitDocument = try #require(PDFDocument(data: fitData))
        #expect(fitDocument.pageCount == 1)

        // Tile: the spooled file carries the grid's page count.
        let tileOptions = PrintOptions(mode: .tile)
        let expectedTiles = PrintCoordinator.pageCount(
            model: wideModel(), options: tileOptions, printInfo: fitInfo, title: "Print Fixture")
        let tileURL = directory.appendingPathComponent("tile.pdf")
        let tileInfo = filePrintInfo(to: tileURL, paper: paper)
        let tileOperation = try PrintCoordinator.makePrintOperation(
            model: wideModel(), options: tileOptions, printInfo: tileInfo, title: "Print Fixture",
            showsProgressPanel: false)
        tileOperation.run()
        let tileData = try #require(try? Data(contentsOf: tileURL))
        let tileDocument = try #require(PDFDocument(data: tileData))
        #expect(tileDocument.pageCount == expectedTiles)
    }
}
