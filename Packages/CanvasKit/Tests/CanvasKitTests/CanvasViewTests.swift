import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import CanvasKit

@MainActor
struct CanvasViewTests {
    @Test func buildsSceneAndHitTests() throws {
        let model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.scene = scene

        let rootFrame = try #require(scene.nodes["root"]?.frame)
        let modelCenter = CGPoint(x: rootFrame.midX, y: rootFrame.midY)
        let screenCenter = view.camera.screenPoint(for: modelCenter)
        #expect(view.nodeID(at: screenCenter) == "root")
        let farAway = view.camera.screenPoint(for: CGPoint(x: -2000, y: -2000))
        #expect(view.nodeID(at: farAway) == nil)
    }

    @Test func cameraModelPointRoundTripsThroughTheView() {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.camera = Camera(origin: CGPoint(x: 100, y: 50), scale: 2)
        let screen = CGPoint(x: 40, y: 20)
        let model = view.camera.modelPoint(for: screen)
        let back = view.camera.screenPoint(for: model)
        #expect(abs(back.x - screen.x) < 0.001)
        #expect(abs(back.y - screen.y) < 0.001)
    }

    @Test func zoomToFitCoversTheScene() throws {
        let model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.scene = scene
        view.zoomToFit()

        let visible = view.camera.visibleRect(viewportSize: view.bounds.size)
        let content = scene.bounds.insetBy(dx: -40, dy: -40)
        #expect(visible.contains(CGPoint(x: content.minX + 5, y: content.minY + 5)))
        #expect(visible.contains(CGPoint(x: content.maxX - 5, y: content.maxY - 5)))
    }

    @Test func zoomAroundAnchorKeepsTheAnchorModelPointPut() {
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.camera = Camera(origin: CGPoint(x: 0, y: 0), scale: 1)
        let anchor = CGPoint(x: 400, y: 300)
        let before = view.camera.modelPoint(for: anchor)
        view.zoom(scale: 2.5, around: anchor)
        let after = view.camera.modelPoint(for: anchor)
        #expect(abs(before.x - after.x) < 0.001)
        #expect(abs(before.y - after.y) < 0.001)
    }
}
