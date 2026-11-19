import MapCore
import Testing

@testable import MapStudy

/// SPEC §10 "Reveal Engine": the shared progressive-disclosure machine
/// behind presentation builds and study recall.
struct RevealEngineTests {
    /// root → a, b; a → a1, a2; a1 → a1x.
    private func makeModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "reveal")
        func add(_ id: String, parent: String?) {
            let node = Node(id: id, title: NodeTitle(text: id))
            model.nodes[id] = node
            model.nodes[id]?.parent = parent
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        add("root", parent: nil)
        add("a", parent: "root")
        add("b", parent: "root")
        add("a1", parent: "a")
        add("a2", parent: "a")
        add("a1x", parent: "a1")
        return model
    }

    private func engine(
        steps: [RevealStep],
        placeholders: Set<String> = [],
        baseVisible: Set<String> = [],
        children: [String: [String]]? = nil
    ) -> RevealEngine {
        RevealEngine(
            steps: steps,
            children: children ?? [
                "root": ["a", "b"], "a": ["a1", "a2"], "a1": ["a1x"], "a2": [], "b": [], "a1x": [],
            ],
            placeholders: placeholders,
            baseVisible: baseVisible)
    }

    // MARK: cursor navigation

    @Test func startCursorRevealsNothingBeyondTheBase() {
        let subject = engine(steps: [RevealStep(ids: ["a"])], baseVisible: ["root"])
        #expect(subject.startCursor == -1)
        #expect(subject.next(after: subject.startCursor) == 0)
        #expect(subject.back(from: subject.startCursor) == nil)
        #expect(subject.state(of: "root", at: subject.startCursor) == .visible)
        #expect(subject.state(of: "a", at: subject.startCursor) == .hidden)
    }

    @Test func nextWalksEveryStepThenStops() {
        let subject = engine(steps: [RevealStep(ids: ["a"]), RevealStep(ids: ["b"])])
        var cursor = subject.startCursor
        cursor = subject.next(after: cursor)!
        #expect(cursor == 0)
        cursor = subject.next(after: cursor)!
        #expect(cursor == 1)
        #expect(subject.next(after: cursor) == nil)
    }

    @Test func backUnappliesOneStepAtATime() {
        let subject = engine(steps: [RevealStep(ids: ["a"]), RevealStep(ids: ["b"])])
        let applied = subject.next(after: subject.next(after: subject.startCursor)!)!
        var cursor = subject.back(from: applied)!
        #expect(cursor == 0)
        cursor = subject.back(from: cursor)!
        #expect(cursor == subject.startCursor)
        #expect(subject.back(from: cursor) == nil)
    }

    @Test func resetIsTheStartCursor() {
        let subject = engine(steps: [RevealStep(ids: ["a"])])
        #expect(subject.clamped(99) == subject.lastCursor)
        #expect(subject.clamped(-5) == subject.startCursor)
        // The reset idiom: the caller's cursor returns to `startCursor`.
        var cursor = subject.next(after: subject.startCursor)!
        cursor = subject.startCursor
        #expect(subject.state(of: "a", at: cursor) == .hidden)
    }

    @Test func emptyEngineHasNoSteps() {
        let subject = engine(steps: [])
        #expect(subject.lastCursor == -1)
        #expect(subject.next(after: subject.startCursor) == nil)
        #expect(subject.revealedIDs(at: 0).isEmpty)
    }

    // MARK: states

    @Test func revealingAnIdRevealsItsSubtree() {
        let subject = engine(steps: [RevealStep(ids: ["a"])])
        let atOne = subject.states(at: 0, universe: ["a", "a1", "a2", "a1x", "b", "root"])
        #expect(atOne["a"] == .visible)
        #expect(atOne["a1"] == .visible)
        #expect(atOne["a2"] == .visible)
        #expect(atOne["a1x"] == .visible)
        #expect(atOne["b"] == .hidden)
    }

    @Test func aStepMayRevealSeveralIdsAtOnce() {
        let subject = engine(steps: [RevealStep(ids: ["a1", "b"])])
        let states = subject.states(at: 0, universe: ["a1", "a2", "b", "a1x"])
        #expect(states["a1"] == .visible)
        #expect(states["b"] == .visible)
        // "a" itself is not revealed — only the named ids and their
        // subtrees.
        #expect(states["a2"] == .hidden)
    }

    @Test func baseVisibleStaysVisibleAtEveryCursor() {
        let subject = engine(steps: [RevealStep(ids: ["a"])], baseVisible: ["root", "b"])
        for cursor in [subject.startCursor, 0, 5] {
            #expect(subject.state(of: "root", at: cursor) == .visible)
            #expect(subject.state(of: "b", at: cursor) == .visible)
        }
    }

    @Test func aBaseVisibleIdStillRevealsItsSubtreeWhenItsStepApplies() {
        // A focus node is fully visible before its build runs, but its
        // children stay hidden until the build names them.
        let subject = engine(steps: [RevealStep(ids: ["a"])], baseVisible: ["a"])
        #expect(subject.state(of: "a1", at: subject.startCursor) == .hidden)
        #expect(subject.state(of: "a1", at: 0) == .visible)
    }

    @Test func placeholdersShowBeforeTheirStepRevealsThem() {
        let subject = engine(steps: [RevealStep(ids: ["a1", "a2"])], placeholders: ["a1", "a2", "b"])
        let before = subject.states(at: subject.startCursor, universe: ["a1", "a2", "b", "a1x"])
        #expect(before["a1"] == .placeholder)
        #expect(before["a2"] == .placeholder)
        #expect(before["b"] == .placeholder)
        #expect(before["a1x"] == .hidden)  // not a placeholder itself
        let after = subject.states(at: 0, universe: ["a1", "a2", "b"])
        #expect(after["a1"] == .visible)
        #expect(after["a2"] == .visible)
        #expect(after["b"] == .placeholder)  // its step never applied
    }

    @Test func jumpEvaluatesAnyCursorDirectly() {
        let subject = engine(steps: [RevealStep(ids: ["a"]), RevealStep(ids: ["b"])])
        #expect(subject.state(of: "a", at: 0) == .visible)
        #expect(subject.state(of: "b", at: 0) == .hidden)
        #expect(subject.state(of: "b", at: 1) == .visible)
        // Out-of-range cursors clamp.
        #expect(subject.state(of: "b", at: 99) == .visible)
        #expect(subject.state(of: "b", at: -99) == .hidden)
    }

    @Test func unknownIdsEvaluateHiddenByDefault() {
        let subject = engine(steps: [RevealStep(ids: ["a"])])
        #expect(subject.state(of: "nope", at: 0) == .hidden)
        #expect(subject.states(at: 0, universe: ["nope"])["nope"] == .hidden)
    }

    @Test func cycleProofHierarchyCannotLoop() {
        let subject = engine(
            steps: [RevealStep(ids: ["x"])],
            children: ["x": ["y"], "y": ["x"]])
        #expect(subject.revealedIDs(at: 0) == ["x", "y"])
    }

    @Test func evaluationIsDeterministic() {
        let steps = [RevealStep(ids: ["a"]), RevealStep(ids: ["a1x", "b"])]
        let one = engine(steps: steps)
        let two = engine(steps: steps)
        let universe: Set<String> = ["a", "a1", "a2", "a1x", "b", "root"]
        for cursor in -1...steps.count {
            #expect(one.states(at: cursor, universe: universe) == two.states(at: cursor, universe: universe))
        }
    }

    // MARK: the model convenience

    @Test func modelInitBuildsTheHierarchyFromTheDocument() {
        let subject = RevealEngine(
            model: makeModel(),
            steps: [RevealStep(ids: ["a1"])],
            baseVisible: ["root", "a", "b"])
        let states = subject.states(at: 0, universe: ["a1", "a1x", "a2"])
        #expect(states["a1"] == .visible)
        #expect(states["a1x"] == .visible)  // subtree came with the model
        #expect(states["a2"] == .hidden)
    }

    @Test func repeatedApplicationIsIdempotent() {
        let subject = engine(steps: [RevealStep(ids: ["a"])])
        let first = subject.revealedIDs(at: 0)
        let second = subject.revealedIDs(at: 0)
        #expect(first == second)
    }
}
