import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

let sceneDate = Date(timeIntervalSince1970: 1_800_000_000)

func sceneModel(rootText: String = "Central Idea") -> MapModel {
    var model = MapModel.emptyDocument(docID: "scene")
    let rootID = "root"
    model.nodes[rootID] = Node(
        id: rootID, title: NodeTitle(text: rootText), created: sceneDate, modified: sceneDate)
    model.roots = [rootID]
    let branchTitles = ["alpha", "beta", "gamma"]
    for (index, text) in branchTitles.enumerated() {
        let id = "branch-\(index)"
        model.nodes[id] = Node(
            id: id, parent: rootID, title: NodeTitle(text: text),
            created: sceneDate, modified: sceneDate)
        model.nodes[rootID]?.children.append(id)
        let leafID = "leaf-\(index)-0"
        model.nodes[leafID] = Node(
            id: leafID, parent: id, title: NodeTitle(text: "leaf \(index)"),
            created: sceneDate, modified: sceneDate)
        model.nodes[id]?.children.append(leafID)
    }
    return model
}

struct SceneGeometryTests {
    @Test func buildsEveryVisibleNode() throws {
        let model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        #expect(scene.nodes.count == 7)
        #expect(scene.branches.count == 6)
        #expect(scene.nodes["root"] != nil)
        #expect(scene.nodes["branch-0"] != nil)
        #expect(scene.nodes["leaf-0-0"] != nil)
    }

    @Test func framesDoNotOverlapAndRootsStack() throws {
        let model = sceneModel()
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
    }

    @Test func branchColorsFollowTheLevelOneIndex() throws {
        let model = sceneModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let branchEdge = scene.branches.first { $0.childID == "branch-1" }
        let leafEdge = scene.branches.first { $0.childID == "leaf-1-0" }
        #expect(PaperTheme.hex(of: try #require(branchEdge?.color)) == 0xF76B15)
        #expect(PaperTheme.hex(of: try #require(leafEdge?.color)) == 0xF76B15)
    }

    @Test func foldedSubtreesAreSkipped() {
        var model = sceneModel()
        model.nodes["branch-1"]?.folded = true
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        #expect(scene.nodes["branch-1"] != nil)
        #expect(scene.nodes["leaf-1-0"] == nil)
        #expect(scene.branches.count == 5)
    }

    @Test func multipleRootsStackVertically() throws {
        var model = sceneModel()
        let secondRoot = "root-2"
        model.nodes[secondRoot] = Node(
            id: secondRoot, title: NodeTitle(text: "Second"), created: sceneDate, modified: sceneDate)
        model.roots.append(secondRoot)

        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let first = try #require(scene.nodes["root"]?.frame)
        let second = try #require(scene.nodes[secondRoot]?.frame)
        #expect(second.minY > first.maxY)
    }

    @Test func pinnedSidesAreRespected() throws {
        var model = sceneModel()
        model.nodes["branch-0"]?.side = .right
        model.nodes["branch-1"]?.side = .right
        model.nodes["branch-2"]?.side = .left
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let root = try #require(scene.nodes["root"]?.frame)
        #expect(try #require(scene.nodes["branch-2"]?.frame).maxX <= root.minX)
        #expect(try #require(scene.nodes["branch-0"]?.frame).minX >= root.maxX)
        #expect(try #require(scene.nodes["branch-1"]?.frame).minX >= root.maxX)
    }
}

struct SpatialGridTests {
    @Test func pointLookupFindsTheRightNode() {
        var grid = SpatialGrid()
        grid.insert(id: "a", frame: CGRect(x: 10, y: 10, width: 100, height: 40))
        grid.insert(id: "b", frame: CGRect(x: 3000, y: -600, width: 90, height: 30))

        #expect(grid.id(at: CGPoint(x: 60, y: 30)) == "a")
        #expect(grid.id(at: CGPoint(x: 3045, y: -585)) == "b")
        #expect(grid.id(at: CGPoint(x: 500, y: 500)) == nil)
    }

    @Test func rectLookupReturnsExactHits() {
        var grid = SpatialGrid()
        grid.insert(id: "a", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        grid.insert(id: "b", frame: CGRect(x: 100, y: 0, width: 50, height: 50))
        grid.insert(id: "c", frame: CGRect(x: 1000, y: 1000, width: 50, height: 50))

        #expect(grid.ids(intersecting: CGRect(x: 0, y: 0, width: 120, height: 60)) == ["a", "b"])
        #expect(grid.ids(intersecting: CGRect(x: 600, y: 600, width: 900, height: 900)) == ["c"])
        #expect(grid.ids(intersecting: CGRect(x: -10, y: -10, width: 5, height: 5)) == [])
    }

    @Test func framesSpanningManyCellsRegisterEverywhere() {
        var grid = SpatialGrid()
        grid.insert(
            id: "wide",
            frame: CGRect(x: -1000, y: -1000, width: 4000, height: 4000))
        #expect(grid.id(at: CGPoint(x: 1500, y: 1500)) == "wide")
        #expect(grid.id(at: CGPoint(x: -999, y: -999)) == "wide")
    }
}
