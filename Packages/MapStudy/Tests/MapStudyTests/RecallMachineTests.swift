import MapCore
import Testing

@testable import MapStudy

/// F-STD-5: the pure recall machine over a branch — one-at-a-time
/// reveals in map order, click reveals, ⌥-click subtree reveals through
/// the RevealEngine's own hierarchy collection, and the basic-card
/// marking targets under the branch's implicit-deck session scope.
struct RecallMachineTests {
    /// root → branch → a, b; a → a1; plus an `offdeck` root-level sibling.
    private func makeModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "recall")
        func add(_ id: String, parent: String?, note: String? = nil, study: NodeStudy? = nil) {
            var node = Node(id: id, title: NodeTitle(text: id), note: note)
            node.parent = parent
            node.study = study
            model.nodes[id] = node
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        add("root", parent: nil)
        add("branch", parent: "root")
        add("a", parent: "branch", note: "answer a")
        add("b", parent: "branch", note: "answer b")
        add("a1", parent: "a", note: "answer a1")
        add("offdeck", parent: "root")
        return model
    }

    @Test func revealOrderIsDepthFirstMapOrderWithoutTheBranchItself() {
        let subject = RecallMachine(model: makeModel(), branchID: "branch")
        #expect(subject.order == ["a", "a1", "b"])
        #expect(!subject.order.contains("branch"))
        #expect(!subject.order.contains("root"))
        #expect(subject.remainingCount == 3)
        #expect(!subject.isComplete)
        #expect(subject.states() == ["a": .placeholder, "a1": .placeholder, "b": .placeholder])
    }

    @Test func revealNextWalksTheOrderOneAtATimeWithoutCascading() {
        var subject = RecallMachine(model: makeModel(), branchID: "branch")
        let first = subject.revealNext()
        #expect(first == "a")
        // "a" is a parent: the reveal never cascades to a1 (F-STD-5's
        // "one at a time" vs the presentation build's subtree reveal).
        #expect(subject.states()["a1"] == .placeholder)
        let second = subject.revealNext()
        let third = subject.revealNext()
        #expect(second == "a1")
        #expect(third == "b")
        let fourth = subject.revealNext()
        #expect(fourth == nil)
        #expect(subject.isComplete)
        #expect(subject.states() == ["a": .visible, "a1": .visible, "b": .visible])
    }

    @Test func revealNextSkipsIdsTheCallerCannotSee() {
        // b folded away on the canvas: the order skips it.
        let subject = RecallMachine(model: makeModel(), branchID: "branch", visible: { $0 != "b" })
        #expect(subject.order == ["a", "a1"])
        var walker = subject
        let first = walker.revealNext()
        let second = walker.revealNext()
        #expect(first == "a")
        #expect(second == "a1")
        #expect(walker.isComplete)
    }

    @Test func clickRevealsExactlyTheClickedPlaceholder() {
        var subject = RecallMachine(model: makeModel(), branchID: "branch")
        let revealedByClick = subject.reveal(id: "a1")
        #expect(revealedByClick)
        #expect(subject.states() == ["a": .placeholder, "a1": .visible, "b": .placeholder])
        // Already revealed, outside the branch, or unknown: no-ops.
        let again = subject.reveal(id: "a1")
        let outside = subject.reveal(id: "root")
        let unknown = subject.reveal(id: "nope")
        #expect(!again && !outside && !unknown)
        #expect(subject.states() == ["a": .placeholder, "a1": .visible, "b": .placeholder])
    }

    @Test func optionClickRevealsTheWholeSubtreeInRevealOrder() {
        var subject = RecallMachine(model: makeModel(), branchID: "branch")
        #expect(subject.revealSubtree(id: "a") == ["a", "a1"])
        #expect(subject.states() == ["a": .visible, "a1": .visible, "b": .placeholder])
        // A second ⌥-click on the same node has nothing left.
        #expect(subject.revealSubtree(id: "a") == [])
        // ⌥-click on the branch node reveals everything it manages.
        #expect(subject.revealSubtree(id: "branch") == ["b"])
        #expect(subject.isComplete)
    }

    @Test func markingTargetsAreTheBranchSessionBasicCardsOnly() {
        // The branch is an implicit deck for the session (ADR-0015):
        // noted leaves inside it are cards; the root-level sibling is
        // not, and neither is the branch node itself (bare here).
        let subject = RecallMachine(model: makeModel(), branchID: "branch")
        #expect(subject.markingTarget(for: "a")?.id == "a")
        #expect(subject.markingTarget(for: "a1")?.id == "a1")
        #expect(subject.markingTarget(for: "b")?.id == "b")
        #expect(subject.markingTarget(for: "branch") == nil)
        #expect(subject.markingTarget(for: "offdeck") == nil)
        #expect(subject.markingTarget(for: "root") == nil)
    }

    @Test func markingTargetsRespectExplicitCardPolicy() {
        var model = makeModel()
        model.nodes["a"]?.study = NodeStudy(card: .off)
        // Explicitly off: the auto rule loses, no marking target.
        #expect(RecallMachine(model: model, branchID: "branch").markingTarget(for: "a") == nil)
        model.nodes["b"]?.study = NodeStudy(card: .on)
        // Explicitly on: a target even without children or a note.
        let onSubject = RecallMachine(model: model, branchID: "branch")
        #expect(onSubject.markingTarget(for: "b")?.id == "b")
    }

    @Test func aCycleInTheHierarchyCannotLoopTheOrder() {
        var model = makeModel()
        model.nodes["a"]?.children.append("b")
        model.nodes["b"]?.parent = "a"
        let subject = RecallMachine(model: model, branchID: "branch")
        #expect(Set(subject.order) == Set(["a", "a1", "b"]))
    }
}
