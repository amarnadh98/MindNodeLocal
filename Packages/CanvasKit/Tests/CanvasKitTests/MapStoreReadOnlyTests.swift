import Foundation
import MapCore
import Testing

@testable import CanvasKit

/// ADR-0023 / F-DOC-4: the store's read-only gate. Every mutation path
/// funnels through `MapStore`, so a host that flips `isReadOnly` (a
/// package from a newer app version) gets its enforcement for free —
/// `perform` and `performWithoutUndo` throw and leave the model, the
/// undo stacks and the change notifications untouched, while
/// `replaceModel` (the load/revert path) stays open.
@MainActor
struct MapStoreReadOnlyTests {
    private func makeStore() -> (MapStore, actor: ChangeFlag) {
        var model = MapModel.emptyDocument()
        let root = Node(id: "root")
        model.roots = [root.id]
        model.nodes[root.id] = root
        let store = MapStore(model: model)
        let flag = ChangeFlag()
        store.onChange = { _ in flag.notified = true }
        return (store, flag)
    }

    @Test func performThrowsAndLeavesTheModelUntouched() throws {
        let (store, flag) = makeStore()
        store.isReadOnly = true

        #expect(throws: ArborError.self) {
            try store.perform(.addChild(parent: "root", index: nil, node: Node(id: "kid")))
        }
        #expect(store.model.nodes["kid"] == nil)
        #expect(store.model.nodes["root"]?.children.isEmpty == true)
        #expect(flag.notified == false)
    }

    @Test func performWithoutUndoThrowsToo() throws {
        let (store, flag) = makeStore()
        store.isReadOnly = true

        #expect(throws: ArborError.self) {
            try store.performWithoutUndo(.setNote(id: "root", note: "no"))
        }
        #expect(store.model.nodes["root"]?.note == nil)
        #expect(flag.notified == false)
    }

    @Test func noUndoStepRegistersWhileReadOnly() throws {
        let (store, _) = makeStore()
        store.isReadOnly = true

        try? store.perform(.addChild(parent: "root", index: nil, node: Node(id: "kid")))
        #expect(store.undoManager.canUndo == false)
        #expect(store.undoManager.canRedo == false)
    }

    @Test func replaceModelAndUnlockedWritesStillWork() throws {
        let (store, flag) = makeStore()
        store.isReadOnly = true

        // The load/revert path ignores the gate: a revert must always
        // run, even for a read-only document.
        var replacement = MapModel.emptyDocument()
        replacement.roots = ["fresh"]
        replacement.nodes["fresh"] = Node(id: "fresh")
        store.replaceModel(replacement)
        #expect(store.model.roots == ["fresh"])

        store.isReadOnly = false
        try store.perform(.addChild(parent: "fresh", index: nil, node: Node(id: "kid")))
        #expect(store.model.nodes["fresh"]?.children == ["kid"])
        #expect(flag.notified == true)
    }
}

/// Records whether the store notified a model change.
@MainActor
private final class ChangeFlag {
    var notified = false
}
