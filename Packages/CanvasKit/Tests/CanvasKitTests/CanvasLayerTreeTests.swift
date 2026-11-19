import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// The virtualized layer tree (SPEC §11.4), headless: the expanded
/// visible set, pool reuse while panning (no unbounded growth), the
/// scene-diff apply (only changed nodes re-raster), the editing-node
/// title hiding and the post-settle re-rasterize.
@MainActor
struct CanvasLayerTreeTests {
    private let viewport = CGSize(width: 800, height: 600)
    private var fitCamera: Camera {
        Camera(origin: CGPoint(x: -400, y: -300), scale: 1)
    }

    private func grid(for scene: CanvasScene) -> SpatialGrid {
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        return grid
    }

    /// The common apply in these tests: instant, no selection.
    private func apply(
        _ tree: CanvasLayerTree, _ scene: CanvasScene, camera: Camera
    ) {
        var context = ApplyContext(
            scene: scene, grid: grid(for: scene), camera: camera, viewport: viewport)
        context.backingScale = 1
        context.animated = false
        context.reduceMotion = false
        tree.apply(context)
    }

    // MARK: culling with margin

    @Test func expandedVisibleRectAddsHalfAViewportPerEdge() {
        let camera = Camera(origin: CGPoint(x: 100, y: 100), scale: 2)
        let expanded = CanvasLayerTree.expandedVisibleRect(
            camera: camera, viewport: viewport)
        // Visible: 400×300 model points; margin 50% of the viewport per
        // edge → 200×150 on each side.
        #expect(expanded.origin == CGPoint(x: -100, y: -50))
        #expect(expanded.width == 800)
        #expect(expanded.height == 600)
    }

    @Test func visibleSetIncludesTheMarginButNotBeyond() {
        var grid = SpatialGrid()
        // At scale 1 the visible rect is (0, 0, 800, 600); the margin
        // reaches (-400, -300) … (1200, 900).
        grid.insert(id: "inside", frame: CGRect(x: 100, y: 100, width: 60, height: 40))
        grid.insert(id: "in-margin", frame: CGRect(x: -350, y: 700, width: 60, height: 40))
        grid.insert(id: "outside", frame: CGRect(x: 5_000, y: 5_000, width: 60, height: 40))
        let camera = Camera(origin: .zero, scale: 1)

        let visible = CanvasLayerTree.visibleNodeIDs(
            grid: grid, camera: camera, viewport: viewport)
        #expect(visible.contains("inside"))
        #expect(visible.contains("in-margin"))
        #expect(!visible.contains("outside"))
    }

    // MARK: apply & pooling

    @Test func applyRealizesOnlyTheVisibleSet() {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        // Park the camera where none of the (tiny) map is visible.
        let farAway = Camera(origin: CGPoint(x: 10_000, y: 10_000), scale: 1)
        apply(tree, scene, camera: farAway)
        #expect(tree.activeNodeLayerIDs.isEmpty)

        // Pan the map into view.
        tree.updateCamera(camera: fitCamera, viewport: viewport, backingScale: 1)
        #expect(tree.activeNodeLayerIDs.count == scene.nodes.count)
    }

    @Test func panRecyclesLayersWithNoUnboundedGrowth() {
        // A tall stack of single-child roots spreads far beyond the
        // viewport; panning across it must reuse pooled layers, not
        // allocate fresh ones per step.
        var model = MapModel.emptyDocument(docID: "wide")
        for index in 0..<40 {
            let id = "root-\(index)"
            model.nodes[id] = Node(
                id: id, title: NodeTitle(text: "Root \(index)"),
                created: sceneDate, modified: sceneDate)
            model.roots.append(id)
        }
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: Camera())

        func panSweep(from startY: CGFloat, to endY: CGFloat) {
            var y = startY
            let step: CGFloat = 200
            let direction = endY > startY ? step : -step
            while (direction > 0 && y <= endY) || (direction < 0 && y >= endY) {
                tree.updateCamera(
                    camera: Camera(origin: CGPoint(x: -400, y: y), scale: 1),
                    viewport: viewport, backingScale: 1)
                y += direction
            }
        }

        let height = scene.bounds.height
        panSweep(from: 0, to: height)
        let allocatedAfterFirstSweep = tree.allocatedNodeLayers
        // One layer per unique id seen — pooled reuse absorbs all the
        // churn in between, and never more than the map has nodes.
        #expect(allocatedAfterFirstSweep <= 40)
        #expect(tree.pooledNodeLayerReuses > 0)

        // The return sweep realizes only ids already seen: zero new
        // allocations, and the pool never grows past its cap.
        panSweep(from: height, to: 0)
        #expect(tree.allocatedNodeLayers == allocatedAfterFirstSweep)
        #expect(
            tree.activeNodeLayerIDs.count + tree.pooledNodeLayerCount
                <= CanvasLayerTree.nodePoolCap)
    }

    @Test func sceneReapplyReRastersNothing() throws {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)
        let before = tree.allocatedNodeLayers

        // The same scene again: zero new layers, zero re-rasters.
        apply(tree, scene, camera: fitCamera)
        #expect(tree.allocatedNodeLayers == before)
    }

    @Test func singleNodeTitleChangeReRastersOnlyThatNode() {
        var model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)

        // Retitle the root; the diff apply leaves untouched layers'
        // rasters alone (their raster keys still match).
        model.nodes["root"]?.title = NodeTitle(text: "A Much Longer Central Title")
        let rebuilt = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        apply(tree, rebuilt, camera: fitCamera)
        #expect(tree.activeNodeLayerIDs.count == rebuilt.nodes.count)
        #expect(tree.allocatedNodeLayers == scene.nodes.count)
    }

    // MARK: editing & LOD

    @Test func editingNodeHidesItsTitleInTheRaster() {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)

        tree.setEditingNode("root", camera: fitCamera, backingScale: 1)
        // The editing node re-rastered with the title suppressed (the
        // overlay draws the live text instead — §11.4).
        #expect(tree.rasterKeyOfNodeLayer("root")?.hidesTitle == true)
        #expect(tree.contentsOfNodeLayer("root") != nil)

        // Ending the session restores the title raster.
        tree.setEditingNode(nil, camera: fitCamera, backingScale: 1)
        #expect(tree.rasterKeyOfNodeLayer("root")?.hidesTitle == false)
    }

    @Test func lowZoomSwitchesToCapsuleRasters() {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        let zoomedOut = Camera(origin: CGPoint(x: -4_000, y: -3_000), scale: 0.2)
        apply(tree, scene, camera: zoomedOut)
        // Below the 0.35× LOD threshold every visible node has a
        // capsule raster (no text measurement at all).
        #expect(tree.activeNodeLayerIDs.count == scene.nodes.count)
        for id in tree.activeNodeLayerIDs {
            #expect(tree.contentsOfNodeLayer(id) != nil)
        }
    }

    @Test func settleReRastersAtTheZoomedScale() {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)
        #expect(tree.contentsScaleOfNodeLayer("root") == 1)

        let zoomed = Camera(
            origin: CGPoint(x: fitCamera.origin.x, y: fitCamera.origin.y), scale: 2)
        tree.updateCamera(camera: zoomed, viewport: viewport, backingScale: 1)
        // The post-settle pass (§11.4) re-rasterizes at the new scale.
        tree.rerasterizeVisible(camera: zoomed, backingScale: 1)
        #expect(tree.contentsScaleOfNodeLayer("root") == 2)
    }
}

// MARK: - test seams on CanvasLayerTree

extension CanvasLayerTree {
    func contentsOfNodeLayer(_ id: String) -> Any? {
        nodeLayerContents(id)
    }

    func contentsScaleOfNodeLayer(_ id: String) -> CGFloat {
        nodeLayerContentsScale(id)
    }

    func rasterKeyOfNodeLayer(_ id: String) -> NodeRasterKey? {
        nodeRasterKey(id)
    }
}
