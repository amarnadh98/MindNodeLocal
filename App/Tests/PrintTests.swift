import AppKit
import Foundation
import MapCore
import PDFKit
import SystemIntegration
import Testing

@testable import Arbor

/// F-INT-9 (M4's print slice): the print menu binding, the accessory
/// panel's options, the composed job's page count (fit / tile /
/// outline), and the spool contract — the REAL `NSPrintOperation`
/// with its save disposition/saving URL plus the composed bytes it
/// prints, written and read back as a file. (The daemon delivery
/// itself — `operation.run()` — hangs on machines without a live
/// print backend and is deliberately not exercised; see
/// `spoolFileContractHoldsForFitAndTile`.)
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
        let info = NSPrintInfo.shared.copied()
        info.paperSize = paper
        info.jobDisposition = NSPrintInfo.JobDisposition.save
        info.dictionary()[NSPrintInfo.AttributeKey("NSPrintJobSavingURL")] = url as NSURL
        return info
    }

    // MARK: the menu binding (⌘P, ADR-0013)

    @Test func fileMenuBindsPrintAndPageSetup() throws {
        // The test host may launch without the menu installed; install
        // it the way `applicationDidFinishLaunching` would (the repo's
        // FocusZenQuickOpenTests pattern — driving the full launch would
        // re-start the library coordinator and the Quick Entry hotkey).
        if NSApp.mainMenu?.items.count ?? 0 < 2 {
            NSApp.mainMenu = AppDelegate().buildMenu()
        }
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
        let info = NSPrintInfo.shared.copied()
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

    // MARK: the spool contract (everything the print daemon handshake
    // needs, without running it)

    /// The composed job, run toward a file: `operation.run()` itself
    /// was harness-verified to block INDEFINITELY on machines whose
    /// print backend is unreachable (a plain PDFKit
    /// `document.printOperation` with a save disposition hangs the
    /// same way — `printToolAgent` never answers; also true inside the
    /// sandboxed test host). A hosted test that called `run()` would
    /// hang the suite — and possibly CI runners — on such machines, so
    /// this asserts everything the spool needs instead: the REAL
    /// operation exists with the save disposition and saving URL, its
    /// page range is the job's, and the composed bytes it prints at
    /// `.pageScaleNone` (1:1 — the pages already ARE the paper) write
    /// and read back as a PDF file with exactly those pages at the
    /// paper size. The one untested step is Apple's daemon delivery.
    @Test func spoolFileContractHoldsForFitAndTile() throws {
        let paper = CGSize(width: 612, height: 792)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Fit: one page at the paper size, with the operation carrying
        // the save disposition and the saving URL.
        let fitURL = directory.appendingPathComponent("fit.pdf")
        let fitInfo = filePrintInfo(to: fitURL, paper: paper)
        let fitOperation = try PrintCoordinator.makePrintOperation(
            model: canonicalModel(), options: PrintOptions(mode: .fit), printInfo: fitInfo,
            title: "Print Fixture", showsProgressPanel: false)
        #expect(fitOperation.pageRange.length == 1)
        #expect(fitOperation.printInfo.jobDisposition == NSPrintInfo.JobDisposition.save)
        #expect(
            fitOperation.printInfo.dictionary()[NSPrintInfo.AttributeKey("NSPrintJobSavingURL")]
                as? URL == fitURL)
        #expect(!fitOperation.showsPrintPanel)

        // The bytes the operation spools at .pageScaleNone are the
        // composed job itself: write them the way the spool would and
        // read the file back.
        let fitData = try PrintCoordinator.compose(
            model: canonicalModel(), options: PrintOptions(mode: .fit), printInfo: fitInfo,
            title: "Print Fixture")
        try fitData.write(to: fitURL)
        let fitDocument = try #require(PDFDocument(url: fitURL))
        #expect(fitDocument.pageCount == 1)
        #expect(fitDocument.page(at: 0)?.bounds(for: .mediaBox).size == paper)

        // Tile: the spool file carries the predicted grid's page count,
        // every page at the paper size.
        let tileOptions = PrintOptions(mode: .tile)
        let expectedTiles = PrintCoordinator.pageCount(
            model: wideModel(), options: tileOptions, printInfo: fitInfo, title: "Print Fixture")
        #expect(expectedTiles > 1)
        let tileURL = directory.appendingPathComponent("tile.pdf")
        let tileInfo = filePrintInfo(to: tileURL, paper: paper)
        let tileOperation = try PrintCoordinator.makePrintOperation(
            model: wideModel(), options: tileOptions, printInfo: tileInfo, title: "Print Fixture",
            showsProgressPanel: false)
        #expect(tileOperation.pageRange.length == expectedTiles)
        let tileData = try PrintCoordinator.compose(
            model: wideModel(), options: tileOptions, printInfo: tileInfo, title: "Print Fixture")
        try tileData.write(to: tileURL)
        let tileDocument = try #require(PDFDocument(url: tileURL))
        #expect(tileDocument.pageCount == expectedTiles)
        for pageIndex in 0..<tileDocument.pageCount {
            #expect(tileDocument.page(at: pageIndex)?.bounds(for: .mediaBox).size == paper)
        }
    }
}
