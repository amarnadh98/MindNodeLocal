import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// Scene diffing by node id: added / removed / moved (frame only) /
/// restyled (content or style). Pure, headless.
struct SceneDiffTests {
    @Test func addedAndRemovedNodes() {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)

        // Add one child to the first branch.
        var grown = sceneModel()
        grown.nodes["new-node"] = Node(
            id: "new-node", parent: "branch-0", title: NodeTitle(text: "new"),
            created: sceneDate, modified: sceneDate)
        grown.nodes["branch-0"]?.children.append("new-node")
        let added = SceneGeometry.build(
            model: grown, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: added)
        #expect(diff.nodes["new-node"] == .added)
        #expect(diff.addedNodeIDs == ["new-node"])
        // Everything else moved (the new sibling pushes the layout).
        #expect(
            diff.nodes["root"] == nil
                || diff.nodes["root"]
                    == .moved(
                        fromFrame: base.nodes["root"]!.frame, toFrame: added.nodes["root"]!.frame)
        )

        // The inverse diff reports the removal.
        let removedDiff = SceneDiffer.diff(old: added, new: base)
        #expect(removedDiff.nodes["new-node"] == .removed)
        #expect(removedDiff.removedNodeIDs == ["new-node"])
        // The branch into the new node was added / removed too.
        #expect(
            removedDiff.branchesRemoved.contains {
                $0.childID == "new-node" && $0.parentID == "branch-0"
            })
    }

    @Test func pureMovesAreMovesNotRestyles() {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)

        // F-LAY-11: a manual offset moves a subtree after auto layout —
        // content unchanged, frame changed.
        var moved = sceneModel()
        moved.nodes["branch-1"]?.offset = ModelOffset(x: 40, y: 12)
        let offset = SceneGeometry.build(
            model: moved, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: offset)
        let change = diff.nodes["branch-1"]
        #expect(
            change
                == .moved(
                    fromFrame: base.nodes["branch-1"]!.frame,
                    toFrame: offset.nodes["branch-1"]!.frame))
        // The subtree's frames moved too, but nothing restyled.
        for (id, change) in diff.nodes {
            if case .restyled = change {
                Issue.record("pure offset restyled \(id)")
            }
        }
    }

    @Test func styleChangeIsRestyledNotMoved() {
        let light = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let dark = SceneGeometry.build(
            model: sceneModel(), variant: .dark, measurer: SceneRenderer.sharedMeasurer)

        // Same model, same frames, different theme → every node
        // restyled at an identical frame.
        let diff = SceneDiffer.diff(old: light, new: dark)
        #expect(diff.nodes.count == light.nodes.count)
        for (id, change) in diff.nodes {
            guard case .restyled(let from, let to) = change else {
                Issue.record("\(id) should restyle on theme change, got \(change)")
                continue
            }
            #expect(from == light.nodes[id]!.frame)
            #expect(to == dark.nodes[id]!.frame)
        }
    }

    @Test func titleChangeIsRestyledAndMayMove() {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let retitled = SceneGeometry.build(
            model: sceneModel(rootText: "A Considerably Longer Central Title"),
            variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: retitled)
        // The root's title (content) changed, so it is never a pure move.
        #expect(diff.nodes["root"] != nil)
        if case .restyled = diff.nodes["root"] {
            // expected
        } else {
            Issue.record("root should restyle on title change")
        }
    }

    @Test func identicalScenesDiffToNothing() {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let diff = SceneDiffer.diff(old: scene, new: scene)
        #expect(diff.nodes.isEmpty)
        #expect(diff.branchesAdded.isEmpty)
        #expect(diff.branchesRemoved.isEmpty)
        #expect(diff.branchMorphs.isEmpty)
    }

    @Test func branchMorphKeepsBothVersions() {
        let base = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        var moved = sceneModel()
        moved.nodes["branch-1"]?.offset = ModelOffset(x: 0, y: 30)
        let offset = SceneGeometry.build(
            model: moved, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        let diff = SceneDiffer.diff(old: base, new: offset)
        let morph = diff.branchMorphs.first { $0.new.childID == "leaf-1-0" }
        #expect(morph != nil)
        #expect(morph?.old.from != morph?.new.from)
        #expect(morph?.old.childID == morph?.new.childID)
    }
}
