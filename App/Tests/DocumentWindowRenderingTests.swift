import AppKit
import CanvasKit
import Foundation
import MapCore
import MapRender
import Testing

@testable import Arbor

/// The app wiring the PR #5 re-review asked for: open a real `.arbor`
/// package, show the document window, and assert the canvas actually has
/// a scene and rendered pixels (the `windowDidLoad` regression class).
@MainActor
struct DocumentWindowRenderingTests {
    @Test func openedDocumentShowsASceneWithDrawnPixels() throws {
        var model = MapModel.emptyDocument()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "Visible Root"), created: date, modified: date)
        model.roots = [rootID]
        for index in 0..<3 {
            let childID = "child-\(index)"
            model.nodes[childID] = Node(
                id: childID, parent: rootID, title: NodeTitle(text: "branch \(index)"),
                created: date, modified: date)
            model.nodes[rootID]?.children.append(childID)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wiring-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)

        let canvas = controller.canvas
        #expect(canvas.scene != nil, "windowDidLoad regression: scene never built")
        #expect(canvas.scene?.nodes[rootID] != nil)
        #expect(!canvas.needsInitialFit, "showWindow must run the initial fit")

        canvas.displayIfNeeded()
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let image else {
            Issue.record("no bitmap for cacheDisplay")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: image)

        let canvasHex = try #require(PaperTheme.hex(of: PaperTheme.canvasLight))
        let canvasRed = Double((canvasHex >> 16) & 0xFF)
        let canvasGreen = Double((canvasHex >> 8) & 0xFF)
        let canvasBlue = Double(canvasHex & 0xFF)
        var inkPixels = 0
        for x in 0..<900 {
            for y in 0..<600 {
                guard
                    let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    let components = color.cgColor.components, components.count >= 3
                else { continue }
                let matchesCanvas =
                    abs(Double(components[0] * 255) - canvasRed) < 2
                    && abs(Double(components[1] * 255) - canvasGreen) < 2
                    && abs(Double(components[2] * 255) - canvasBlue) < 2
                if !matchesCanvas {
                    inkPixels += 1
                }
            }
        }
        #expect(inkPixels > 500, "expected drawn map pixels, found \(inkPixels)")

        document.close()
    }
}
