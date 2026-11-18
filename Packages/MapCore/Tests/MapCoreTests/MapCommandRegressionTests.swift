import Foundation
import Testing

@testable import MapCore

/// Regression tests for the review on PR #3: every case here was a probe
/// that found a bug.
struct MapCommandRegressionTests {
    private func linearModel(_ titles: [String]) -> MapModel {
        var model = MapModel.emptyDocument(docID: "regression")
        model.nodes["n0"] = Node(
            id: "n0", title: NodeTitle(text: "root"), created: fixedDate, modified: fixedDate)
        model.roots = ["n0"]
        for (index, title) in titles.enumerated() {
            let id = "n\(index + 1)"
            model.nodes[id] = Node(
                id: id, parent: "n0", title: NodeTitle(text: title),
                created: fixedDate, modified: fixedDate)
            model.nodes["n0"]?.children.append(id)
        }
        return model
    }

    @Test func multiNodeDeleteUndoPreservesSiblingOrder() throws {
        var model = linearModel(["n1", "n2", "n3", "n4"])
        let delete = MapCommand.deleteSubtrees(ids: ["n3", "n1"])
        let undo = try delete.inverse(in: model)
        try delete.apply(to: &model)
        #expect(model.nodes["n0"]?.children == ["n2", "n4"])

        try undo.apply(to: &model)
        #expect(model.nodes["n0"]?.children == ["n1", "n2", "n3", "n4"])
        #expect(model == linearModel(["n1", "n2", "n3", "n4"]))
    }

    @Test func overlappingDeleteUndoDoesNotDuplicateChildren() throws {
        var model = linearModel(["branch"])
        model.nodes["n1"]?.children = ["n1a", "n1b"]
        model.nodes["n1a"] = Node(
            id: "n1a", parent: "n1", title: NodeTitle(text: "a"), created: fixedDate, modified: fixedDate)
        model.nodes["n1b"] = Node(
            id: "n1b", parent: "n1", title: NodeTitle(text: "b"), created: fixedDate, modified: fixedDate)

        let delete = MapCommand.deleteSubtrees(ids: ["n1a", "n1"])
        let undo = try delete.inverse(in: model)
        try delete.apply(to: &model)
        #expect(model.nodes["n1a"] == nil)
        #expect(model.nodes["n1"] == nil)

        try undo.apply(to: &model)
        #expect(model.nodes["n1"]?.children == ["n1a", "n1b"])
        #expect(MapValidator.validate(model).isEmpty)
    }

    @Test func duplicateIdsInDeleteUndoExactlyOnce() throws {
        var model = linearModel(["n1", "n2", "n3", "n4"])
        let original = model

        let delete = MapCommand.deleteSubtrees(ids: ["n2", "n2"])
        let undo = try delete.inverse(in: model)
        try delete.apply(to: &model)
        #expect(model.nodes["n0"]?.children == ["n1", "n3", "n4"])

        try undo.apply(to: &model)
        #expect(model == original)
        #expect(MapValidator.validate(model).isEmpty)
    }

    @Test func movesThatBreakSummariesPurgeAndRestoreThem() throws {
        var model = linearModel(["a", "b", "c"])
        let rootChildren = model.nodes["n0"]!.children
        model.summaries = [
            Summary(id: "sm-0", parent: "n0", range: [rootChildren[0], rootChildren[1]], node: rootChildren[2])
        ]
        let original = model

        let move = MapCommand.moveNode(id: rootChildren[0], parent: "n0", index: 0)
        let moveAway = MapCommand.moveNode(id: rootChildren[1], parent: "n1", index: 0)
        let undo = try moveAway.inverse(in: model)
        try move.apply(to: &model)
        try moveAway.apply(to: &model)

        #expect(model.summaries?.isEmpty != false)
        #expect(MapValidator.validate(model).isEmpty)

        try undo.apply(to: &model)
        #expect(model.summaries == original.summaries)
    }

    @Test func failingGroupLeavesModelUntouched() throws {
        let model = linearModel(["a", "b"])
        let failing = MapCommand.group(
            name: "Failing",
            commands: [
                .editText(id: "n1", title: NodeTitle(text: "CHANGED")),
                .editText(id: "no-such-node", title: NodeTitle(text: "x")),
            ])
        var working = model
        #expect(throws: ArborError.self) {
            try failing.apply(to: &working)
        }
        #expect(working == model)
    }

    @Test func deletePurgesAndUndoRestoresConnections() throws {
        var model = linearModel(["a", "b"])
        model.connections = [
            Connection(id: "conn-1", from: "n1", to: "n2"),
            Connection(id: "conn-2", from: "n0", to: "n1"),
            Connection(id: "conn-3", from: "n0", to: "n2"),
        ]
        let original = model

        let delete = MapCommand.deleteSubtrees(ids: ["n1"])
        let undo = try delete.inverse(in: model)
        try delete.apply(to: &model)

        #expect(model.connections?.map(\.id) == ["conn-3"])
        #expect(MapValidator.validate(model).isEmpty)

        try undo.apply(to: &model)
        #expect(model.connections == original.connections)
        #expect(model == original)
    }

    @Test func deletePurgesAndUndoRestoresBoundariesAndSummaries() throws {
        var model = linearModel(["a", "b", "c"])
        model.boundaries = [
            Boundary(id: "bd-1", nodes: ["n1", "n2"], title: "scope"),
            Boundary(id: "bd-2", nodes: ["n1"], title: nil),
        ]
        model.summaries = [Summary(id: "sm-1", parent: "n0", range: ["n1", "n2"], node: "n3")]
        let original = model

        let delete = MapCommand.deleteSubtrees(ids: ["n1"])
        let undo = try delete.inverse(in: model)
        try delete.apply(to: &model)

        #expect(model.boundaries?.map(\.id) == ["bd-1"])
        #expect(model.boundaries?.first?.nodes == ["n2"])
        #expect(model.summaries?.isEmpty != false)
        #expect(MapValidator.validate(model).isEmpty)

        try undo.apply(to: &model)
        #expect(model == original)
    }

    @Test func deleteNodePromotingChildrenPurgesSecondaryReferences() throws {
        var model = linearModel(["child-1", "child-2"])
        model.nodes["n1"]?.children = ["n1a"]
        model.nodes["n1a"] = Node(
            id: "n1a", parent: "n1", title: NodeTitle(text: "leaf"), created: fixedDate, modified: fixedDate)
        model.connections = [
            Connection(id: "conn-1", from: "n0", to: "n1a"),
            Connection(id: "conn-2", from: "n2", to: "n1"),
            Connection(id: "conn-3", from: "n0", to: "n2"),
        ]
        let original = model

        let delete = MapCommand.deleteNodePromotingChildren(id: "n1")
        let undo = try delete.inverse(in: model)
        try delete.apply(to: &model)

        #expect(model.nodes["n1a"]?.parent == "n0")
        #expect(model.nodes["n0"]?.children.contains("n1a") == true)
        #expect(model.connections?.map(\.id) == ["conn-1", "conn-3"])
        #expect(MapValidator.validate(model).isEmpty)

        try undo.apply(to: &model)
        #expect(model == original)
    }

    @Test func leafCreationIgnoresPayloadChildrenAndSide() throws {
        var model = linearModel(["a"])
        var payload = Node(id: "new", title: NodeTitle(text: "new"))
        payload.children = ["ghost-child"]
        payload.side = .left

        try MapCommand.addChild(parent: "n0", index: nil, node: payload).apply(to: &model)
        #expect(model.nodes["new"]?.children.isEmpty == true)
        #expect(MapValidator.validate(model).isEmpty)

        var rootPayload = Node(id: "fresh-root", title: NodeTitle(text: "root2"))
        rootPayload.children = ["ghost"]
        rootPayload.side = .right
        try MapCommand.addRoot(index: nil, node: rootPayload).apply(to: &model)
        #expect(model.nodes["fresh-root"]?.side == nil)
        #expect(MapValidator.validate(model).isEmpty)

        var siblingPayload = Node(id: "sib", title: NodeTitle(text: "sib"))
        siblingPayload.children = ["ghost"]
        try MapCommand.addSibling(anchor: "n0", before: false, node: siblingPayload).apply(to: &model)
        #expect(MapValidator.validate(model).isEmpty)
    }

    @Test func duplicateGetsFreshIdentity() throws {
        var model = linearModel(["a"])
        model.nodes["n1"]?.study = NodeStudy(
            card: .on, fsrs: FSRSState(due: fixedDate, reps: 5, state: .review))
        model.nodes["n1"]?.created = fixedDate

        let command = try MapCommand.duplicate(id: "n1", in: model)
        try command.apply(to: &model)

        let copyID = model.nodes["n0"]!.children.last!
        let copy = model.nodes[copyID]!
        #expect(copy.id != "n1")
        #expect(copy.study?.fsrs == nil)
        #expect(copy.created != fixedDate)
    }
}
