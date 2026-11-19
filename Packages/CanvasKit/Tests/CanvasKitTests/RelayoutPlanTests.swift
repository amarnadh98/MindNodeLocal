import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// The relayout animation plan (SPEC §7.6): which ids animate how, and
/// that Reduce Motion collapses all of it to nothing. Pure, headless.
struct RelayoutPlanTests {
    @Test func newNodesAppearFromTheParentAnchor() throws {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        var grown = sceneModel()
        grown.nodes["new-node"] = Node(
            id: "new-node", parent: "branch-0", title: NodeTitle(text: "new"),
            created: sceneDate, modified: sceneDate)
        grown.nodes["branch-0"]?.children.append("new-node")
        let added = SceneGeometry.build(
            model: grown, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: added)
        let plan = RelayoutPlanner.plan(
            old: base, new: added, diff: diff, reduceMotion: false)

        let appear = try #require(plan.moves["new-node"])
        guard case .appear(let fromAnchor, let frame) = appear else {
            Issue.record("new node should appear, got \(appear)")
            return
        }
        #expect(frame == added.nodes["new-node"]!.frame)
        // The parent anchor is the branch's outgoing point.
        let incoming = try #require(added.branches.first { $0.childID == "new-node" })
        #expect(fromAnchor == incoming.from)
    }

    @Test func deletedNodesDisappearFromTheirOldFrame() throws {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        var shrunken = sceneModel()
        shrunken.nodes["branch-1"]?.children.removeAll()
        shrunken.nodes.removeValue(forKey: "leaf-1-0")
        let deleted = SceneGeometry.build(
            model: shrunken, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: deleted)
        let plan = RelayoutPlanner.plan(
            old: base, new: deleted, diff: diff, reduceMotion: false)

        let move = try #require(plan.moves["leaf-1-0"])
        guard case .disappear(let frame) = move else {
            Issue.record("deleted node should disappear, got \(move)")
            return
        }
        #expect(frame == base.nodes["leaf-1-0"]!.frame)
    }

    @Test func movedNodesSpringFromOldToNewOrigin() throws {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        var moved = sceneModel()
        moved.nodes["branch-1"]?.offset = ModelOffset(x: 30, y: 8)
        let offset = SceneGeometry.build(
            model: moved, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: offset)
        let plan = RelayoutPlanner.plan(
            old: base, new: offset, diff: diff, reduceMotion: false)

        let spring = try #require(plan.moves["branch-1"])
        guard case .spring(let fromOrigin, let toOrigin) = spring else {
            Issue.record("moved node should spring, got \(spring)")
            return
        }
        #expect(fromOrigin == base.nodes["branch-1"]!.frame.origin)
        #expect(toOrigin == offset.nodes["branch-1"]!.frame.origin)
        #expect(fromOrigin != toOrigin)
    }

    @Test func restyledNodesAtTheSameFrameDoNotMove() {
        let light = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let dark = SceneGeometry.build(
            model: sceneModel(), variant: .dark, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: light, new: dark)
        let plan = RelayoutPlanner.plan(
            old: light, new: dark, diff: diff, reduceMotion: false)
        // A pure theme change re-rasters but never moves anything.
        for (id, move) in plan.moves {
            Issue.record("theme change should not move \(id): \(move)")
        }
        #expect(plan.branchMorphs.isEmpty)
    }

    @Test func reduceMotionProducesNoPlan() {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        var grown = sceneModel()
        grown.nodes["new-node"] = Node(
            id: "new-node", parent: "branch-0", title: NodeTitle(text: "new"),
            created: sceneDate, modified: sceneDate)
        grown.nodes["branch-0"]?.children.append("new-node")
        let added = SceneGeometry.build(
            model: grown, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: added)
        let plan = RelayoutPlanner.plan(
            old: base, new: added, diff: diff, reduceMotion: true)
        #expect(plan.isEmpty, "Reduce Motion must not animate: \(plan.moves)")
    }

    @Test func firstSceneNeverAnimates() {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let diff = SceneDiffer.diff(old: nil, new: scene)
        #expect(diff.addedNodeIDs.count == scene.nodes.count)
        let plan = RelayoutPlanner.plan(
            old: nil, new: scene, diff: diff, reduceMotion: false)
        #expect(plan.isEmpty, "initial load must land at first paint instantly")
    }
}
