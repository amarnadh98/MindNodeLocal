import Foundation
import Testing

@testable import MapCore

/// ADR-0009: level-1 nodes keep a persistent palette index, so
/// reordering, moving or deleting siblings never recolors a branch, and
/// new level-1 nodes take the next unused index. F-STY-8's Recolor
/// Branches and F-STY-4's theme selection are undoable commands with
/// exact inverses.
struct PaletteIndexTests {
    private func paletteModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "palette")
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "root"), created: fixedDate, modified: fixedDate)
        model.roots = [rootID]
        let indices: [(String, Int?)] = [
            ("branch-a", 0), ("branch-b", 1), ("branch-c", 2),
        ]
        for (id, index) in indices {
            model.nodes[id] = Node(
                id: id, parent: rootID, title: NodeTitle(text: id), paletteIndex: index,
                created: fixedDate, modified: fixedDate)
            model.nodes[rootID]?.children.append(id)
        }
        return model
    }

    @Test func newLevelOneNodesTakeTheNextUnusedIndex() throws {
        var model = paletteModel()
        // 0, 1 and 2 are taken: the next fresh branch takes 3.
        try MapCommand.addChild(
            parent: "root", index: nil,
            node: Node(id: "branch-d", title: NodeTitle(text: "d"))
        ).apply(to: &model)
        #expect(model.nodes["branch-d"]?.paletteIndex == 3)

        // A gap (delete branch-b) is filled before anything higher.
        try MapCommand.deleteSubtrees(ids: ["branch-b"]).apply(to: &model)
        try MapCommand.addChild(
            parent: "root", index: nil,
            node: Node(id: "branch-e", title: NodeTitle(text: "e"))
        ).apply(to: &model)
        #expect(model.nodes["branch-e"]?.paletteIndex == 1)

        // Deeper nodes never gain an index.
        try MapCommand.addChild(
            parent: "branch-a", index: nil,
            node: Node(id: "leaf-a", title: NodeTitle(text: "leaf"))
        ).apply(to: &model)
        #expect(model.nodes["leaf-a"]?.paletteIndex == nil)

        // Nor do new roots.
        try MapCommand.addRoot(index: nil, node: Node(id: "root-2")).apply(to: &model)
        #expect(model.nodes["root-2"]?.paletteIndex == nil)
    }

    @Test func payloadIndicesSurviveCreationCommands() throws {
        var model = paletteModel()
        try MapCommand.addChild(
            parent: "root", index: nil,
            node: Node(id: "carried", title: NodeTitle(text: "carried"), paletteIndex: 5)
        ).apply(to: &model)
        #expect(model.nodes["carried"]?.paletteIndex == 5)

        try MapCommand.insertParent(
            anchor: "branch-a",
            node: Node(id: "wrapper", title: NodeTitle(text: "wrapper"))
        ).apply(to: &model)
        #expect(model.nodes["wrapper"]?.paletteIndex == 3)
    }

    @Test func reorderKeepsEveryStoredIndex() throws {
        var model = paletteModel()
        let before = storedIndices(model)
        try MapCommand.reorderSibling(id: "branch-b", delta: 1).apply(to: &model)
        try MapCommand.reorderSibling(id: "branch-c", delta: -2).apply(to: &model)
        #expect(model.nodes["root"]?.children == ["branch-c", "branch-a", "branch-b"])
        #expect(storedIndices(model) == before)
    }

    @Test func moveKeepsEveryStoredIndex() throws {
        var model = paletteModel()
        model.nodes["second-root"] = Node(id: "second-root", title: NodeTitle(text: "two"))
        model.roots.append("second-root")
        try MapCommand.moveNode(id: "branch-b", parent: "second-root", index: 0)
            .apply(to: &model)
        #expect(model.nodes["branch-b"]?.paletteIndex == 1)
        #expect(model.nodes["branch-a"]?.paletteIndex == 0)
        #expect(model.nodes["branch-c"]?.paletteIndex == 2)
    }

    @Test func deleteKeepsEveryStoredIndex() throws {
        var model = paletteModel()
        try MapCommand.deleteSubtrees(ids: ["branch-b"]).apply(to: &model)
        #expect(model.nodes["branch-a"]?.paletteIndex == 0)
        #expect(model.nodes["branch-c"]?.paletteIndex == 2)
    }

    @Test func nextPaletteIndexSkipsUsedIndices() {
        var model = MapModel.emptyDocument()
        let rootID = "root"
        model.nodes[rootID] = Node(id: rootID)
        model.roots = [rootID]
        for (id, index) in [("a", 0), ("b", 2), ("c", 5)] {
            model.nodes[id] = Node(id: id, parent: rootID, paletteIndex: index)
            model.nodes[rootID]?.children.append(id)
        }
        #expect(model.nextPaletteIndex(forChildOf: rootID) == 1)
    }

    @Test func recolorBranchesRotatesSiblingIndicesAndInvertsExactly() throws {
        var model = paletteModel()
        let rotate = MapCommand.recolorBranches(rootID: "root", in: model)
        let undo = try rotate.inverse(in: model)
        try rotate.apply(to: &model)
        #expect(model.nodes["branch-a"]?.paletteIndex == 1)
        #expect(model.nodes["branch-b"]?.paletteIndex == 2)
        #expect(model.nodes["branch-c"]?.paletteIndex == 0)

        var restored = model
        try undo.apply(to: &restored)
        #expect(storedIndices(restored) == storedIndices(paletteModel()))
    }

    @Test func recolorBranchesInvertsExactlyAcrossNilIndices() throws {
        var model = paletteModel()
        // A missing index must round-trip back to nil, not to a number.
        model.nodes["branch-a"]?.paletteIndex = nil
        let rotate = MapCommand.recolorBranches(rootID: "root", in: model)
        let undo = try rotate.inverse(in: model)
        try rotate.apply(to: &model)
        #expect(model.nodes["branch-a"]?.paletteIndex == 1)
        #expect(model.nodes["branch-b"]?.paletteIndex == 2)
        #expect(model.nodes["branch-c"]?.paletteIndex == nil)

        var restored = model
        try undo.apply(to: &restored)
        #expect(restored.nodes["branch-a"]?.paletteIndex == nil)
        #expect(restored.nodes["branch-b"]?.paletteIndex == 1)
        #expect(restored.nodes["branch-c"]?.paletteIndex == 2)
    }

    @Test func recolorBranchesOnMissingNodeThrowsAllOrNothing() {
        var model = paletteModel()
        let command = MapCommand.recolorBranches(
            assignments: [
                PaletteIndexAssignment(id: "branch-a", index: 4),
                PaletteIndexAssignment(id: "ghost", index: 0),
            ])
        #expect(throws: ArborError.self) {
            try command.apply(to: &model)
        }
        #expect(model.nodes["branch-a"]?.paletteIndex == 0)
    }

    @Test func setThemeAppliesAndInvertsExactly() throws {
        var model = paletteModel()
        model.theme = ThemeSelection(id: "paper", overrides: ThemePatch(baseFont: "Georgia"))

        let change = MapCommand.setTheme(id: "ocean")
        let undo = try change.inverse(in: model)
        try change.apply(to: &model)
        #expect(model.theme == ThemeSelection(id: "ocean", overrides: ThemePatch(baseFont: "Georgia")))

        try undo.apply(to: &model)
        #expect(model.theme == ThemeSelection(id: "paper", overrides: ThemePatch(baseFont: "Georgia")))

        // nil restores a document with no stored theme selection.
        var fresh = paletteModel()
        try MapCommand.setTheme(id: "study").apply(to: &fresh)
        let freshUndo = try MapCommand.setTheme(id: "study").inverse(in: paletteModel())
        try freshUndo.apply(to: &fresh)
        #expect(fresh.theme == nil)
    }

    @Test func setThemeDisplayNameFeedsTheUndoMenu() {
        #expect(MapCommand.setTheme(id: "ocean").displayName == "Set Theme")
        #expect(MapCommand.recolorBranches(assignments: []).displayName == "Recolor Branches")
    }

    @Test func paletteIndexRoundTripsThroughMapJSON() throws {
        var model = paletteModel()
        model.nodes["branch-a"]?.style = NodeStylePatch(fill: "#E5484D")
        let roundTripped = try MapDocumentCoder.roundTrip(model)
        #expect(roundTripped == model)
        #expect(roundTripped.nodes["branch-b"]?.paletteIndex == 1)
    }

    private func storedIndices(_ model: MapModel) -> [String: Int?] {
        var result: [String: Int?] = [:]
        for (id, node) in model.nodes {
            result[id] = node.paletteIndex
        }
        return result
    }
}
