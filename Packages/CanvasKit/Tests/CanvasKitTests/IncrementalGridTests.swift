import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// The incremental spatial-grid path (SPEC §11.4/§11.8): a scene that
/// follows another one updates only the cells of its changed nodes —
/// `SpatialGrid.update/remove` and the canvas view's diff-driven sync
/// must leave the grid answering exactly like a full rebuild.
@MainActor
struct IncrementalGridTests {
    private func smallModel(nodeCount: Int) -> MapModel {
        var model = MapModel.emptyDocument(docID: "grid")
        let date = Date(timeIntervalSince1970: 1)
        for index in 0..<nodeCount {
            let id = "n\(index)"
            model.nodes[id] = Node(
                id: id,
                title: NodeTitle(text: "Node \(index) title"),
                created: date, modified: date)
        }
        var nextChild = 1
        model.roots = ["n0"]
        var frontier = 0
        while nextChild < nodeCount {
            let childCount = min(3, nodeCount - nextChild)
            model.nodes["n\(frontier)"]?.children =
                (nextChild..<(nextChild + childCount)).map { "n\($0)" }
            for child in nextChild..<(nextChild + childCount) {
                model.nodes["n\(child)"]?.parent = "n\(frontier)"
            }
            nextChild += childCount
            frontier += 1
        }
        return model
    }

    /// Queries over a covering sweep of rectangles must match a grid built
    /// from scratch.
    private func assertGridsAgree(_ incremental: SpatialGrid, _ rebuilt: SpatialGrid) {
        for row in 0..<24 {
            for column in 0..<24 {
                let probe = CGRect(
                    x: -2_000 + CGFloat(column) * 190, y: -2_000 + CGFloat(row) * 190,
                    width: 4_400, height: 4_400)
                let expected = rebuilt.ids(intersecting: probe)
                let actual = incremental.ids(intersecting: probe)
                #expect(
                    actual == expected,
                    "probe \(probe) — incremental \(actual.count) ids vs rebuilt \(expected.count)")
            }
        }
        // Point queries through the same public API the hit-tester uses.
        for x in stride(from: -300.0, through: 1_500.0, by: 37) {
            for y in stride(from: -300.0, through: 900.0, by: 41) {
                let point = CGRect(x: x, y: y, width: 0.001, height: 0.001)
                #expect(
                    incremental.ids(intersecting: point) == rebuilt.ids(intersecting: point),
                    "point (\(x), \(y))")
            }
        }
    }

    @Test func updateRemoveMatchAFullRebuild() {
        let measurer = TextMeasurer()
        let model = smallModel(nodeCount: 40)
        let first = SceneGeometry.build(model: model, variant: .light, measurer: measurer)

        // Rename one node (size change → move), delete another (removed),
        // add a child (added).
        var edited = model
        edited.nodes["n8"]?.title = NodeTitle(text: "Node eight gets a much longer title")
        try? MapCommand.deleteSubtrees(ids: ["n10"]).apply(to: &edited)
        let extra = Node(id: "extra", title: NodeTitle(text: "Extra"))
        try? MapCommand.addChild(parent: "n1", index: nil, node: extra).apply(to: &edited)
        let second = SceneGeometry.build(model: edited, variant: .light, measurer: measurer)
        #expect(second.nodes["n10"] == nil)
        #expect(second.nodes["extra"] != nil)

        var incremental = SpatialGrid()
        for node in first.nodes.values {
            incremental.insert(id: node.id, frame: node.frame)
        }
        let diff = SceneDiffer.diff(old: first, new: second)
        for (id, change) in diff.nodes {
            switch change {
            case .removed:
                incremental.remove(id: id)
            case .added:
                if let frame = second.nodes[id]?.frame {
                    incremental.insert(id: id, frame: frame)
                }
            case .moved(_, let to), .restyled(_, let to):
                incremental.update(id: id, frame: to)
            }
        }
        var rebuilt = SpatialGrid()
        for node in second.nodes.values {
            rebuilt.insert(id: node.id, frame: node.frame)
        }
        assertGridsAgree(incremental, rebuilt)
    }

    @Test func insertReplacesInsteadOfDuplicating() {
        var grid = SpatialGrid()
        let frame = CGRect(x: 10, y: 10, width: 40, height: 20)
        grid.insert(id: "a", frame: frame)
        grid.insert(id: "a", frame: frame.offsetBy(dx: 500, dy: 500))
        // The old cells no longer hold the id.
        #expect(grid.ids(intersecting: frame) == [])
        #expect(grid.ids(intersecting: frame.offsetBy(dx: 500, dy: 500)) == ["a"])
        grid.remove(id: "a")
        #expect(grid.ids(intersecting: frame.offsetBy(dx: 500, dy: 500)) == [])
    }

    @Test func canvasViewGridStaysCorrectAcrossSceneChanges() {
        let measurer = TextMeasurer()
        let model = smallModel(nodeCount: 40)
        let first = SceneGeometry.build(model: model, variant: .light, measurer: measurer)
        var edited = model
        edited.nodes["n13"]?.title = NodeTitle(text: "Node thirteen renamed much longer")
        edited.nodes["n5"]?.offset = ModelOffset(x: 90, y: 40)
        let second = SceneGeometry.build(model: edited, variant: .light, measurer: measurer)
        #expect(second.nodes["n13"]!.frame != first.nodes["n13"]!.frame)
        #expect(second.nodes["n5"]!.frame != first.nodes["n5"]!.frame)

        // One view applies scenes through the public setter (its grid
        // syncs incrementally); the other rebuilds each scene in place.
        let incrementalView = CanvasView()
        let rebuiltView = CanvasView()
        incrementalView.scene = first
        incrementalView.scene = second
        rebuiltView.scene = second

        for x in stride(from: -100.0, through: 1_600.0, by: 29) {
            for y in stride(from: -100.0, through: 800.0, by: 31) {
                let point = NSPoint(x: x, y: y)
                #expect(
                    incrementalView.nodeID(at: point) == rebuiltView.nodeID(at: point),
                    "hit test diverged at (\(x), \(y))")
            }
        }
        // The moved nodes hit at their new frames on the incremental path.
        let renamedFrame = second.nodes["n13"]!.frame
        let hit = incrementalView.nodeID(
            at: NSPoint(x: renamedFrame.midX, y: renamedFrame.midY))
        #expect(hit == "n13")
    }
}
