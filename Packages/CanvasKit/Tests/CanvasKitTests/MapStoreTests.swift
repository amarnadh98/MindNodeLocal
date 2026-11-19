import Foundation
import MapCore
import Testing

@testable import CanvasKit

/// Store-level tests (SPEC §11.3): perform→undo and undo→redo are
/// exact, failures change nothing, editText coalesces, and a seeded
/// fuzz of 200 commands fully undoes back to the start.
///
/// `modified`/`modifiedBy` are journal fields the store stamps on every
/// touch and undo intentionally does not rewind (like a file's mtime),
/// so model equality is compared modulo them (`journalNormalized`).
@MainActor
struct MapStoreTests {
    @Test func performThenUndoRestoresTheModel() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        let original = store.model
        try store.perform(.addChild(parent: "root", index: nil, node: Node(id: "new")))

        #expect(store.model.nodes["new"] != nil)
        store.undoManager.undo()

        #expect(Self.journalNormalized(store.model) == Self.journalNormalized(original))
    }

    @Test func undoThenRedoRestoresTheModel() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        try store.perform(.addChild(parent: "root", index: nil, node: Node(id: "new")))
        try store.perform(.editText(id: "a", title: NodeTitle(text: "renamed")))
        let edited = store.model

        store.undoManager.undo()
        store.undoManager.redo()

        #expect(Self.journalNormalized(store.model) == Self.journalNormalized(edited))
    }

    @Test func failedCommandLeavesModelAndUndoStackUntouched() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        let original = store.model
        try store.perform(.addChild(parent: "root", index: nil, node: Node(id: "new")))
        let afterAdd = store.model

        // A missing parent throws before anything is applied or
        // registered: the model and the undo stack must not move.
        #expect(throws: (any Error).self) {
            try store.perform(.addChild(parent: "missing", index: nil, node: Node(id: "new2")))
        }
        #expect(Self.journalNormalized(store.model) == Self.journalNormalized(afterAdd))

        // Exactly the one valid action is on the stack: undoing once
        // must land back on the original model.
        store.undoManager.undo()
        #expect(Self.journalNormalized(store.model) == Self.journalNormalized(original))
        #expect(!store.undoManager.canUndo)
    }

    @Test func consecutiveEditTextsCoalesceIntoOneUndoStep() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        try store.perform(.editText(id: "a", title: NodeTitle(text: "first")))
        try store.perform(.editText(id: "a", title: NodeTitle(text: "second")))
        #expect(store.model.nodes["a"]?.title.text == "second")

        // One undo step covers the whole typing session: a single undo
        // must restore the session's start, not the intermediate edit.
        store.undoManager.undo()
        #expect(store.model.nodes["a"]?.title.text == "root-a")

        // And redo replays the session's *newest* edit.
        store.undoManager.redo()
        #expect(store.model.nodes["a"]?.title.text == "second")
    }

    @Test func editTextsOnDifferentNodesDoNotCoalesce() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        try store.perform(.editText(id: "a", title: NodeTitle(text: "renamed a")))
        try store.perform(.editText(id: "b", title: NodeTitle(text: "renamed b")))

        store.undoManager.undo()
        #expect(store.model.nodes["b"]?.title.text == "root-b")
        #expect(store.model.nodes["a"]?.title.text == "renamed a")
        store.undoManager.undo()
        #expect(store.model.nodes["a"]?.title.text == "root-a")
        #expect(!store.undoManager.canUndo)
    }

    @Test func performAfterUndoDoesNotCoalesceWithTheUndoneSession() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        try store.perform(.editText(id: "a", title: NodeTitle(text: "first")))
        store.undoManager.undo()

        // The new edit must register its own undo step, not merge into
        // the pre-navigation session (which registered nothing more).
        try store.perform(.editText(id: "a", title: NodeTitle(text: "after undo")))
        #expect(store.undoManager.canUndo)

        store.undoManager.undo()
        #expect(store.model.nodes["a"]?.title.text == "root-a")
        #expect(!store.undoManager.canUndo)
    }

    @Test func performNotifiesObserverForEachChange() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        var origins: [MapStore.ChangeOrigin] = []
        store.onChange = { origins.append($0) }

        try store.perform(.editText(id: "a", title: NodeTitle(text: "typed")))
        try store.perform(.editText(id: "a", title: NodeTitle(text: "typed more")))
        store.undoManager.undo()
        store.undoManager.redo()

        guard origins.count == 4 else {
            Issue.record("expected four change notifications, got \(origins.count)")
            return
        }
        guard case .perform(let command) = origins[0] else {
            Issue.record("expected a .perform origin")
            return
        }
        #expect(command == .editText(id: "a", title: NodeTitle(text: "typed")))
        guard case .undo = origins[2], case .redo = origins[3] else {
            Issue.record("expected .undo and .redo origins")
            return
        }
    }

    @Test func replaceModelClearsHistory() throws {
        let store = MapStore(model: Self.seededModel(), undoManager: Self.freshManager())
        try store.perform(.addChild(parent: "root", index: nil, node: Node(id: "new")))
        #expect(store.undoManager.canUndo)

        store.replaceModel(MapModel.emptyDocument())
        #expect(!store.undoManager.canUndo)
        #expect(!store.undoManager.canRedo)
        #expect(store.model.nodes.isEmpty)
    }

    @Test(arguments: [UInt64(1), UInt64(2), UInt64(3)])
    func seededFuzzFullyUndoes(seed: UInt64) throws {
        let store = MapStore(model: Self.seededModel(seed: seed), undoManager: Self.freshManager())
        let original = store.model
        var rng = SplitMix64(seed: seed)

        for _ in 0..<200 {
            let command = Self.randomCommand(model: store.model, rng: &rng)
            do {
                try store.perform(command)
            } catch {
                continue  // invalid targets must leave the store untouched
            }
        }
        #expect(!store.model.nodes.isEmpty, "fuzz never applied anything")

        while store.undoManager.canUndo {
            store.undoManager.undo()
        }
        #expect(
            Self.journalNormalized(store.model) == Self.journalNormalized(original),
            "full undo did not restore the seed-\(seed) model")
    }

    // MARK: selection after delete

    @Test func deletedMiddleNodeSelectsNearestSurvivingSibling() {
        let model = Self.seededModel()
        // Children of root are [a, b, c]: "a" wins the distance-1 tie.
        let selection = MapStore.selectionAfterDelete(
            model: model, deletedIDs: ["b"], selection: ["b"])
        #expect(selection == ["a"])
    }

    @Test func deletedFirstNodeSelectsNextSibling() {
        let model = Self.seededModel()
        let selection = MapStore.selectionAfterDelete(
            model: model, deletedIDs: ["a"], selection: ["a"])
        #expect(selection == ["b"])
    }

    @Test func deleteAllChildrenSelectsParent() {
        let model = Self.seededModel()
        // "a" survives; both its children die, so they fall back to it.
        let selection = MapStore.selectionAfterDelete(
            model: model, deletedIDs: ["a1", "a2"], selection: ["a1", "a2"])
        #expect(selection == ["a"])
    }

    @Test func deletedBranchMemberSelectsSurvivingSibling() {
        let model = Self.seededModel()
        // "a1" dies inside the deleted "a" subtree; its topmost deleted
        // ancestor owns the slot, so the fallback is "a"'s sibling "b".
        let selection = MapStore.selectionAfterDelete(
            model: model, deletedIDs: ["a"], selection: ["a1"])
        #expect(selection == ["b"])
    }

    @Test func deletedRootFallsBackToNearestSurvivingRoot() {
        let model = Self.seededModel()
        let selection = MapStore.selectionAfterDelete(
            model: model, deletedIDs: ["root"], selection: ["root"])
        #expect(selection == ["root2"])
    }

    @Test func deletingEverythingDeselects() {
        var model = Self.seededModel()
        model.roots = ["root"]
        model.nodes["root2"] = nil
        let selection = MapStore.selectionAfterDelete(
            model: model, deletedIDs: ["root"], selection: ["root"])
        #expect(selection.isEmpty)
    }

    @Test func survivorsKeepTheirSelection() {
        let model = Self.seededModel()
        let selection = MapStore.selectionAfterDelete(
            model: model, deletedIDs: ["a"], selection: ["b", "c", "a1"])
        #expect(selection == ["b", "c"])
    }
}

// MARK: - fixtures

extension MapStoreTests {
    /// A two-root tree: `root` has children [a, b, c], "a" has [a1, a2].
    fileprivate static func seededModel(seed: UInt64 = 0) -> MapModel {
        var model = MapModel(docID: "store-\(seed)")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        func node(_ id: String, parent: String? = nil, title: String) -> Node {
            var node = Node(id: id, parent: parent, title: NodeTitle(text: title))
            node.created = stamp
            node.modified = stamp
            return node
        }
        model.nodes["root"] = node("root", title: "root")
        model.nodes["root2"] = node("root2", title: "second root")
        model.roots = ["root", "root2"]
        for id in ["a", "b", "c"] {
            model.nodes[id] = node(id, parent: "root", title: "root-\(id)")
            model.nodes["root"]?.children.append(id)
        }
        for id in ["a1", "a2"] {
            model.nodes[id] = node(id, parent: "a", title: "a-\(id)")
            model.nodes["a"]?.children.append(id)
        }
        return model
    }

    /// The manager with event grouping off, so one `undo()` undoes exactly
    /// one store step (each `perform` opens its own explicit group anyway;
    /// in the app, the run-loop event groups a gesture's steps).
    fileprivate static func freshManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    /// Zeroes the journal fields the store stamps on every touch.
    fileprivate static func journalNormalized(_ model: MapModel) -> MapModel {
        var copy = model
        for (id, _) in copy.nodes {
            copy.nodes[id]?.modified = Date(timeIntervalSince1970: 0)
            copy.nodes[id]?.modifiedBy = .user
        }
        return copy
    }

    // Command dispatchers are wide switches by design.
    // swiftlint:disable cyclomatic_complexity
    /// A random command against `model`, mixing valid operations with
    /// the occasional invalid target to exercise the failure path.
    fileprivate static func randomCommand(model: MapModel, rng: inout SplitMix64) -> MapCommand {
        let ids = Array(model.nodes.keys)
        guard let id = rng.pick(ids) else {
            return .addRoot(index: nil, node: Node(id: UUID().uuidString))
        }
        if rng.range(12) == 0 {
            return .addChild(
                parent: "missing-\(rng.range(10))", index: nil,
                node: Node(id: UUID().uuidString))
        }
        let fresh = Node(id: UUID().uuidString)
        switch rng.range(16) {
        case 0:
            return .addChild(
                parent: id, index: rng.bool() ? rng.range(10) : nil, node: fresh)
        case 1:
            return .addSibling(anchor: id, before: rng.bool(), node: fresh)
        case 2:
            return .insertParent(anchor: id, node: fresh)
        case 3:
            return .addRoot(index: rng.bool() ? rng.range(5) : nil, node: fresh)
        case 4:
            let extra = rng.pick(ids) ?? id
            return .deleteSubtrees(ids: rng.bool() ? [id] : [id, extra])
        case 5:
            return .deleteNodePromotingChildren(id: id)
        case 6:
            return .editText(id: id, title: NodeTitle(text: "edited \(rng.range(1000))"))
        case 7:
            let target = rng.bool() ? rng.pick(ids) : nil
            return .moveNode(id: id, parent: target, index: rng.range(10))
        case 8:
            return .reorderSibling(id: id, delta: rng.bool() ? -1 : 1)
        case 9:
            return .promote(id: id)
        case 10:
            return .demote(id: id)
        case 11:
            return .detach(id: id)
        case 12:
            if let command = try? MapCommand.duplicate(id: id, in: model) {
                return command
            }
            return .setFolded(id: id, folded: rng.bool())
        case 13:
            return .setFolded(id: id, folded: rng.bool())
        case 14:
            return .setSide(id: id, side: rng.bool() ? .left : .right)
        default:
            return .setOffset(
                id: id, offset: ModelOffset(x: Double(rng.range(50)), y: Double(rng.range(50))))
        }
    }
    // swiftlint:enable cyclomatic_complexity
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

    mutating func bool() -> Bool {
        next() & 1 == 0
    }

    mutating func range(_ upper: Int) -> Int {
        Int(next() % UInt64(max(upper, 1)))
    }

    mutating func pick<T>(_ array: [T]) -> T? {
        array.isEmpty ? nil : array[range(array.count)]
    }
}
