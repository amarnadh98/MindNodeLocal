import CoreGraphics
import Foundation
import MapCore
import MapRender
import QuartzCore
import Testing

@testable import CanvasKit

/// `CATransform3D` has no `==` in Swift; compare field by field.
private func transformsEqual(_ lhs: CATransform3D, _ rhs: CATransform3D) -> Bool {
    lhs.m11 == rhs.m11 && lhs.m12 == rhs.m12 && lhs.m13 == rhs.m13 && lhs.m14 == rhs.m14
        && lhs.m21 == rhs.m21 && lhs.m22 == rhs.m22 && lhs.m23 == rhs.m23 && lhs.m24 == rhs.m24
        && lhs.m31 == rhs.m31 && lhs.m32 == rhs.m32 && lhs.m33 == rhs.m33 && lhs.m34 == rhs.m34
        && lhs.m41 == rhs.m41 && lhs.m42 == rhs.m42 && lhs.m43 == rhs.m43 && lhs.m44 == rhs.m44
}

/// The F-STD-6 mastery overlay: tint/outline/ring layers realize over
/// the existing scene, the camera re-transforms them, and — the budget
/// rule — node rasters are never touched.
@MainActor
struct MasteryOverlayTests {
    private let red = CGColor(srgbRed: 0.9, green: 0.28, blue: 0.22, alpha: 0.25)
    private let gray = CGColor(gray: 0.5, alpha: 1)
    private let green = CGColor(srgbRed: 0.27, green: 0.65, blue: 0.35, alpha: 1)

    private func scene(ids: [String]) -> CanvasScene {
        let style = PaperTheme.resolvedStyle(level: 1, level1Index: 0, variant: .light)
        var nodes: [String: SceneNode] = [:]
        for (index, id) in ids.enumerated() {
            nodes[id] = SceneNode(
                id: id, frame: CGRect(x: 0, y: CGFloat(index * 100), width: 120, height: 40),
                style: style, title: NodeTitle(text: id), level: 1, level1Index: 0)
        }
        return CanvasScene(
            nodes: nodes, branches: [], canvasColor: CGColor(gray: 0.97, alpha: 1))
    }

    @Test func marksRealizeAsLayersOverTheContentTree() {
        let overlay = MasteryOverlay()
        let content = CALayer()
        overlay.attach(to: content)
        let ids = ["card", "fresh", "parent"]
        let scene = scene(ids: ids)
        let camera = Camera()
        overlay.update(
            [
                "card": .tint(red),
                "fresh": .outline(gray),
                "parent": .ring(color: green, progress: 0.7),
            ],
            scene: scene, camera: camera)

        #expect(overlay.visibleNodeIDs == ["card", "fresh"])
        #expect(overlay.visibleRingIDs == ["parent"])
        #expect(content.sublayers?.count == 3)

        // The tint fills, the outline strokes, the ring arcs.
        let tint = content.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.fillColor == red }
        #expect(tint != nil)
        let outline = content.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.fillColor == nil }
        #expect(outline?.strokeColor == gray)
        let ring = content.sublayers?.compactMap { $0 as? CAShapeLayer }
            .first {
                $0.path
                    == MasteryOverlay.ringPath(
                        geometry: MasteryOverlay.ringGeometry(for: scene.nodes["parent"]!.frame), progress: 0.7)
            }
        #expect(ring?.strokeColor == green)
    }

    @Test func marksLeaveTheSceneLayersUntouched() throws {
        // The overlay must not force a re-raster: the budget rule is
        // "no re-raster of untouched nodes".
        let tree = CanvasLayerTree()
        let ids = ["a", "b"]
        let scene = scene(ids: ids)
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        var context = ApplyContext(
            scene: scene, grid: grid, camera: Camera(), viewport: CGSize(width: 800, height: 600))
        context.animated = false
        tree.apply(context)
        let keyBefore = tree.nodeRasterKey("a")

        tree.masteryMarks = ["a": .tint(red)]
        tree.apply(context)

        #expect(tree.mastery.visibleNodeIDs == ["a"])
        #expect(tree.nodeRasterKey("a") == keyBefore)
    }

    @Test func updatesReuseLayersAndDropStaleIDs() {
        let overlay = MasteryOverlay()
        let content = CALayer()
        overlay.attach(to: content)
        let scene = scene(ids: ["a", "b"])
        let camera = Camera()
        overlay.update(["a": .tint(red), "b": .tint(red)], scene: scene, camera: camera)
        let before = content.sublayers?.count

        // Same marks again: no new layers.
        overlay.update(["a": .tint(red), "b": .tint(red)], scene: scene, camera: camera)
        #expect(content.sublayers?.count == before)

        // A mark leaving the table drops its layer.
        overlay.update(["a": .tint(red)], scene: scene, camera: camera)
        #expect(overlay.visibleNodeIDs == ["a"])
        #expect(content.sublayers?.count == 1)

        // A node leaving the scene drops its layer too.
        overlay.update(["a": .tint(red), "gone": .tint(red)], scene: scene, camera: camera)
        #expect(overlay.visibleNodeIDs == ["a"])
    }

    @Test func nilTableAndClearTakeTheOverlayDown() {
        let overlay = MasteryOverlay()
        let content = CALayer()
        overlay.attach(to: content)
        let scene = scene(ids: ["a"])
        overlay.update(["a": .tint(red)], scene: scene, camera: Camera())
        #expect(!overlay.visibleNodeIDs.isEmpty)

        overlay.update(nil, scene: scene, camera: Camera())
        #expect(overlay.visibleNodeIDs.isEmpty)
        #expect((content.sublayers ?? []).isEmpty)

        overlay.update(["a": .ring(color: green, progress: 1)], scene: scene, camera: Camera())
        overlay.clear()
        #expect(overlay.visibleRingIDs.isEmpty)
        #expect((content.sublayers ?? []).isEmpty)
    }

    @Test func cameraMovesRetransformWithoutRebuildingPaths() {
        let overlay = MasteryOverlay()
        let content = CALayer()
        overlay.attach(to: content)
        let scene = scene(ids: ["a"])
        overlay.update(["a": .tint(red)], scene: scene, camera: Camera())
        guard let layer = content.sublayers?.first as? CAShapeLayer else {
            Issue.record("no overlay layer")
            return
        }
        let path = layer.path
        let frame = layer.frame

        let zoomed = Camera(origin: CGPoint(x: -40, y: -20), scale: 2)
        overlay.updateCamera(camera: zoomed)

        // The geometry never moves: only the model-space transform does.
        #expect(layer.path == path)
        #expect(transformsEqual(layer.transform, CanvasLayerTree.modelSpaceTransform(for: zoomed)))
        #expect(layer.frame.size == frame.size)
    }

    @Test func ringGeometryAnchorsAtTheTopRightCorner() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
        let geometry = MasteryOverlay.ringGeometry(for: frame)
        #expect(geometry.center == CGPoint(x: 110, y: 20))
        #expect(geometry.radius > 0)

        // Progress clamps to [0, 1]; 0 renders nothing.
        #expect(MasteryOverlay.ringPath(geometry: geometry, progress: 0) == nil)
        #expect(MasteryOverlay.ringPath(geometry: geometry, progress: -0.5) == nil)
        #expect(MasteryOverlay.ringPath(geometry: geometry, progress: 1.4) != nil)
    }
}
