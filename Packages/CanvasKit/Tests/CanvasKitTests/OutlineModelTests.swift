import Foundation
import MapCore
import Testing

@testable import CanvasKit

/// Headless tests for the pure outline layer (F-OUT, SPEC §5.9 and
/// §11.6): the clockwise first-level ordering, the row projection
/// (disclosure mirrors `node.folded`), the split/merge title surgery,
/// and every keyboard / drag-and-drop command builder — each exactly
/// one undoable `MapCommand`, each with an inverse that restores the
/// model exactly.
struct OutlineModelTests {
    // MARK: clockwise first-level order (F-OUT-2)

    @Test func rootsAppearInCreationOrder() {
        let model = Self.model()
        #expect(OutlineModel.displayedChildren(of: nil, in: model, sideOf: Self.resolver(model)) == ["root", "root2"])
    }

    @Test func firstLevelFollowsClockwiseVisualOrder() {
        let model = Self.model()
        // [a(right), b(left), c(right), d(left)] displays as the two
        // right children top→bottom, then the left ones bottom→top.
        #expect(
            OutlineModel.displayedChildren(of: "root", in: model, sideOf: Self.resolver(model))
                == ["a", "c", "d", "b"])
    }

    @Test func singleSidedRootKeepsModelOrder() {
        let model = Self.model()
        // root2's children are all pinned left: one side, model order.
        #expect(
            OutlineModel.displayedChildren(of: "root2", in: model, sideOf: Self.resolver(model))
                == ["x", "y"])
        // Deeper levels are never permuted.
        #expect(
            OutlineModel.displayedChildren(of: "b", in: model, sideOf: Self.resolver(model))
                == ["b1", "b2"])
    }

    @Test func rowsProjectDepthFirstAndHideFoldedChildren() throws {
        var model = Self.model()
        try MapCommand.setFolded(id: "a", folded: true).apply(to: &model)
        let rows = OutlineModel.rows(in: model, sideOf: Self.resolver(model))
        #expect(rows.map(\.id) == ["root", "a", "c", "d", "b", "b1", "b2", "root2", "x", "y"])
        #expect(rows.map(\.depth) == [0, 1, 1, 1, 1, 2, 2, 0, 1, 1])
    }

    @Test func previousRowAndSiblingFollowDisplayedOrder() {
        let model = Self.model()
        let sideOf = Self.resolver(model)
        // The row above "b" (left side, displayed last) is "d".
        #expect(OutlineModel.previousRow(before: "b", in: model, sideOf: sideOf)?.id == "d")
        // The previous displayed sibling of "b" is "d", not the model
        // neighbour "a".
        #expect(OutlineModel.previousDisplayedSibling(of: "b", in: model, sideOf: sideOf) == "d")
        #expect(OutlineModel.previousDisplayedSibling(of: "a", in: model, sideOf: sideOf) == nil)
        #expect(OutlineModel.previousRow(before: "root", in: model, sideOf: sideOf) == nil)
        #expect(OutlineModel.adjacentRow(to: "d", downward: false, in: model, sideOf: sideOf) == "c")
    }

    // MARK: title surgery

    @Test func splitTitleCutsTextAndRuns() {
        let title = NodeTitle(
            text: "Hello Brave World",
            runs: [
                Run(range: [0, 11], bold: true),
                Run(range: [12, 5], italic: true),
            ])
        let (head, tail) = OutlineCommands.split(title: title, at: 6)
        #expect(head.text == "Hello ")
        #expect(head.runs == [Run(range: [0, 6], bold: true)])
        #expect(tail.text == "Brave World")
        #expect(tail.runs == [Run(range: [0, 5], bold: true), Run(range: [6, 5], italic: true)])
    }

    @Test func appendShiftsRunsByTheLeftLength() {
        let merged = OutlineCommands.appended(
            NodeTitle(text: "First", runs: [Run(range: [0, 5], bold: true)]),
            NodeTitle(text: "Second", runs: [Run(range: [1, 3], italic: true)]))
        #expect(merged.text == "FirstSecond")
        #expect(merged.runs == [Run(range: [0, 5], bold: true), Run(range: [6, 3], italic: true)])
    }

    // MARK: ⏎ split (F-OUT-3)

    @Test func splitCommandSplitsAtCaretAndFullyUndoes() throws {
        let model = Self.model()
        let action = try #require(
            OutlineCommands.splitCommand(
                id: "a", caret: 6, draft: NodeTitle(text: "Hello Brave", runs: [Run(range: [0, 5], bold: true)]),
                in: model))
        #expect(action.caret == nil)

        let inverse = try action.command.inverse(in: model)
        var working = model
        try action.command.apply(to: &working)

        #expect(working.nodes["a"]?.title.text == "Hello ")
        #expect(working.nodes["a"]?.title.runs == [Run(range: [0, 5], bold: true)])
        #expect(working.nodes[action.focus]?.parent == "root")
        #expect(working.nodes["root"]?.children == ["a", action.focus, "b", "c", "d"])
        #expect(working.nodes[action.focus]?.title.text == "Brave")

        try inverse.apply(to: &working)
        #expect(working == model)
    }

    @Test func splitAtEndCreatesAnEmptyRowBelowWithoutEditingText() throws {
        let model = Self.model()
        let action = try #require(
            OutlineCommands.splitCommand(
                id: "a", caret: 6, draft: NodeTitle(text: "root-a"), in: model))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["a"]?.title.text == "root-a")
        #expect(working.nodes[action.focus]?.title.text.isEmpty == true)
        // A bare addSibling, not a group.
        if case .addSibling = action.command {
            // expected
        } else {
            Issue.record("expected a bare addSibling, got \(action.command)")
        }
    }

    @Test func splitOfARootCreatesTheNextRootSection() throws {
        let model = Self.model()
        let action = try #require(
            OutlineCommands.splitCommand(
                id: "root2", caret: ("" as NSString).length, draft: NodeTitle(text: ""), in: model))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.roots == ["root", "root2", action.focus])
    }

    // MARK: ⌫ merge (F-OUT-3)

    @Test func mergeCommandAppendsTitleRunsAndChildrenAndUndoes() throws {
        let model = Self.model()
        let action = try #require(
            OutlineCommands.mergeCommand(
                id: "b", draft: NodeTitle(text: " plus", runs: [Run(range: [1, 4], italic: true)]),
                in: model, sideOf: Self.resolver(model)))
        #expect(action.focus == "d")
        #expect(action.caret == 6)

        let inverse = try action.command.inverse(in: model)
        var working = model
        try action.command.apply(to: &working)

        #expect(working.nodes["d"]?.title.text == "root-d plus")
        #expect(
            working.nodes["d"]?.title.runs
                == [Run(range: [7, 4], italic: true)])
        // b's children moved under the merge target.
        #expect(working.nodes["d"]?.children == ["b1", "b2"])
        #expect(working.nodes["b1"]?.parent == "d")
        #expect(working.nodes["b"] == nil)
        #expect(working.nodes["root"]?.children == ["a", "c", "d"])

        try inverse.apply(to: &working)
        #expect(working == model)
    }

    @Test func mergeOfTheFirstRowIsANoOp() {
        let model = Self.model()
        #expect(
            OutlineCommands.mergeCommand(
                id: "root", draft: NodeTitle(text: "x"), in: model, sideOf: Self.resolver(model))
                == nil)
    }

    // MARK: ⇥ / ⇧⇥ indent & outdent (F-OUT-3)

    @Test func indentNestsUnderThePreviousDisplayedSibling() throws {
        let model = Self.model()
        // "b" is left-side: its previous displayed sibling is "d".
        let action = try #require(
            OutlineCommands.indentCommand(id: "b", in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["b"]?.parent == "d")
        #expect(working.nodes["d"]?.children == ["b"])
        // The indented row keeps its own subtree.
        #expect(working.nodes["b"]?.children == ["b1", "b2"])
    }

    @Test func indentUnfoldsAFoldedTargetInTheSameStep() throws {
        var model = Self.model()
        try MapCommand.setFolded(id: "a", folded: true).apply(to: &model)
        let action = try #require(
            OutlineCommands.indentCommand(id: "c", in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["c"]?.parent == "a")
        #expect(working.nodes["a"]?.folded == false)
        #expect(working.nodes["a"]?.children.last == "c")
    }

    @Test func indentOfAFirstRowIsANoOp() {
        let model = Self.model()
        #expect(OutlineCommands.indentCommand(id: "a", in: model, sideOf: Self.resolver(model)) == nil)
        #expect(OutlineCommands.indentCommand(id: "root", in: model, sideOf: Self.resolver(model)) == nil)
    }

    @Test func outdentPromotesTheRow() throws {
        let model = Self.model()
        let action = try #require(OutlineCommands.outdentCommand(id: "b1", in: model))
        #expect(action.command == .promote(id: "b1"))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["b1"]?.parent == "root")
        #expect(OutlineCommands.outdentCommand(id: "root", in: model) == nil)
    }

    // MARK: ⌘↑ / ⌘↓ move (F-OUT-3)

    @Test func moveDownWithinTheRightSide() throws {
        let model = Self.model()
        let action = try #require(
            OutlineCommands.moveCommand(id: "a", downward: true, in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["root"]?.children == ["b", "c", "a", "d"])
        // Displayed: "a" swapped below "c" (F-OUT-3's ⌘↓).
        #expect(
            OutlineModel.displayedChildren(of: "root", in: working, sideOf: Self.resolver(working))
                == ["c", "a", "d", "b"])
    }

    @Test func moveWithinTheLeftSideUsesDisplayedOrder() throws {
        // Left children display bottom→top: moving "d" down must land
        // it *below* "b" in displayed order, i.e. earlier in the model.
        let model = Self.model()
        let action = try #require(
            OutlineCommands.moveCommand(id: "d", downward: true, in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["root"]?.children == ["a", "d", "b", "c"])
        #expect(
            OutlineModel.displayedChildren(of: "root", in: working, sideOf: Self.resolver(working))
                == ["a", "c", "b", "d"])
    }

    @Test func moveAcrossTheSideBoundaryPinsTheSide() throws {
        let model = Self.model()
        // "c" is the last right child; moving it down crosses onto the
        // left side — one grouped step pins it left and lands it after
        // "d" in displayed order.
        let action = try #require(
            OutlineCommands.moveCommand(id: "c", downward: true, in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["c"]?.side == .left)
        #expect(
            OutlineModel.displayedChildren(of: "root", in: working, sideOf: Self.resolver(working))
                == ["a", "d", "c", "b"])
    }

    @Test func moveAtTheDisplayedEdgesIsANoOp() {
        let model = Self.model()
        let sideOf = Self.resolver(model)
        // "a" is the first displayed row; "b" the last of the group.
        #expect(OutlineCommands.moveCommand(id: "a", downward: false, in: model, sideOf: sideOf) == nil)
        #expect(OutlineCommands.moveCommand(id: "b", downward: true, in: model, sideOf: sideOf) == nil)
        // A no-op move (already in the target slot) registers nothing.
        #expect(OutlineCommands.moveCommand(id: "root", downward: true, in: model, sideOf: sideOf) != nil)
        #expect(OutlineCommands.moveCommand(id: "root2", downward: true, in: model, sideOf: sideOf) == nil)
    }

    // MARK: drag & drop (F-OUT-4)

    @Test func dropAsSiblingInsertsBelowTheTarget() throws {
        let model = Self.model()
        let action = try #require(
            OutlineCommands.dropCommand(
                dragged: "d", target: "a", asChild: false, in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["root"]?.children == ["a", "d", "b", "c"])
    }

    @Test func dropAsChildAppendsAndUnfolds() throws {
        var model = Self.model()
        try MapCommand.setFolded(id: "a", folded: true).apply(to: &model)
        let action = try #require(
            OutlineCommands.dropCommand(
                dragged: "c", target: "a", asChild: true, in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.nodes["c"]?.parent == "a")
        #expect(working.nodes["a"]?.children.last == "c")
        #expect(working.nodes["a"]?.folded == false)
    }

    @Test func dropIntoOwnSubtreeOrNoOpSlotsIsRejected() {
        let model = Self.model()
        let sideOf = Self.resolver(model)
        #expect(
            OutlineCommands.dropCommand(
                dragged: "root", target: "b1", asChild: false, in: model, sideOf: sideOf)
                == nil)
        #expect(
            OutlineCommands.dropCommand(
                dragged: "a", target: "a", asChild: true, in: model, sideOf: sideOf)
                == nil)
        // Dropping "b" after "d" (its current displayed slot) is a no-op.
        #expect(
            OutlineCommands.dropCommand(
                dragged: "b", target: "d", asChild: false, in: model, sideOf: sideOf)
                == nil)
    }

    @Test func dropOntoARootReordersSections() throws {
        let model = Self.model()
        let action = try #require(
            OutlineCommands.dropCommand(
                dragged: "root", target: "root2", asChild: false, in: model, sideOf: Self.resolver(model)))
        var working = model
        try action.command.apply(to: &working)
        #expect(working.roots == ["root2", "root"])
        #expect(working.nodes["root"]?.parent == nil)
    }

    // MARK: fold (F-OUT-3, F-LAY-14)

    @Test func foldCommandSkipsLeavesAndNoOps() {
        let model = Self.model()
        #expect(
            OutlineCommands.foldCommand(id: "b", folded: true, in: model)?.command
                == .setFolded(id: "b", folded: true))
        #expect(OutlineCommands.foldCommand(id: "b1", folded: true, in: model) == nil)
        var folded = model
        try? MapCommand.setFolded(id: "b", folded: true).apply(to: &folded)
        #expect(OutlineCommands.foldCommand(id: "b", folded: true, in: folded) == nil)
    }

    // MARK: randomized outline ↔ map consistency (SPEC §14, M4 exit)

    @Test(arguments: [UInt64(11), UInt64(12), UInt64(13)])
    @MainActor
    func seededRandomEditsKeepTheOutlineConsistentAndUndoRestores(seed: UInt64) throws {
        let store = MapStore(
            model: Self.seededRandomModel(seed: seed), undoManager: Self.freshManager())
        let original = store.model
        var rng = SplitMix64(seed: seed)

        for _ in 0..<500 {
            let command = Self.randomCommand(model: store.model, rng: &rng)
            do {
                try store.perform(command)
            } catch {
                continue
            }
            let rows = OutlineModel.rows(in: store.model, sideOf: OutlineModel.modelSides(in: store.model))
            #expect(
                rows.map(\.id) == Self.independentWalk(store.model).map(\.id),
                "seed \(seed): the projection diverged from a fresh walk")
            #expect(
                rows == Self.independentWalk(store.model),
                "seed \(seed): depths diverged from a fresh walk")
            #expect(Set(rows.map(\.id)).count == rows.count, "seed \(seed): a row appears twice")
        }

        while store.undoManager.canUndo {
            store.undoManager.undo()
        }
        #expect(
            Self.journalNormalized(store.model) == Self.journalNormalized(original),
            "seed \(seed): full undo did not restore the original model")
    }

    /// A walk written independently of `OutlineModel`: recursive DFS,
    /// its own clockwise application, its own folded handling. The
    /// randomized test demands both agree after every store change.
    private static func independentWalk(_ model: MapModel) -> [OutlineRow] {
        var result: [OutlineRow] = []

        func side(_ id: String) -> SidePin? {
            model.nodes[id]?.side ?? .right
        }

        func visit(_ id: String, _ depth: Int) {
            result.append(OutlineRow(id: id, depth: depth))
            guard let node = model.nodes[id], !node.folded else { return }
            let children = node.children
            guard depth == 0 else {
                for child in children { visit(child, depth + 1) }
                return
            }
            let left = children.filter { side($0) == .left }
            let right = children.filter { side($0) != .left }
            if !left.isEmpty && !right.isEmpty {
                for child in right + left.reversed() { visit(child, depth + 1) }
            } else {
                for child in children { visit(child, depth + 1) }
            }
        }

        for root in model.roots { visit(root, 0) }
        return result
    }
}

/// Fixtures and the fuzz harness for the consistency test.
extension OutlineModelTests {
    // MARK: fixtures

    /// Two roots; `root` mixes pinned sides so the clockwise rule has
    /// both regions to work with.
    private static func model() -> MapModel {
        var model = MapModel(docID: "outline")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        func node(
            _ id: String, parent: String? = nil, title: String, side: SidePin? = nil
        ) -> Node {
            var node = Node(id: id, parent: parent, title: NodeTitle(text: title), side: side)
            node.created = stamp
            node.modified = stamp
            return node
        }

        model.nodes["root"] = node("root", title: "root")
        model.nodes["root2"] = node("root2", title: "root2")
        model.roots = ["root", "root2"]

        // Children of root: a, b(left), c, d(left).
        for child in [
            node("a", parent: "root", title: "root-a"),
            node("b", parent: "root", title: "root-b", side: .left),
            node("c", parent: "root", title: "root-c"),
            node("d", parent: "root", title: "root-d", side: .left),
        ] {
            model.nodes[child.id] = child
            model.nodes["root"]?.children.append(child.id)
        }
        for id in ["b1", "b2"] {
            model.nodes[id] = node(id, parent: "b", title: "b-\(id)")
            model.nodes["b"]?.children.append(id)
        }
        for id in ["x", "y"] {
            model.nodes[id] = node(id, parent: "root2", title: "root2-\(id)", side: .left)
            model.nodes["root2"]?.children.append(id)
        }
        return model
    }

    private static func resolver(_ model: MapModel) -> (String) -> SidePin? {
        { id in model.nodes[id]?.side ?? .right }
    }

    /// A random starting tree for the consistency fuzz.
    @MainActor
    private static func seededRandomModel(seed: UInt64) -> MapModel {
        var model = MapModel(docID: "outline-fuzz-\(seed)")
        var rng = SplitMix64(seed: seed ^ 0x5EED)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)

        func freshNode(parent: String?, side: SidePin?) -> Node {
            var node = Node(
                id: UUID().uuidString, parent: parent,
                title: NodeTitle(text: "node \(rng.range(1000))"), side: side)
            node.created = stamp
            node.modified = stamp
            return node
        }

        var rootIDs: [String] = []
        for _ in 0...(rng.range(2) + 1) {
            let root = freshNode(parent: nil, side: nil)
            model.nodes[root.id] = root
            rootIDs.append(root.id)
            for _ in 0..<rng.range(5) {
                var child = freshNode(parent: root.id, side: rng.bool() ? .left : nil)
                child.created = stamp
                model.nodes[child.id] = child
                model.nodes[root.id]?.children.append(child.id)
                if rng.bool() {
                    for _ in 0..<rng.range(3) {
                        let grandchild = freshNode(parent: child.id, side: nil)
                        model.nodes[grandchild.id] = grandchild
                        model.nodes[child.id]?.children.append(grandchild.id)
                    }
                }
            }
        }
        model.roots = rootIDs
        return model
    }

    @MainActor
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

    /// A random store mutation, biased towards structure changes (the
    /// outline projection's job is exactly those).
    private static func randomCommand(model: MapModel, rng: inout SplitMix64) -> MapCommand {
        let ids = Array(model.nodes.keys)
        guard let id = rng.pick(ids) else {
            return .addRoot(index: nil, node: Node(id: UUID().uuidString))
        }
        let fresh = Node(id: UUID().uuidString)
        switch rng.range(12) {
        case 0:
            return .addChild(parent: id, index: rng.bool() ? rng.range(5) : nil, node: fresh)
        case 1:
            return .addSibling(anchor: id, before: rng.bool(), node: fresh)
        case 2:
            return .insertParent(anchor: id, node: fresh)
        case 3:
            return .editText(id: id, title: NodeTitle(text: "edited \(rng.range(1000))"))
        case 4:
            let target = rng.bool() ? rng.pick(ids) : nil
            return .moveNode(id: id, parent: target, index: rng.range(8))
        case 5:
            return .reorderSibling(id: id, delta: rng.bool() ? -1 : 1)
        case 6:
            return .promote(id: id)
        case 7:
            return .demote(id: id)
        case 8:
            return .deleteNodePromotingChildren(id: id)
        case 9:
            return .setFolded(id: id, folded: rng.bool())
        case 10:
            return .setSide(id: id, side: rng.bool() ? .left : .right)
        default:
            return .deleteSubtrees(ids: [id])
        }
    }
}

/// A tiny deterministic RNG so a failing seed reproduces exactly.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SplitMix64 {
    mutating func range(_ upper: Int) -> Int {
        Int(next() % UInt64(upper))
    }

    mutating func bool() -> Bool {
        next() & 1 == 0
    }

    mutating func pick<T>(_ items: [T]) -> T? {
        guard !items.isEmpty else { return nil }
        return items[range(items.count)]
    }
}
