import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// Hosts the canvas in an offscreen window and inspects the rendered
/// pixels — the test class the PR #5 review asked for after the
/// layer-hosting bug shipped invisible canvases.
@MainActor
struct CanvasRenderingTests {
    @Test func hostedCanvasRendersTheRootFill() throws {
        let model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.scene = scene
        view.zoomToFit()
        view.displayIfNeeded()

        let rootFill = try #require(scene.nodes["root"]?.style.fillColor)
        let rootHex = try #require(PaperTheme.hex(of: rootFill))
        let rootFrame = try #require(scene.nodes["root"]?.frame)
        // Sample the middle of the frame's left padding band: pure fill —
        // the center holds white title text and the very edge blends with
        // the raised shadow.
        let samplePoint = view.camera.screenPoint(
            for: CGPoint(x: rootFrame.minX + 8, y: rootFrame.midY))

        guard
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            Issue.record("no bitmap for cacheDisplay")
            return
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard
            let sample = image.colorAt(
                x: Int(samplePoint.x), y: Int(view.bounds.height - samplePoint.y))?.usingColorSpace(
                    .deviceRGB)
        else {
            Issue.record("no pixel at the root center")
            return
        }
        let expected = PaperTheme.color(fromHex: rootHex)
        let expectedComponents = try #require(expected.components)
        let sampleComponents = try #require(sample.cgColor.components)
        for channel in 0..<3 {
            #expect(
                abs(sampleComponents[channel] - expectedComponents[channel]) < 0.02,
                "channel \(channel): sample \(sampleComponents[channel]) expected \(expectedComponents[channel])")
        }
    }

    @Test func hostedCanvasHasInkBeyondTheBackground() throws {
        let model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.scene = scene
        view.zoomToFit()
        view.displayIfNeeded()

        guard
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            Issue.record("no bitmap for cacheDisplay")
            return
        }
        view.cacheDisplay(in: view.bounds, to: image)
        let canvasHex = try #require(PaperTheme.hex(of: PaperTheme.canvasLight))
        let canvasRed = Double((canvasHex >> 16) & 0xFF)
        let canvasGreen = Double((canvasHex >> 8) & 0xFF)
        let canvasBlue = Double(canvasHex & 0xFF)

        var inkPixels = 0
        for x in 0..<600 where inkPixels < 40 {
            for y in 0..<400 where inkPixels < 40 {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                guard let components = color.cgColor.components, components.count >= 3 else { continue }
                let matchesCanvas =
                    abs(Double(components[0] * 255) - canvasRed) < 2
                    && abs(Double(components[1] * 255) - canvasGreen) < 2
                    && abs(Double(components[2] * 255) - canvasBlue) < 2
                if !matchesCanvas {
                    inkPixels += 1
                }
            }
        }
        #expect(inkPixels >= 40, "expected rendered node/branch ink, found \(inkPixels)")
    }
}

/// Multi-root stacking with a wide root — balanced subtrees extend above
/// the root, so stacking by the root's own `minY` used to overlap trees.
struct MultiRootStackingTests {
    @Test func wideRootsStackWithoutOverlap() throws {
        var model = MapModel.emptyDocument(docID: "stacking")
        let date = sceneDate
        for (rootIndex, rootID) in ["wide-root", "second-root"].enumerated() {
            model.nodes[rootID] = Node(
                id: rootID, title: NodeTitle(text: "Root \(rootIndex) is deliberately wide"),
                created: date, modified: date)
            let childCount = rootIndex == 0 ? 1 : 12
            for child in 0..<childCount {
                let childID = "\(rootID)-child-\(child)"
                model.nodes[childID] = Node(
                    id: childID, parent: rootID,
                    title: NodeTitle(text: "child \(child) with a long title"),
                    created: date, modified: date)
                model.nodes[rootID]?.children.append(childID)
            }
        }
        model.roots = ["wide-root", "second-root"]

        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let list = Array(scene.nodes.values)
        for i in list.indices {
            for j in list.indices where j > i {
                let separated =
                    list[i].frame.maxX <= list[j].frame.minX
                    || list[j].frame.maxX <= list[i].frame.minX
                    || list[i].frame.maxY <= list[j].frame.minY
                    || list[j].frame.maxY <= list[i].frame.minY
                #expect(separated, "\(list[i].id) overlaps \(list[j].id)")
            }
        }
        let first = try #require(scene.nodes["wide-root"]?.frame)
        let second = try #require(scene.nodes["second-root"]?.frame)
        #expect(second.minY > first.minY)
    }
}
