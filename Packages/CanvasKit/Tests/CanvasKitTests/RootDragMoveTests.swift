import AppKit
import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import CanvasKit

// MARK: - root drag moves the map (ADR-0032)

/// A plain drag of a ROOT moves the whole map: one `.setOffset` command
/// carrying the drag delta (never a moveNode/detach), descendants follow
/// in the rebuilt scene, the offset accumulates, drops over another
/// node's frame keep the reparent, and one undo step restores.
@MainActor
struct RootDragMovesMapTests {
    /// An empty-canvas point below the whole map, comfortably inside the
    /// harness viewport (no auto-scroll) and away from every frame and
    /// gap corridor.
    private func emptyPoint(below scene: CanvasScene) -> CGPoint {
        CGPoint(x: scene.bounds.midX, y: scene.bounds.maxY + 150)
    }

    @Test func plainRootDragEmitsOneSetOffsetAndMovesTheMap() throws {
        let model = sceneModel()
        let harness = DragHarness(model: model)
        let store = MapStore(model: model, undoManager: Self.freshManager())
        let original = store.model
        var drops = 0
        var dropped: MapCommand?
        var droppedSelection: Set<String> = []
        harness.view.onDrop = { command, selection in
            if let command {
                drops += 1
                dropped = command
                droppedSelection = selection
            }
        }

        // Grab the root and drag it to empty canvas below the map.
        try harness.grab("root")
        let start = try harness.center(of: "root")
        let end = emptyPoint(below: harness.scene)
        harness.drag(to: end)
        guard case .active(let session) = harness.view.drag else {
            Issue.record("a >4 pt move must start a drag")
            return
        }
        #expect(session.target == .newRoot(at: end))
        harness.drop(at: end)

        // ONE command, a setOffset with the exact drag delta — never a
        // moveNode, never a detach.
        #expect(drops == 1)
        let command = try #require(dropped)
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        #expect(command == .setOffset(id: "root", offset: ModelOffset(x: delta.x, y: delta.y)))
        #expect(droppedSelection == ["root"])

        // Performed through the store: the root's offset is set, and the
        // rebuilt scene moves the root AND every descendant by the delta.
        try store.perform(command)
        #expect(store.model.nodes["root"]?.offset == ModelOffset(x: delta.x, y: delta.y))
        let moved = buildScene(store.model)
        let plainScene = harness.scene
        for id in ["root", "branch-0", "branch-1", "leaf-2-0"] {
            let plain = try #require(plainScene.nodes[id]?.frame)
            let shifted = try #require(moved.nodes[id]?.frame)
            #expect(abs(shifted.minX - plain.minX - delta.x) < 0.001)
            #expect(abs(shifted.minY - plain.minY - delta.y) < 0.001)
        }

        // The spatial grid follows the new scene: hit-testing at the
        // moved root's center finds it, the vacated spot finds nothing.
        harness.view.scene = moved
        let movedCenter = try #require(moved.nodes["root"]?.frame)
        #expect(
            harness.view.nodeID(at: harness.screen(CGPoint(x: movedCenter.midX, y: movedCenter.midY)))
                == "root")
        #expect(harness.view.nodeID(at: harness.screen(start)) == nil)
        // One undo step restores the pre-drag model exactly; redo
        // replays the move.
        store.undoManager.undo()
        #expect(Self.journalNormalized(store.model) == Self.journalNormalized(original))
        #expect(!store.undoManager.canUndo)
        store.undoManager.redo()
        #expect(store.model.nodes["root"]?.offset == ModelOffset(x: delta.x, y: delta.y))
    }

    @Test func plainRootDragAccumulatesOnAnExistingOffset() throws {
        var model = sceneModel()
        model.nodes["root"]?.offset = ModelOffset(x: 100, y: 50)
        let harness = DragHarness(model: model)
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in dropped = command }

        try harness.grab("root")
        let start = try harness.center(of: "root")
        let end = emptyPoint(below: harness.scene)
        harness.drag(to: end)
        harness.drop(at: end)

        // The delta lands on top of the stored offset (F-LAY-11).
        let command = try #require(dropped)
        #expect(
            command
                == .setOffset(
                    id: "root",
                    offset: ModelOffset(x: 100 + end.x - start.x, y: 50 + end.y - start.y)))
    }

    @Test func rootDraggedOverItsOwnSubtreeStillMoves() throws {
        let harness = DragHarness(model: sceneModel())
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in dropped = command }

        // The cursor passes over the dragged root's own descendants —
        // `.none` is still a move, not a snap-back.
        try harness.grab("root")
        let start = try harness.center(of: "root")
        let end = try harness.center(of: "leaf-1-0")
        #expect(hypot(end.x - start.x, end.y - start.y) > DragCommands.snapBackDistance)
        harness.drag(to: end)
        guard case .active(let session) = harness.view.drag else {
            Issue.record("expected an active drag")
            return
        }
        #expect(session.target == .none)
        harness.drop(at: end)
        #expect(
            dropped
                == .setOffset(
                    id: "root", offset: ModelOffset(x: end.x - start.x, y: end.y - start.y)))
    }

    @Test func rootDroppedOnAnotherNodesFrameStillReparents() throws {
        var model = sceneModel()
        model.nodes["root-2"] = Node(
            id: "root-2", title: NodeTitle(text: "Second"), created: sceneDate, modified: sceneDate)
        model.roots.append("root-2")
        let harness = DragHarness(model: model)
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in dropped = command }

        // ADR-0032's exception: the cursor over another node's frame
        // keeps the plain reparent drop.
        try harness.grab("root")
        let end = try harness.center(of: "root-2")
        harness.drag(to: end)
        guard case .active(let session) = harness.view.drag else {
            Issue.record("expected an active drag")
            return
        }
        #expect(session.target == .reparent(parent: "root-2", index: 0))
        harness.drop(at: end)
        #expect(dropped == .moveNode(id: "root", parent: "root-2", index: 0))
    }

    @Test func orgChartRootDragMovesTheMapToo() throws {
        let model = orgModel()
        let harness = DragHarness(model: model)
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in dropped = command }

        try harness.grab("root")
        let start = try harness.center(of: "root")
        let end = emptyPoint(below: harness.scene)
        harness.drag(to: end)
        harness.drop(at: end)

        let command = try #require(dropped)
        #expect(
            command
                == .setOffset(
                    id: "root", offset: ModelOffset(x: end.x - start.x, y: end.y - start.y)))
        var moved = model
        moved.nodes["root"]?.offset = ModelOffset(x: end.x - start.x, y: end.y - start.y)
        let movedScene = buildScene(moved)
        for id in ["a", "b"] {
            let plain = try #require(harness.scene.nodes[id]?.frame)
            let shifted = try #require(movedScene.nodes[id]?.frame)
            #expect(abs(shifted.minX - plain.minX - (end.x - start.x)) < 0.001)
            #expect(abs(shifted.minY - plain.minY - (end.y - start.y)) < 0.001)
        }
    }

    @Test func subSnapBackRootDropPerformsNothing() throws {
        let model = sceneModel()
        let harness = DragHarness(model: model)
        var drops = 0
        harness.view.onDrop = { command, _ in
            if command != nil { drops += 1 }
        }

        // A root dragged just past the threshold but back inside the
        // F-LAY-11 snap radius clears a nil offset — a no-op drop with
        // no phantom undo step.
        try harness.grab("root")
        let start = try harness.center(of: "root")
        let end = CGPoint(x: start.x + 12, y: start.y + 9)
        harness.drag(to: end)
        harness.drop(at: end)
        #expect(drops == 0)
    }

    // MARK: store helpers

    private static func freshManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    private static func journalNormalized(_ model: MapModel) -> MapModel {
        var copy = model
        for (id, _) in copy.nodes {
            copy.nodes[id]?.modified = Date(timeIntervalSince1970: 0)
            copy.nodes[id]?.modifiedBy = .user
        }
        return copy
    }
}

/// The overlays and the scene geometry a root move drags along
/// (connections, boundaries, summaries recompute from the moved frames).
struct RootMoveRelationsTests {
    @Test func connectionsBoundariesAndSummariesFollowTheMovedRoot() throws {
        var model = sceneModel()
        model.nodes["summary-node"] = Node(
            id: "summary-node", parent: "root", title: NodeTitle(text: "sum"),
            created: sceneDate, modified: sceneDate)
        model.nodes["root"]?.children.append("summary-node")
        model.connections = [
            Connection(id: "c", from: "branch-0", to: "branch-2")
        ]
        model.boundaries = [Boundary(id: "b", nodes: ["branch-0", "branch-1"])]
        model.summaries = [
            Summary(id: "s", parent: "root", range: ["branch-0", "branch-1"], node: "summary-node")
        ]

        let before = buildScene(model)
        let delta = ModelOffset(x: 140, y: -90)
        model.nodes["root"]?.offset = delta
        let after = buildScene(model)

        // The connection's anchors follow the moved endpoints…
        let connectionBefore = try #require(before.connections.first)
        let connectionAfter = try #require(after.connections.first)
        #expect(abs(connectionAfter.from.x - connectionBefore.from.x - 140) < 0.001)
        #expect(abs(connectionAfter.to.y - connectionBefore.to.y + 90) < 0.001)
        // …the boundary wraps the moved subtrees…
        let boundaryBefore = try #require(before.boundaries.first)
        let boundaryAfter = try #require(after.boundaries.first)
        #expect(abs(boundaryAfter.bounds.minX - boundaryBefore.bounds.minX - 140) < 0.001)
        #expect(abs(boundaryAfter.bounds.minY - boundaryBefore.bounds.minY + 90) < 0.001)
        // …and the summary's brace stays glued to its range (and the
        // summary node, an ordinary child, moved along).
        let summaryBefore = try #require(before.summaries.first)
        let summaryAfter = try #require(after.summaries.first)
        #expect(abs(summaryAfter.bounds.minX - summaryBefore.bounds.minX - 140) < 0.001)
        let sumNodeBefore = try #require(before.nodes["summary-node"]?.frame)
        let sumNodeAfter = try #require(after.nodes["summary-node"]?.frame)
        #expect(abs(sumNodeAfter.minY - sumNodeBefore.minY + 90) < 0.001)
    }
}
