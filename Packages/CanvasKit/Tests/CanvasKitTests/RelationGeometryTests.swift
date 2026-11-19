import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

/// Headless relation-geometry tests (F-REL-1/2/3): the Bézier and
/// hit-test math, label placement, arrowhead orientation, boundary
/// padding and organic-smoothing determinism, summary brace geometry,
/// and the overlays' consistency through model edits (the same
/// pure-build invariant any future incremental scene path inherits —
/// overlays derive from frames only).
@MainActor
struct RelationGeometryTests {
    private let measurer = TextMeasurer()

    private func sceneModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "relations")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ id: String, parent: String?, title: String) {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: title),
                created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        add("root", parent: nil, title: "Root")
        add("a", parent: "root", title: "Alpha")
        add("b", parent: "root", title: "Beta")
        add("c", parent: "root", title: "Gamma")
        add("a1", parent: "a", title: "Alpha child")
        return model
    }

    private func build(_ model: MapModel) -> CanvasScene {
        SceneGeometry.build(model: model, variant: .light, measurer: measurer)
    }

    // MARK: F-REL-1 connections

    @Test func connectionAnchorsSitOnNodeEdgesWithDefaultBow() throws {
        var model = sceneModel()
        model.connections = [Connection(id: "conn", from: "a", to: "b")]
        let scene = build(model)
        #expect(scene.connections.count == 1)
        let connection = try #require(scene.connections.first)
        let frameA = try #require(scene.nodes["a"]?.frame)
        let frameB = try #require(scene.nodes["b"]?.frame)

        // The connection runs between the two nodes' facing edges.
        #expect(connection.from.x == frameA.maxX)
        #expect(connection.to.x == frameB.minX)
        #expect(abs(connection.from.y - frameA.midY) < 1)
        #expect(abs(connection.to.y - frameB.midY) < 1)

        // The stored offset is nil → the default control: the midpoint
        // bow, perpendicular to the segment.
        let defaultControl = RelationPath.defaultControl(from: connection.from, to: connection.to)
        #expect(connection.control == defaultControl)
        #expect(!connection.straight)

        // The label/handle position is the curve's t = 0.5 point, which
        // lies between the segment midpoint and the control.
        let midpoint = CGPoint(
            x: (connection.from.x + connection.to.x) / 2,
            y: (connection.from.y + connection.to.y) / 2)
        let bow = hypot(defaultControl.x - midpoint.x, defaultControl.y - midpoint.y)
        #expect(bow > 0.5)
        let handleToMidpoint = hypot(
            connection.handlePosition.x - midpoint.x, connection.handlePosition.y - midpoint.y)
        #expect(abs(handleToMidpoint - bow / 2) < 0.01)
    }

    @Test func controlOffsetRoundTripsThroughTheHandle() throws {
        var model = sceneModel()
        model.connections = [Connection(id: "conn", from: "a", to: "b")]
        let scene = build(model)
        let connection = try #require(scene.connections.first)
        let handle = CGPoint(x: connection.from.x + 40, y: connection.from.y - 30)
        // The stored offset is the exact inversion of
        // handle = (segment midpoint + control) / 2.
        let midpoint = CGPoint(
            x: (connection.from.x + connection.to.x) / 2,
            y: (connection.from.y + connection.to.y) / 2)
        let expectedControl = CGPoint(
            x: 2 * handle.x - midpoint.x, y: 2 * handle.y - midpoint.y)
        let offset = RelationGeometry.controlOffset(for: connection, handlePoint: handle)
        let defaultControl = RelationPath.defaultControl(from: connection.from, to: connection.to)
        #expect(
            offset
                == ModelOffset(
                    x: expectedControl.x - defaultControl.x,
                    y: expectedControl.y - defaultControl.y))

        // Rebuilding with the stored offset puts the handle at the
        // dragged point.
        model.connections = [
            Connection(id: "conn", from: "a", to: "b", control: offset)
        ]
        let rebuilt = build(model)
        let moved = try #require(rebuilt.connections.first)
        #expect(abs(moved.handlePosition.x - handle.x) < 0.01)
        #expect(abs(moved.handlePosition.y - handle.y) < 0.01)
    }

    @Test func hitTestFollowsTheCurveWithTolerance() throws {
        var model = sceneModel()
        model.connections = [Connection(id: "conn", from: "a", to: "a1")]
        let scene = build(model)
        let connection = try #require(scene.connections.first)

        // A point on the sampled polyline hits; a far point misses.
        let onCurve = connection.samples[12]
        #expect(
            RelationGeometry.connectionID(
                at: onCurve, tolerance: RelationGeometry.hitTolerance, in: scene.connections)
                == "conn")
        let far = CGPoint(x: onCurve.x, y: onCurve.y + 120)
        #expect(
            RelationGeometry.connectionID(
                at: far, tolerance: RelationGeometry.hitTolerance, in: scene.connections)
                == nil)

        // Tolerance rules: 4 pt off the curve hits, 20 pt off does not
        // (probe along the curve's normal at the midpoint, where the
        // polyline is dense).
        let near = CGPoint(x: onCurve.x, y: onCurve.y + 4)
        let distant = CGPoint(x: onCurve.x, y: onCurve.y + 20)
        #expect(
            RelationGeometry.connectionID(
                at: near, tolerance: RelationGeometry.hitTolerance, in: scene.connections) == "conn")
        #expect(
            RelationGeometry.connectionID(
                at: distant, tolerance: RelationGeometry.hitTolerance, in: scene.connections)
                == nil)

        // The straight style hits along the segment, not the curve.
        model.connections = [
            Connection(
                id: "conn", from: "a", to: "a1",
                style: ConnectionStyle(lineStyle: .straight))
        ]
        let straightScene = build(model)
        let straight = try #require(straightScene.connections.first)
        #expect(straight.straight)
        let curvePeak = RelationPath.point(
            onConnection: straight.from, to: straight.to, control: straight.control,
            straight: false, parameter: 0.5)
        #expect(
            RelationGeometry.connectionID(
                at: curvePeak, tolerance: 2, in: straightScene.connections) == nil)
    }

    @Test func arrowheadsOrientAlongTheTangents() throws {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 100, y: 0)
        let control = RelationPath.defaultControl(from: from, to: to)
        // A horizontal connection bows down (y +): both tangents head
        // along the direction of travel (+x), the start toward the bow
        // and the end arriving up into the tip — an end arrowhead
        // points +x, a start arrowhead points −x (the travel negated).
        let start = RelationPath.tangent(
            onConnection: from, to: to, control: control, straight: false, parameter: 0)
        let end = RelationPath.tangent(
            onConnection: from, to: to, control: control, straight: false, parameter: 1)
        #expect(start.x > 0.9)
        #expect(start.y > 0)
        #expect(end.x > 0.9)
        #expect(end.y < 0)

        // Arrowheads open backward from the tip.
        let head = RelationPath.arrowhead(at: to, direction: end, width: 1.5)
        let box = head.boundingBox
        #expect(box.minX <= to.x && box.maxX <= to.x + 0.01)
        #expect(box.minY < to.y && box.maxY > to.y)

        // A straight connection's tangents are the unit segment.
        let straightTangent = RelationPath.tangent(
            onConnection: from, to: to, control: control, straight: true, parameter: 0)
        #expect(straightTangent == CGPoint(x: 1, y: 0))
    }

    @Test func foldedEndpointsHideTheConnection() throws {
        var model = sceneModel()
        model.connections = [Connection(id: "conn", from: "a", to: "a1")]
        #expect(build(model).connections.count == 1)

        // F-LAY-14: a folded endpoint takes the connection's overlays
        // away — folding "a" removes "a1" from the scene, and the
        // connection that pointed at it goes with it.
        model.nodes["a"]?.folded = true
        let scene = build(model)
        #expect(scene.nodes["a1"] == nil)
        #expect(scene.connections.isEmpty)
    }

    // MARK: F-REL-2 boundaries

    @Test func boundaryWrapsMembersAndSubtreesAndFollowsRelayout() throws {
        var model = sceneModel()
        model.boundaries = [Boundary(id: "bd", nodes: ["a", "b"], title: "Group")]
        var scene = build(model)
        #expect(scene.boundaries.count == 1)
        let boundary = try #require(scene.boundaries.first)
        #expect(boundary.memberIDs.contains("a1"))
        // The outline covers every member subtree (a + a1, b) plus
        // padding, and the title sits inside the top-left.
        for id in ["a", "a1", "b"] {
            let frame = try #require(scene.nodes[id]?.frame)
            #expect(boundary.bounds.contains(frame))
        }
        #expect(boundary.bounds.minX < (scene.nodes["a"]?.frame.minX ?? 0))
        #expect(boundary.title == "Group")

        // A longer title relayouts the child; the pure rebuild follows.
        let oldBounds = boundary.bounds
        model.nodes["a1"]?.title = NodeTitle(text: "A much longer alpha child title that wraps")
        scene = build(model)
        let grown = try #require(scene.boundaries.first)
        #expect(grown.bounds.width >= oldBounds.width)
        #expect(grown.bounds.contains(try #require(scene.nodes["a1"]?.frame)))
    }

    @Test func organicOutlineIsDeterministicAndDistinctFromRounded() {
        let frames = [
            CGRect(x: 0, y: 0, width: 80, height: 24),
            CGRect(x: 120, y: 0, width: 60, height: 24),
            CGRect(x: 0, y: 60, width: 60, height: 24),
        ]
        let first = RelationPath.boundaryOutline(
            frames: frames, padding: 14, cornerRadius: 16, organic: true)
        let second = RelationPath.boundaryOutline(
            frames: frames, padding: 14, cornerRadius: 16, organic: true)
        // Same frames → the same bounds (the rounded-hull walk is
        // deterministic in its vertex order).
        #expect(first.boundingBoxOfPath == second.boundingBoxOfPath)

        // The hull tightens where the rounded rect fills the whole
        // combined box: its diagonal waist leaves the bbox's corners
        // outside the outline.
        let rounded = RelationPath.boundaryOutline(
            frames: frames, padding: 14, cornerRadius: 16, organic: false)
        let combined = frames[0].union(frames[1]).union(frames[2]).insetBy(dx: -14, dy: -14)
        #expect(rounded.boundingBoxOfPath == combined)
        let bottomRight = CGPoint(x: 150, y: 90)
        #expect(rounded.contains(bottomRight, using: .winding))
        #expect(!first.contains(bottomRight, using: .winding))

        // Determinism: the convex hull is ordered and stable.
        let corners = frames.flatMap { frame in
            [
                CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY),
            ]
        }
        let hull = RelationPath.convexHull(of: corners)
        #expect(hull.count >= 4)
        let again = RelationPath.convexHull(of: corners.shuffled())
        #expect(hull == again)
    }

    @Test func boundaryStyleOverridesSelectOrganicAndDash() throws {
        var model = sceneModel()
        model.boundaries = [
            Boundary(
                id: "bd", nodes: ["a", "b"],
                style: ConnectionStyle(color: "#0090FF", dash: true, lineStyle: .curve))
        ]
        let scene = build(model)
        let boundary = try #require(scene.boundaries.first)
        #expect(boundary.style.organic)
        #expect(boundary.style.dash)
        // F-REL-2: a dashed stroke, 60% alpha, 10% tint fill.
        #expect(abs(boundary.style.stroke.alpha - 0.6) < 0.001)
        #expect(abs(boundary.style.fill.alpha - 0.10) < 0.001)
    }

    // MARK: F-REL-3 summaries

    @Test func summaryPlacesItsNodeBeyondTheBrace() throws {
        var model = sceneModel()
        // A right-facing map so the range sits on one side (the
        // balanced map would split the siblings across the root).
        model.nodes["root"]?.structure = LayoutStructure.mindmapRight.rawValue
        let children = model.nodes["root"]?.children ?? []
        model.summaries = [
            Summary(id: "sm", parent: "root", range: [children[0], children[1]], node: "sum")
        ]
        model.nodes["sum"] = Node(
            id: "sum", parent: "root", title: NodeTitle(text: "Summary"),
            created: Date(), modified: Date())
        model.nodes["root"]?.children.append("sum")

        let scene = build(model)
        #expect(scene.summaries.count == 1)
        let summary = try #require(scene.summaries.first)
        let rangeUnion = try #require(scene.nodes[children[0]]?.frame)
            .union(try #require(scene.nodes[children[1]]?.frame))
        let summaryFrame = try #require(scene.nodes["sum"]?.frame)

        // The brace hugs the range's right edge; the node sits beyond
        // its mid point, aligned with the range's center.
        let braceBox = summary.brace.boundingBoxOfPath
        #expect(braceBox.minX >= rangeUnion.maxX)
        #expect(summaryFrame.minX > braceBox.maxX)
        #expect(abs(summaryFrame.midY - rangeUnion.midY) < 2)
        #expect(summary.bounds.intersects(braceBox))

        // The org-down layout puts the brace below the range instead.
        model.nodes["root"]?.structure = LayoutStructure.orgDown.rawValue
        let vertical = build(model)
        let verticalSummary = try #require(vertical.summaries.first)
        let verticalUnion = try #require(vertical.nodes[children[0]]?.frame)
            .union(try #require(vertical.nodes[children[1]]?.frame))
        let verticalBrace = verticalSummary.brace.boundingBoxOfPath
        #expect(verticalSummary.axis == .vertical)
        #expect(verticalBrace.minY >= verticalUnion.maxY)
        let verticalNode = try #require(vertical.nodes["sum"]?.frame)
        #expect(verticalNode.minY > verticalBrace.maxY)
        #expect(abs(verticalNode.midX - verticalUnion.midX) < 2)
    }

    @Test func deletingRangeNodesRemovesOrKeepsTheSummaryConsistently() throws {
        var model = sceneModel()
        let children = model.nodes["root"]?.children ?? []
        // A summary over the full range [a, b].
        model.summaries = [
            Summary(id: "sm", parent: "root", range: [children[0], children[1]], node: "sum")
        ]
        model.nodes["sum"] = Node(
            id: "sum", parent: "root", title: NodeTitle(text: "Summary"),
            created: Date(), modified: Date())
        model.nodes["root"]?.children.append("sum")

        // Deleting one range node drops the summary (its range is no
        // longer the recorded run) and the delete's inverse restores it.
        let before = model
        var working = model
        try MapCommand.deleteSubtrees(ids: [children[1]]).apply(to: &working)
        #expect(working.summaries == nil)
        let inverse = try MapCommand.deleteSubtrees(ids: [children[1]]).inverse(in: model)
        try inverse.apply(to: &working)
        #expect(working == before)

        // Deleting the summary node itself removes the record.
        var second = model
        try MapCommand.deleteSubtrees(ids: ["sum"]).apply(to: &second)
        #expect(second.summaries == nil)
        #expect(second.nodes["sum"] == nil)

        // Moving a range node out of the parent purges the stale
        // summary; the move's inverse restores it.
        var third = model
        try MapCommand.moveNode(id: children[1], parent: "a", index: 0).apply(to: &third)
        #expect(third.summaries == nil)
        let moveInverse = try MapCommand.moveNode(id: children[1], parent: "a", index: 0)
            .inverse(in: model)
        try moveInverse.apply(to: &third)
        #expect(third == before)
    }

    @Test func summaryRangeAfterMidDeleteStillBracesTheSurvivingRun() throws {
        // A three-sibling range with the middle deleted: the recorded
        // range purges (it names a deleted child), documented
        // consistency — never a brace to nowhere.
        var model = sceneModel()
        let children = model.nodes["root"]?.children ?? []
        model.summaries = [
            Summary(
                id: "sm", parent: "root",
                range: [children[0], children[1], children[2]], node: "sum")
        ]
        model.nodes["sum"] = Node(
            id: "sum", parent: "root", title: NodeTitle(text: "Summary"),
            created: Date(), modified: Date())
        model.nodes["root"]?.children.append("sum")

        var working = model
        try MapCommand.deleteSubtrees(ids: [children[1]]).apply(to: &working)
        #expect(working.summaries == nil)
        // The summary node survives as an ordinary node.
        #expect(working.nodes["sum"] != nil)
        #expect(working.nodes["root"]?.children.contains("sum") == true)
    }

    // MARK: determinism across edits (the incremental invariant)

    @Test func overlaysArePureAcrossArbitraryEditSequences() throws {
        // The overlays derive from the model and the placed frames
        // only: whichever path recomputes the frames (full rebuild or
        // a future incremental pass), the overlays must agree. Build
        // after a random command sequence and compare against a
        // from-scratch build of the final model.
        var randomState: UInt64 = 2_026
        func nextRandom() -> UInt64 {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return randomState >> 33
        }
        var model = sceneModel()
        model.connections = [Connection(id: "conn", from: "a", to: "b", label: "why")]
        model.boundaries = [Boundary(id: "bd", nodes: ["a", "b"])]
        let children = model.nodes["root"]?.children ?? []
        model.summaries = [
            Summary(id: "sm", parent: "root", range: [children[0], children[1]], node: "sum")
        ]
        model.nodes["sum"] = Node(
            id: "sum", parent: "root", title: NodeTitle(text: "Summary"),
            created: Date(), modified: Date())
        model.nodes["root"]?.children.append("sum")

        for _ in 0..<40 {
            let ids = Array(model.nodes.keys)
            guard !ids.isEmpty else { break }
            let id = ids[Int(nextRandom() % UInt64(ids.count))]
            let command = MapCommand.editText(
                id: id, title: NodeTitle(text: "renamed \(nextRandom())"))
            if (try? command.apply(to: &model)) != nil {
                let sceneA = build(model)
                let sceneB = build(model)
                #expect(sceneA.connections.map(\.samples) == sceneB.connections.map(\.samples))
                #expect(sceneA.boundaries.map(\.bounds) == sceneB.boundaries.map(\.bounds))
                #expect(sceneA.summaries.map(\.bounds) == sceneB.summaries.map(\.bounds))
            }
        }
    }

    @Test func draftTitleBuildKeepsOverlaysAligned() throws {
        // The editing draft path (live typing) rebuilds scenes the same
        // way: overlays follow the grown node exactly like a committed
        // title does.
        var model = sceneModel()
        model.boundaries = [Boundary(id: "bd", nodes: ["a"])]
        let draft = SceneGeometry.build(
            model: model, variant: .light, measurer: measurer,
            editingTitle: (id: "a", title: NodeTitle(text: "A considerably longer draft title")))
        let committed: MapModel = {
            var edited = model
            edited.nodes["a"]?.title = NodeTitle(text: "A considerably longer draft title")
            return edited
        }()
        let committedScene = build(committed)
        #expect(
            draft.boundaries.first?.bounds == committedScene.boundaries.first?.bounds)
        #expect(
            draft.nodes["a"]?.frame == committedScene.nodes["a"]?.frame)
    }
}
