import AppKit
import CanvasKit
import CoreGraphics
import Foundation
import ImageIO
import MapCore
import MapIO
import MapRender
import SceneExport
import Testing
import UniformTypeIdentifiers

@testable import Arbor
@testable import CanvasKit

/// Hosted app tests for the M3 media slice (F-CNT-2/3/5/7/8, F-TAG-3):
/// smart typing through the real commit path, images through the real
/// package, markers and their cycling, the source anchor, math
/// rendering with the source fallback, the filter bar (dim + hide +
/// saved filters) and media-carrying exports through the shared
/// renderer.
@MainActor
struct MediaFeatureTests {
    private static func makeUntitledDocument() throws -> MapDocument {
        try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
    }

    private static func makeShownDocument() throws -> (MapDocument, DocumentWindowController, CanvasView) {
        let document = try makeUntitledDocument()
        var model = document.model
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for id in ["root", "a", "b"] {
            model.nodes[id] = Node(id: id, title: NodeTitle(text: id), created: date, modified: date)
        }
        model.roots = ["root"]
        model.nodes["root"]?.children = ["a", "b"]
        model.nodes["a"]?.parent = "root"
        model.nodes["b"]?.parent = "root"
        document.store.replaceModel(model)
        document.undoManager?.removeAllActions()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        controller.canvas.commitEditing()
        return (document, controller, controller.canvas)
    }

    private static func solidPNG(width: Int = 12, height: Int = 8, red: CGFloat = 1) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return out as Data
    }

    // MARK: smart typing through the real commit path (F-EDT-10)

    @Test func taskTagAndNoteSplitCommitAsOneUndoStep() throws {
        let (document, controller, canvas) = try Self.makeShownDocument()
        canvas.setSelection(["a"])
        _ = document.model

        // The real path: the editing-commit handler through the store.
        controller.handleEditingCommit(
            id: "a", title: NodeTitle(text: "[x] Ship #ops\n--\nran the deploy"), next: .none)
        let after = document.model
        #expect(after.nodes["a"]?.title.text == "Ship")
        #expect(after.nodes["a"]?.task?.done == true)
        #expect(after.nodes["a"]?.note == "ran the deploy")
        #expect(after.nodes["a"]?.tags?.count == 1)
        #expect(after.tags?.count == 1)

        // One undo step restores the pristine node AND the document
        // tag list (field-wise: the undo run re-stamps `modified`).
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.title.text == "a")
        #expect(document.model.nodes["a"]?.task == nil)
        #expect(document.model.nodes["a"]?.note == nil)
        #expect(document.model.nodes["a"]?.tags == nil)
        #expect(document.model.tags == nil)
    }

    @Test func mathCommitSetsTheMathFlag() throws {
        let (_, controller, canvas) = try Self.makeShownDocument()
        canvas.setSelection(["b"])
        controller.handleEditingCommit(id: "b", title: NodeTitle(text: "$$E = mc^2$$"), next: .none)
        #expect(controller.contentStore?.model.nodes["b"]?.math == true)
        #expect(controller.contentStore?.model.nodes["b"]?.title.text == "E = mc^2")
    }

    @Test func codeCommitMarksTheTitleRuns() throws {
        let (_, controller, canvas) = try Self.makeShownDocument()
        canvas.setSelection(["b"])
        controller.handleEditingCommit(id: "b", title: NodeTitle(text: "```func f() {}```"), next: .none)
        let node = try #require(controller.contentStore?.model.nodes["b"])
        #expect(node.title.text == "func f() {}")
        #expect(node.title.runs.first?.code == true)
    }

    // MARK: images (F-CNT-2)

    @Test func insertedImageLandsInThePackageAndRoundTrips() async throws {
        let (document, controller, canvas) = try Self.makeShownDocument()
        canvas.setSelection(["a"])
        let png = try Self.solidPNG()

        controller.mediaCoordinator.insertImageData(png, pixels: CGSize(width: 12, height: 8))
        let after = controller.contentStore?.model
        #expect(after?.nodes["a"]?.image?.asset.isEmpty == false)
        #expect(after?.nodes["a"]?.image?.size == [Double(12), Double(8)])
        let asset = try #require(after?.nodes["a"]?.image?.asset)

        // The bytes live in the package wrapper now (assets/ entry).
        #expect(document.assetData(asset) == png)

        // Undo removes the image (field-wise: the undo run re-stamps
        // `modified`; the bytes may stay — assets are content-addressed
        // and idempotent).
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.image == nil)
        #expect(document.model.tags == nil)

        // Save + reopen round-trips the image reference and bytes.
        document.undoManager?.redo()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-media-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try await document.save(
            to: url, ofType: AppIdentity.documentUTI, for: .saveAsOperation)
        let reopened = try MapDocument(contentsOf: url, ofType: AppIdentity.documentUTI)
        let node = try #require(reopened.model.nodes["a"])
        #expect(node.image?.asset == asset)
        #expect(node.image?.size == [12, 8])
        #expect(reopened.assetData(asset) == png)
    }

    @Test func imagePasteSetsTheSelectionImage() throws {
        let (document, controller, canvas) = try Self.makeShownDocument()
        canvas.setSelection(["a"])
        let pngType = NSPasteboard.PasteboardType("public.png")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(try Self.solidPNG(), forType: pngType)

        let handled = controller.mediaCoordinator.pasteImageIfPresent(pasteboard)
        #expect(handled)
        #expect(controller.contentStore?.model.nodes["a"]?.image != nil)

        // An Arbor node copy on the pasteboard is never hijacked.
        let payload = try PasteboardSerializer.payload(
            from: document.model, selection: ["a"])
        pasteboard.clearContents()
        pasteboard.setData(payload, forType: DocumentWindowController.payloadType)
        pasteboard.setData(try Self.solidPNG(), forType: pngType)
        #expect(!controller.mediaCoordinator.pasteImageIfPresent(pasteboard))
    }

    @Test func imageResizeCommitsOneCommand() throws {
        let (document, controller, canvas) = try Self.makeShownDocument()
        var model = document.model
        model.nodes["a"]?.image = NodeImage(asset: "aa.png", size: [80, 40], placement: .above)
        document.store.replaceModel(model)
        canvas.setSelection(["a"])
        _ = document.model

        controller.mediaCoordinator.resizeImage(id: "a", to: CGSize(width: 120, height: 60))
        #expect(controller.contentStore?.model.nodes["a"]?.image?.size == [120, 60])
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.image?.size == [80, 40])
    }

    // MARK: markers (F-CNT-3)

    @Test func markerToggleCyclesAndUndoes() throws {
        let (document, controller, canvas) = try Self.makeShownDocument()
        canvas.setSelection(["a", "b"])

        controller.mediaCoordinator.toggleMarker("sticker:priority-1")
        var model = try #require(controller.contentStore?.model)
        #expect(model.nodes["a"]?.markers == ["sticker:priority-1"])
        #expect(model.nodes["b"]?.markers == ["sticker:priority-1"])

        // A family member replaces its sibling, not stacks.
        controller.mediaCoordinator.toggleMarker("sticker:priority-3")
        model = try #require(controller.contentStore?.model)
        #expect(model.nodes["a"]?.markers == ["sticker:priority-3"])

        // A canvas click on the priority marker cycles it one step.
        controller.mediaCoordinator.cycleMarker(id: "a")
        model = try #require(controller.contentStore?.model)
        #expect(model.nodes["a"]?.markers == ["sticker:priority-4"])

        // The last click clears the family.
        controller.mediaCoordinator.cycleMarker(id: "a")
        controller.mediaCoordinator.cycleMarker(id: "a")
        model = try #require(controller.contentStore?.model)
        #expect(model.nodes["a"]?.markers == nil)
    }

    // MARK: source anchors (F-CNT-8)

    @Test func sourceCommandRoundTripsThroughTheSelection() throws {
        let (document, controller, canvas) = try Self.makeShownDocument()
        canvas.setSelection(["a"])
        _ = document.model
        let source = SourceRef(
            url: "https://example.com/video", time: 93.5, excerpt: "the key claim")
        controller.performKeepingSelection(.setSource(id: "a", source: source))
        #expect(controller.contentStore?.model.nodes["a"]?.source?.time == 93.5)
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.source == nil)
    }

    // MARK: math rendering (F-CNT-5, ADR-0027)

    @Test func mathCacheRendersValidLatexAndFailsClosed() throws {
        let glyph = MathImageCache.glyph(
            latex: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}",
            font: FontSpec(size: 13, weight: 0.1),
            tint: CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        #expect(glyph != nil)
        #expect(glyph!.size.width > 20)

        // A parse error renders nothing — the source text shows.
        let invalid = MathImageCache.glyph(
            latex: "\\unknowncmd{x}",
            font: FontSpec(size: 13, weight: 0.1),
            tint: CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        #expect(invalid == nil)

        // The note preview's math image path also works.
        #expect(
            MathImageCache.image(latex: "E = mc^2", fontSize: 14, color: .labelColor) != nil)

        // The note block parser lifts $$ spans out.
        let blocks = NoteMathParser.segments(of: "before\n$$x^2$$\nafter")
        #expect(blocks == [.text("before\n"), .math("x^2"), .text("\nafter")])
    }

    // MARK: the media caches (F-CNT-2/3)

    @Test func thumbnailDecodesOffTheMainThread() async throws {
        let store = MediaAssetStore()
        let png = try Self.solidPNG()
        let decoded = DecodeExpectation()
        store.onDecoded = { decoded.fulfill() }

        let first = store.thumbnail(named: "aa.png", fetch: { png })
        #expect(first == nil, "the first ask returns the placeholder state")
        try await decoded.wait(timeout: 5)

        let second = store.thumbnail(named: "aa.png", fetch: { png })
        #expect(second != nil)
        #expect(store.revision == 1)
    }

    @Test func sfSymbolGlyphRastersTinted() throws {
        let glyph = SFSymbolGlyphCache.image(
            token: "sf:star", tint: CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        #expect(glyph != nil)
        // A second ask with the same tint reuses the cache.
        let again = SFSymbolGlyphCache.image(
            token: "sf:star", tint: CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        #expect(again === glyph)
        // An unknown symbol renders nothing (its slot stays empty).
        #expect(SFSymbolGlyphCache.image(token: "sf:totally-not-a-symbol", tint: CGColor(gray: 0.2, alpha: 1)) == nil)
    }

    // MARK: the filter bar (F-TAG-3)

    @Test func filterBarDimAndHideModes() throws {
        let (document, controller, canvas) = try Self.makeShownDocument()
        // Only "a" has a note.
        var model = document.model
        model.nodes["a"]?.note = "needle"
        document.store.replaceModel(model)
        controller.updateScene(preserveCamera: true)

        // DIM mode: every node stays in the scene; the highlight set
        // holds the matches.
        controller.mediaCoordinator.apply(filter: NodeFilter(text: "needle"), hide: false)
        #expect(canvas.highlight == .filter(NodeFilter(text: "needle")))
        let highlighted = canvas.highlightedIDs()
        #expect(highlighted == ["a"])

        // HIDE mode: the scene prunes non-matching nodes (ancestors
        // of matches stay).
        controller.mediaCoordinator.apply(filter: NodeFilter(text: "needle"), hide: true)
        #expect(canvas.highlight == nil)
        let scene = try #require(canvas.scene)
        #expect(scene.nodes["b"] == nil)
        #expect(scene.nodes["a"] != nil)
        #expect(scene.nodes["root"] != nil)

        // Off: everything returns.
        controller.mediaCoordinator.apply(filter: NodeFilter(), hide: false)
        #expect(try #require(canvas.scene).nodes["b"] != nil)
    }

    @Test func savedFiltersAreOneUndoableDocumentCommand() throws {
        let (document, controller, _) = try Self.makeShownDocument()
        let before = document.model
        controller.performKeepingSelection(
            .setFilters([SavedFilter(id: "f1", name: "Open", query: "is:open")]))
        #expect(controller.contentStore?.model.filters?.first?.name == "Open")
        document.undoManager?.undo()
        #expect(document.model == before)

        // The bar surfaces them (the popups' content).
        controller.mediaCoordinator.toggleFilterBar()
        controller.mediaCoordinator.refreshFilterBar()
        controller.performKeepingSelection(
            .setFilters([SavedFilter(id: "f1", name: "Open", query: "is:open")]))
        controller.mediaCoordinator.refreshFilterBar()
        controller.mediaCoordinator.toggleFilterBar()
    }

    // MARK: media in exports (the shared renderer, SPEC §11)

    @Test func mediaCarryingSceneExportsToPDFAndPNG() async throws {
        let png = try Self.solidPNG(width: 24, height: 16)
        let (document, controller, canvas) = try Self.makeShownDocument()
        // Store the bytes first: the content-addressed name is what the
        // node references.
        let storedAsset = document.addAsset(png, ext: "png")
        var model = document.model
        model.nodes["a"]?.image = NodeImage(asset: storedAsset, size: [60, 20], placement: .above)
        model.nodes["a"]?.markers = ["sticker:priority-2", "emoji:💡"]
        model.nodes["b"]?.math = true
        model.nodes["b"]?.title = NodeTitle(text: "x^2")
        model.nodes["b"]?.source = SourceRef(url: "https://example.com")
        model.nodes["b"]?.attachments = [Attachment(asset: "bb.pdf", name: "Y.pdf")]
        document.store.replaceModel(model)
        controller.updateScene(preserveCamera: true)

        // The image thumbnail decodes off the main thread; the decode's
        // completion rebuilds the scene with the media attached.
        let scene: CanvasScene = try await {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let scene = canvas.scene,
                    scene.nodes["a"]?.media?.image != nil,
                    scene.nodes["b"]?.media?.math != nil
                {
                    return scene
                }
                try await Task.sleep(for: .milliseconds(20))
                controller.updateScene(preserveCamera: true)
            }
            Issue.record("the media never resolved onto the scene")
            return try #require(canvas.scene)
        }()

        let imageNode = try #require(scene.nodes["a"])
        #expect(imageNode.media?.image != nil, "the async decode must have landed")
        let mathNode = try #require(scene.nodes["b"])
        #expect(mathNode.media?.math != nil, "the math glyph must have resolved")

        // PDF + PNG through the SceneExport painters (the shared
        // NodeRenderer path).
        let pdfOptions = PDFExportOptions(content: .map(.wholeMap), margin: 20)
        let pdf = try PDFExporter.export(
            scene: scene, model: document.model, options: pdfOptions,
            measurer: SceneRenderer.sharedMeasurer)
        #expect(pdf.count > 1_000)
        #expect(String(decoding: pdf.prefix(8), as: UTF8.self).hasPrefix("%PDF"))

        var pngOptions = ImageExportOptions()
        pngOptions.margin = 20
        let exported = try ImageExporter.export(
            scene: scene, model: document.model, options: pngOptions,
            measurer: SceneRenderer.sharedMeasurer)
        #expect(exported.data.count > 500)
    }
}

/// A tiny async expectation for the off-main decode completion. Both
/// ends run on the main actor (the decode's completion hops there), so
/// a plain flag is race-free.
@MainActor
private final class DecodeExpectation {
    private var fulfilled = false

    func fulfill() {
        fulfilled = true
    }

    func wait(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fulfilled {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the async decode never completed")
    }
}
