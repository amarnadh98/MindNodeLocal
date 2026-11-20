import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

/// M3 content commands through the incremental scene path: task
/// toggles (checkbox → ring changes on every ancestor), tag edits and
/// note/link edits all change **decorations**, and decorations are part
/// of the measured size — so `SceneGeometry.update` with the
/// command-derived dirty set must produce a scene exactly equal to a
/// full `SceneGeometry.build` of the same model (frames *and*
/// decorations included). The companion property suite
/// (`SceneGeometryIncrementalTests`) covers the structural commands;
/// this one owns the content-command quarter.
struct SceneGeometryContentIncrementalTests {
    /// A three-level map: root → mid → two leaves, with a tag definition
    /// in place.
    private func contentModel() -> MapModel {
        let date = Date(timeIntervalSince1970: 1)
        func node(_ id: String, parent: String?) -> Node {
            Node(id: id, parent: parent, title: NodeTitle(text: id), created: date, modified: date)
        }

        var model = MapModel.emptyDocument(docID: "content")
        model.nodes["root"] = node("root", parent: nil)
        model.nodes["mid"] = node("mid", parent: "root")
        model.nodes["leafA"] = node("leafA", parent: "mid")
        model.nodes["leafB"] = node("leafB", parent: "mid")
        model.nodes["root"]?.children = ["mid"]
        model.nodes["mid"]?.children = ["leafA", "leafB"]
        model.roots = ["root"]
        model.tags = [Tag(id: "t-urgent", name: "urgent", color: "#E5484D")]
        return model
    }

    /// Frames and decorations exactly equal — the two outputs an
    /// incremental content edit can move (styles/levels are pinned by
    /// the structural suite).
    private func assertScenesEqual(_ incremental: CanvasScene, _ full: CanvasScene, _ comment: String) {
        #expect(incremental.nodes.count == full.nodes.count, "\(comment)")
        for (id, left) in incremental.nodes {
            guard let right = full.nodes[id] else {
                Issue.record("\(comment): id \(id) missing in full")
                continue
            }
            #expect(left.frame == right.frame, "\(comment): frame \(id)")
            let detail =
                "\(comment): decorations \(id) — \(String(describing: left.decorations)) "
                + "vs \(String(describing: right.decorations))"
            #expect(left.decorations == right.decorations, "\(detail)")
        }
    }

    @Test func updateEqualsFullRebuildAfterContentEdits() throws {
        let measurer = TextMeasurer()
        var model = contentModel()
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        /// One round: apply, take the command-derived dirty set (the
        /// host's full-rebuild fallback when nil), compare.
        func round(_ command: MapCommand, _ comment: String) throws {
            var edited = model
            try command.apply(to: &edited)
            let dirty = SceneGeometry.dirtyIDs(for: command, in: edited)
            let full = SceneGeometry.build(model: edited, variant: .light, measurer: measurer)
            if let dirty {
                let incremental = SceneGeometry.update(
                    model: edited, cache: cache, variant: .light, measurer: measurer,
                    dirty: dirty)
                assertScenesEqual(incremental, full, comment)
            } else {
                // nil = the host's full-rebuild fallback, which is the
                // reference itself.
                assertScenesEqual(full, full, comment)
            }
            model = edited
        }

        // Task on: the leaf gains a checkbox, `mid` and `root` gain
        // rings — all three re-measure.
        try round(.setTask(ids: ["leafA"], isTask: true), "task on")
        #expect(model.nodes["leafA"]?.task != nil)
        // A second leaf task grows both rings' totals.
        try round(.setTask(ids: ["leafB"], isTask: true), "second task")
        // Completing one leaf fills the rings one step further.
        try round(.setTaskDone(ids: ["leafA"], done: true), "task done")
        try round(.setTaskDetails(id: "leafA", due: "2026-12-01", priority: 2, repeat: nil), "details")
        // Toggling the task off drops the checkbox and shrinks the rings.
        try round(.setTask(ids: ["leafA"], isTask: false), "task off")
        // A wholesale task-value snapshot through the same path.
        try round(
            .setTaskValue(id: "leafB", task: NodeTask(done: true)), "task value")

        // Tags: assignment, multi-select reassignment, removal.
        try round(.toggleTag(ids: ["leafA", "leafB"], tagID: "t-urgent", assigned: true), "tag on")
        try round(.setNodeTags(id: "leafA", tags: nil), "node tags cleared")
        // Definition edits fall back to the full rebuild (`dirtyIDs`
        // returns nil) — the rename re-labels every pill that carries it.
        let renamed = Tag(id: "t-urgent", name: "critical", color: "#E5484D")
        let tagsCommand = MapCommand.updateTag(renamed, in: model)
        #expect(
            SceneGeometry.dirtyIDs(for: tagsCommand, in: model) == nil,
            "definition edits take the full-rebuild fallback")
        try round(tagsCommand, "tag renamed")

        // Notes and links: badge decorations change the node's own size.
        try round(.setNote(id: "leafB", note: "A two\nline note"), "note on")
        try round(.setLink(id: "leafB", link: "https://example.com"), "link on")
        try round(.setNote(id: "leafB", note: "  "), "whitespace note clears")
        try round(.setLink(id: "leafB", link: nil), "link off")

        // M3 media (F-CNT-2/3/5/7/8): every one is a decoration or a
        // layout input of the node itself — the command-derived dirty
        // set must keep incremental == full.
        try round(
            .setImage(
                id: "leafB", image: NodeImage(asset: "aabb.png", size: [60, 30], placement: .below)),
            "image on")
        try round(.setImage(id: "leafB", image: nil), "image off")
        try round(
            .setMarkers(id: "leafB", markers: ["sf:star.fill", "sticker:priority-2"]), "markers on")
        try round(
            .setMarkers(id: "leafB", markers: ["sticker:priority-2"]), "markers shrink")
        try round(.setMarkers(id: "leafB", markers: nil), "markers off")
        try round(
            .setAttachments(
                id: "leafB", attachments: [Attachment(asset: "ccdd.pdf", name: "Paper.pdf")]),
            "attachment on")
        try round(
            .setSource(
                id: "leafB", source: SourceRef(url: "https://example.com", page: 3)),
            "source on")
        try round(.setMath(id: "leafB", math: true), "math on")
        try round(.setMath(id: "leafB", math: nil), "math off")
        // Saved filters are document state, not a layout input.
        try round(
            .setFilters([SavedFilter(id: "f1", name: "Has Image", query: "has:image")]),
            "saved filter")

        // The rings survived the whole sequence.
        let final = SceneGeometry.update(
            model: model, cache: cache, variant: .light, measurer: measurer, dirty: [])
        guard case .progress(let completed, let total)? = final.nodes["mid"]?.decorations?.task
        else {
            Issue.record("mid lost its ring after the sequence")
            return
        }
        #expect(completed == 1)
        #expect(total == 1)
    }

    /// Structural edits under tasks: deleting, moving or restoring a task
    /// subtree changes the rings of every ancestor — far beyond the
    /// command's own dirty set. The update diffs the progress index so
    /// the rings above stay exact.
    @Test func structuralEditsUnderTasksKeepAncestorRingsExact() throws {
        let measurer = TextMeasurer()
        var model = contentModel()
        model.nodes["leafA"]?.task = NodeTask(done: true)
        model.nodes["leafB"]?.task = NodeTask()
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        func round(_ command: MapCommand, _ comment: String) throws {
            let inverse = try command.inverse(in: model)
            for step in [command, inverse] {
                var edited = model
                try step.apply(to: &edited)
                let full = SceneGeometry.build(model: edited, variant: .light, measurer: measurer)
                if let dirty = SceneGeometry.dirtyIDs(for: step, in: edited) {
                    let incremental = SceneGeometry.update(
                        model: edited, cache: cache, variant: .light, measurer: measurer,
                        dirty: dirty)
                    assertScenesEqual(incremental, full, comment)
                } else {
                    _ = SceneGeometry.build(
                        model: edited, cache: cache, variant: .light, measurer: measurer)
                }
                model = edited
            }
        }

        // Deleting the done leaf drops `root`'s ring from 1/2 to 0/1 —
        // `root` is not in the delete's own dirty set — and the undo
        // restores it.
        try round(.deleteSubtrees(ids: ["leafA"]), "delete task leaf")
        // Moving a task leaf up to the root changes both rings.
        try round(.moveNode(id: "leafB", parent: "root", index: 0), "move task leaf")
    }

    /// The ancestor chain rule: a task toggle on a leaf must dirty the
    /// leaf **and** every ancestor (each ring is a leading decoration,
    /// so each ring node's own size changed).
    @Test func taskTogglesDirtyTheWholeAncestorChain() throws {
        let date = Date(timeIntervalSince1970: 1)
        var model = MapModel.emptyDocument(docID: "chain")
        for (id, parent) in [("root", nil), ("mid", "root"), ("leaf", "mid")] {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: id), created: date, modified: date)
        }
        model.nodes["root"]?.children = ["mid"]
        model.nodes["mid"]?.children = ["leaf"]
        model.roots = ["root"]

        let toggle = MapCommand.setTask(ids: ["leaf"], isTask: true)
        try toggle.apply(to: &model)
        #expect(
            SceneGeometry.dirtyIDs(for: toggle, in: model) == ["leaf", "mid", "root"],
            "a task toggle dirties the node plus its whole ancestor chain")

        let done = MapCommand.setTaskDone(ids: ["leaf"], done: true)
        try done.apply(to: &model)
        #expect(
            SceneGeometry.dirtyIDs(for: done, in: model) == ["leaf", "mid", "root"])
    }
    @Test func dirtyIDsCoverEveryCommandKind() throws {
        let date = Date(timeIntervalSince1970: 1)
        var model = MapModel.emptyDocument(docID: "dirty")
        var root = Node(id: "root", title: NodeTitle(text: "Root"), created: date, modified: date)
        let child = Node(id: "child", parent: "root", created: date, modified: date)
        root.children = ["child"]
        model.nodes["root"] = root
        model.nodes["child"] = child
        model.roots = ["root"]

        let leaf = Node(id: "leaf", title: NodeTitle(text: "x"), created: date, modified: date)
        let known: [MapCommand] = [
            .editText(id: "child", title: NodeTitle(text: "t")),
            .addChild(parent: "root", index: nil, node: leaf),
            .addSibling(anchor: "child", before: false, node: leaf),
            .insertParent(anchor: "child", node: leaf),
            .addRoot(index: nil, node: leaf),
            .deleteSubtrees(ids: ["child"]),
            .deleteNodePromotingChildren(id: "child"),
            .moveNode(id: "child", parent: "root", index: 0),
            .reorderSibling(id: "child", delta: 1),
            .promote(id: "child"),
            .demote(id: "child"),
            .detach(id: "child"),
            .insertSubtrees(mapping: ["leaf": leaf], anchors: [InsertionAnchor(id: "leaf", parent: "root", index: 0)]),
            .group(name: "G", commands: [.editText(id: "child", title: NodeTitle(text: "t"))]),
            .setSide(id: "child", side: .left),
            .setFolded(id: "child", folded: true),
            .setOffset(id: "child", offset: ModelOffset(x: 1, y: 1)),
            .setConnections(nil),
            .setBoundaries(nil),
            .setSummaries(nil),
            .setLink(id: "child", link: "https://example.com"),
            .setTask(ids: ["child"], isTask: true),
            .setTaskDone(ids: ["child"], done: true),
            .setTaskDetails(id: "child", due: nil, priority: nil, repeat: nil),
            .setTaskValue(id: "child", task: nil),
            .toggleTag(ids: ["child"], tagID: "t", assigned: true),
            .setNodeTags(id: "child", tags: nil),
            // M3 media commands (F-CNT-2/3/5/7/8).
            .setImage(id: "child", image: NodeImage(asset: "x.png", size: [40, 20])),
            .setMarkers(id: "child", markers: ["sticker:priority-1"]),
            .setAttachments(id: "child", attachments: [Attachment(asset: "y.pdf", name: "Y.pdf")]),
            .setSource(id: "child", source: SourceRef(url: "https://example.com")),
            .setMath(id: "child", math: true),
            .setFilters([SavedFilter(id: "f", name: "n", query: "is:task")]),
        ]
        for command in known {
            #expect(
                SceneGeometry.dirtyIDs(for: command, in: model) != nil,
                "\(command.displayName) must map to a dirty set")
        }
        // Definition edits are the one deliberate exception: a tag
        // rename/recolor/delete can touch any carrier node, so they map
        // to `nil` and the host takes the full-rebuild fallback.
        #expect(SceneGeometry.dirtyIDs(for: MapCommand.setTags(nil), in: model) == nil)
        // A group with an unknown member (self-referential stand-in) is
        // still recognized; the point is that a *future* command kind
        // added without a dirtyIDs case returns nil. Cover the present
        // explicitly: every case above maps.
    }
}
