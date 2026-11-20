import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

/// The incremental scene path's one blind spot, made deterministic
/// (ADR-0011): an edit the walk cannot see — below a folded node, or
/// inside a filter-pruned region — is never resolved, so its cached
/// entry chain survives stale. When the region reopens (an unfold, or a
/// move carrying the subtree out of the fold), an intermediate ancestor
/// whose own inputs are unchanged would reuse the old placement and
/// serve the stale state. `IncrementalLayout.update` purges the recorded
/// parent chain of every dirty id its pass could not resolve; these two
/// regressions pin that contract (the seeded equivalence suite reaches
/// the same class of failure only per random realization — it is what
/// caught the bug on CI).
struct SceneGeometryFoldEditTests {
    // MARK: the model

    /// R → [S, F]; F → [U]; U → [V]; V → [W, V2]. U's own inputs never
    /// change in either scenario, so only the purge can force the
    /// reopened chain to relayout.
    private func foldedEditModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "fold-edit")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func make(_ id: String, _ title: String, children: [String] = []) -> Node {
            var node = Node(id: id, title: NodeTitle(text: title), created: date, modified: date)
            node.children = children
            return node
        }
        model.nodes["R"] = make("R", "Root", children: ["S", "F"])
        model.nodes["S"] = make("S", "Side branch long enough to matter")
        model.nodes["F"] = make("F", "Fold me", children: ["U"])
        model.nodes["U"] = make("U", "Untouched mid", children: ["V"])
        model.nodes["V"] = make("V", "Parent of the pair", children: ["W", "V2"])
        model.nodes["W"] = make("W", "Leaf")
        model.nodes["V2"] = make("V2", "Sibling")
        for parent in ["R", "F", "U", "V"] {
            for child in model.nodes[parent]?.children ?? [] {
                model.nodes[child]?.parent = parent
            }
        }
        model.roots = ["R"]
        return model
    }

    /// Fold F, apply `edit` while U's subtree is invisible, reopen F.
    private func reopened(
        model: inout MapModel, measurer: TextMeasurer, cache: SceneBuildCache,
        edit: MapCommand
    ) throws -> (incremental: CanvasScene, full: CanvasScene) {
        func update(_ command: MapCommand, on edited: MapModel) throws -> CanvasScene {
            let dirty = try #require(SceneGeometry.dirtyIDs(for: command, in: edited))
            return SceneGeometry.update(
                model: edited, cache: cache, variant: .light, measurer: measurer, dirty: dirty)
        }

        // Fold: U's subtree leaves the scene.
        try MapCommand.setFolded(id: "F", folded: true).apply(to: &model)
        _ = try update(.setFolded(id: "F", folded: true), on: model)

        // The blind edit — below the fold, invisible to the walk.
        try edit.apply(to: &model)
        _ = try update(edit, on: model)

        // Reopen: the chain must serve the edit fresh.
        try MapCommand.setFolded(id: "F", folded: false).apply(to: &model)
        let incremental = try update(.setFolded(id: "F", folded: false), on: model)
        let full = SceneGeometry.build(model: model, variant: .light, measurer: measurer)
        return (incremental, full)
    }

    // MARK: the regressions

    @Test func renameUnderAFoldServesAFreshFrameWhenReopened() throws {
        let measurer = TextMeasurer()
        var model = foldedEditModel()
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        let rename = MapCommand.editText(
            id: "W", title: NodeTitle(text: "A considerably longer leaf title"))
        let scenes = try reopened(
            model: &model, measurer: measurer, cache: cache, edit: rename)

        #expect(scenes.incremental.nodes.count == scenes.full.nodes.count)
        #expect(
            scenes.incremental.nodes["W"]?.frame == scenes.full.nodes["W"]?.frame,
            "the renamed leaf's frame must be its measured post-rename size")
    }

    @Test func moveUnderAFoldKeepsTheMovedNodeWhenReopened() throws {
        let measurer = TextMeasurer()
        var model = foldedEditModel()
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        // W moves under its sibling V2 while both are folded away.
        let move = MapCommand.moveNode(id: "W", parent: "V2", index: 0)
        let scenes = try reopened(model: &model, measurer: measurer, cache: cache, edit: move)

        #expect(scenes.incremental.nodes.count == scenes.full.nodes.count)
        #expect(
            scenes.incremental.nodes["W"] != nil,
            "the moved node must reappear when the fold reopens")
        #expect(
            scenes.incremental.nodes["V"]?.frame == scenes.full.nodes["V"]?.frame,
            "the donor parent must relayout without its moved child")
    }
}
