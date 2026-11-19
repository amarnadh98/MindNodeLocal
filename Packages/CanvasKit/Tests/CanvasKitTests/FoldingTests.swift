import Foundation
import MapCore
import Testing

@testable import CanvasKit

private let foldDate = Date(timeIntervalSince1970: 1_800_000_000)

/// r (depth 1) ─ c1 leaf, c2 ─ g1 (depth 3) ─ gg1 (depth 4).
private func foldableModel() -> MapModel {
    var model = MapModel.emptyDocument(docID: "fold")
    for (id, parent) in [
        ("r", nil as String?), ("c1", "r"), ("c2", "r"), ("g1", "c2"), ("gg1", "g1"),
    ] {
        model.nodes[id] = Node(id: id, parent: parent, title: NodeTitle(text: id))
        if let parent {
            model.nodes[parent]?.children.append(id)
        } else {
            model.roots.append(id)
        }
    }
    return model
}

/// Applies `command` to a copy of `model` and returns the ids left folded.
private func foldedIDs(after command: MapCommand, in model: MapModel) throws -> Set<String> {
    var working = model
    try command.apply(to: &working)
    return Set(working.nodes.filter(\.value.folded).keys)
}

/// The pure fold-command builders (F-LAY-14): every menu action is ONE
/// command — bare or grouped, one undo step — or nil when the map is
/// already in the requested state, and no-op presses never register an
/// undo step.
@Suite
struct FoldingShowLevelsTests {
    @Test func levelOneFoldsEveryInnerNode() throws {
        let command = try #require(Folding.showLevelsCommand(levels: 1, in: foldableModel()))
        // Only the root row stays visible: every deeper inner node folds.
        #expect(try foldedIDs(after: command, in: foldableModel()) == ["r", "c2", "g1"])
    }

    @Test func levelThreeOnlyFoldsBelowLevelThree() throws {
        let command = try #require(Folding.showLevelsCommand(levels: 3, in: foldableModel()))
        #expect(try foldedIDs(after: command, in: foldableModel()) == ["g1"])
    }

    @Test func levelZeroUnfoldsEverything() throws {
        var model = foldableModel()
        model.nodes["c2"]?.folded = true
        model.nodes["r"]?.folded = true
        let command = try #require(Folding.showLevelsCommand(levels: 0, in: model))
        #expect(try foldedIDs(after: command, in: model) == [])
    }

    @Test func anAlreadyShownLevelEmitsNoCommand() {
        var model = foldableModel()
        for id in ["r", "c2", "g1"] {
            model.nodes[id]?.folded = true
        }
        #expect(Folding.showLevelsCommand(levels: 1, in: model) == nil)
    }

    @Test func theCommandIsGroupedSoUndoSeesOneStep() throws {
        // Two changes (c2, g1 at level 2, plus nothing else) must arrive
        // as ONE group command, not a list.
        let command = try #require(Folding.showLevelsCommand(levels: 2, in: foldableModel()))
        guard case .group(_, let commands) = command else {
            Issue.record("expected a grouped command")
            return
        }
        #expect(commands.count == 2)
    }
}

@Suite
struct FoldingToggleWithSiblingsTests {
    @Test func anyUnfoldedSiblingFoldsTheWholeGroup() throws {
        // c1 (a leaf) carries the selection; its foldable sibling c2
        // folds with it.
        let command = try #require(
            Folding.toggleWithSiblingsCommand(selection: ["c1"], in: foldableModel()))
        #expect(try foldedIDs(after: command, in: foldableModel()) == ["c2"])
    }

    @Test func aFoldedGroupUnfoldsTogether() throws {
        var model = foldableModel()
        model.nodes["c1"]?.folded = true
        model.nodes["c2"]?.folded = true
        let command = try #require(
            Folding.toggleWithSiblingsCommand(selection: ["c1"], in: model))
        #expect(try foldedIDs(after: command, in: model) == [])
    }

    @Test func mixedGroupsFoldAndRootsFormTheirOwnGroup() throws {
        var model = foldableModel()
        model.roots.append("r2")
        model.nodes["r2"] = Node(id: "r2", title: NodeTitle(text: "r2"), created: foldDate)
        // Two groups touched (the roots and c1/c2's parent group): both
        // fold in one grouped command. g1 is a child of c2, not a
        // sibling, and r2 is a leaf, so neither changes.
        let command = try #require(
            Folding.toggleWithSiblingsCommand(selection: ["r", "c2"], in: model))
        guard case .group = command else {
            Issue.record("expected a grouped command")
            return
        }
        #expect(try foldedIDs(after: command, in: model) == ["r", "c2"])
    }

    @Test func twoSelectionsInOneGroupVisitItOnce() throws {
        // Siblings c1 and c2 share one group: the group is visited once
        // and the result is ONE bare command (no phantom grouping).
        let command = try #require(
            Folding.toggleWithSiblingsCommand(selection: ["c1", "c2"], in: foldableModel()))
        guard case .setFolded(let id, let folded) = command else {
            Issue.record("expected a single bare setFolded command")
            return
        }
        #expect(id == "c2")
        #expect(folded)
        #expect(try foldedIDs(after: command, in: foldableModel()) == ["c2"])
    }

    @Test func aGroupWithNothingToChangeEmitsNoCommand() {
        // Nothing selected, or the selection's group is all leaves:
        // no phantom undo step.
        #expect(Folding.toggleWithSiblingsCommand(selection: [], in: foldableModel()) == nil)
        #expect(Folding.toggleWithSiblingsCommand(selection: ["gg1"], in: foldableModel()) == nil)
    }
}

@Suite
struct FoldingUnfoldOneLevelTests {
    @Test func unfoldsOnlyTheSelectedFoldedNodes() throws {
        var model = foldableModel()
        model.nodes["c2"]?.folded = true
        model.nodes["r"]?.folded = true
        let command = try #require(Folding.unfoldOneLevelCommand(selection: ["c2", "g1"], in: model))
        // g1 isn't folded (and would unfold nothing): only c2 changes.
        #expect(try foldedIDs(after: command, in: model) == ["r"])
    }

    @Test func nothingFoldedEmitsNoCommand() {
        #expect(Folding.unfoldOneLevelCommand(selection: ["c2"], in: foldableModel()) == nil)
    }
}
