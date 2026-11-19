import CoreGraphics
import Foundation
import Testing

@testable import MapLayout

/// Seeded property test for the incremental pass (SPEC §9/§11.3): over
/// random trees × all structures × random dirty edits,
/// `IncrementalLayout.update` must produce frames *exactly* equal to a
/// full `TreeLayout.layout` of the same tree — same floats, not same
/// rounded values. Dirty sets follow the public contract (only the nodes
/// whose own inputs changed); the engine closes them under ancestors
/// itself, and over-marking is exercised too because it must stay safe.
struct IncrementalLayoutTests {
    // MARK: test source (a materialized tree served by id)

    private func sourceIndex(of tree: LayoutNode) -> [String: LayoutSourceNode] {
        var index: [String: LayoutSourceNode] = [:]
        func walk(_ node: LayoutNode) {
            index[node.id] = LayoutSourceNode(
                id: node.id, size: node.size, side: node.side,
                childIDs: node.children.map(\.id))
            node.children.forEach(walk)
        }
        walk(tree)
        return index
    }

    private func source(for index: [String: LayoutSourceNode]) -> (String) -> LayoutSourceNode? {
        { index[$0] }
    }

    /// Pure in-place transform of the subtree rooted at `target`.
    private func transformed(
        _ tree: LayoutNode, target: String, _ change: (inout LayoutNode) -> Void
    ) -> LayoutNode {
        var copy = tree
        if copy.id == target {
            change(&copy)
            return copy
        }
        copy.children = copy.children.map { transformed($0, target: target, change) }
        return copy
    }

    /// All node ids of a tree, in pre-order.
    private func allIDs(_ tree: LayoutNode) -> [String] {
        [tree.id] + tree.children.flatMap(allIDs)
    }

    private func id(of tree: LayoutNode, at index: Int) -> String {
        allIDs(tree)[index]
    }

    // MARK: the property

    @Test func incrementalEqualsFullAcrossRandomEdits() {
        for seed: UInt64 in 0..<100 {
            var generator = SeededGenerator(seed: seed &+ 5_000)
            var id = 0
            var tree = randomTree(&generator, depth: 6, id: &id)

            for structure in allStructures {
                var state = LayoutState()
                var round = 0
                while true {
                    // Full layout of the current tree, as the reference.
                    let full = TreeLayout.layout(root: tree, structure: structure)

                    // Bootstrap or incremental: bootstrap must equal the
                    // full layout and fill the state.
                    let index = sourceIndex(of: tree)
                    let (frames, newState) = IncrementalLayout.update(
                        rootID: tree.id, structure: structure,
                        state: state, dirty: round == 0 ? nil : [],
                        source: source(for: index))
                    #expect(
                        frames == full,
                        "seed \(seed) \(structure.rawValue) round \(round): bootstrap/refresh mismatch")
                    state = newState

                    // An empty dirty set with a filled state must reuse
                    // everything and still match the full layout.
                    let (reuseFrames, reuseState) = IncrementalLayout.update(
                        rootID: tree.id, structure: structure, state: state, dirty: [],
                        source: source(for: index))
                    #expect(
                        reuseFrames == full,
                        "seed \(seed) \(structure.rawValue) round \(round): full-reuse mismatch")
                    state = reuseState

                    if round == 6 { break }
                    round += 1

                    // One random edit: a node's own input changes (dirty
                    // = {that node}); the engine closes ancestors itself.
                    let ids = allIDs(tree)
                    let target = ids[generator.count(in: 0...(ids.count - 1))]
                    var dirty: Set<String> = [target]
                    let kind = generator.count(in: 0...4)
                    var edited = tree
                    switch kind {
                    case 0:  // size change
                        edited = transformed(edited, target: target) { node in
                            node.size = CGSize(
                                width: generator.uniform(20...340),
                                height: generator.uniform(10...140))
                        }
                    case 1:  // pinned side change
                        let sides: [LayoutSide?] = [.left, .right, nil]
                        edited = transformed(edited, target: target) { node in
                            node.side = sides[generator.count(in: 0...2)]
                        }
                    case 2:  // child added
                        id += 1
                        let child = LayoutNode(
                            id: "r\(id)",
                            size: CGSize(width: generator.uniform(20...320), height: generator.uniform(10...130)))
                        edited = transformed(edited, target: target) { node in
                            node.children.append(child)
                        }
                    case 3:  // child removed (or a fold: the subtree's
                        // layout input is the parent's child list)
                        edited = transformed(edited, target: target) { node in
                            guard !node.children.isEmpty else { return }
                            node.children.remove(
                                at: generator.count(in: 0...(node.children.count - 1)))
                        }
                    default:  // children reordered
                        edited = transformed(edited, target: target) { node in
                            guard node.children.count > 1 else { return }
                            node.children.shuffle(using: &generator)
                        }
                    }
                    let editedIndex = sourceIndex(of: edited)
                    let editedFull = TreeLayout.layout(root: edited, structure: structure)

                    // Occasionally over-mark: extra dirty ids must be
                    // safe (more recomputation, same output).
                    if generator.count(in: 0...3) == 0 {
                        let extras = ids.filter { _ in generator.count(in: 0...1) == 0 }
                        dirty.formUnion(extras)
                    }

                    let (editedFrames, editedState) = IncrementalLayout.update(
                        rootID: edited.id, structure: structure, state: state, dirty: dirty,
                        source: source(for: editedIndex))
                    #expect(
                        editedFrames == editedFull,
                        "seed \(seed) \(structure.rawValue) round \(round) kind \(kind): edit of \(target) mismatched")
                    tree = edited
                    state = editedState
                }
            }
        }
    }

    @Test func spacingChangeDiscardsEntries() {
        var generator = SeededGenerator(seed: 99)
        var id = 0
        let tree = randomTree(&generator, depth: 5, id: &id)
        let index = sourceIndex(of: tree)

        let (defaultFrames, defaultState) = IncrementalLayout.update(
            rootID: tree.id, structure: .mindmapRight,
            source: source(for: index))
        #expect(defaultFrames == TreeLayout.layout(root: tree, structure: .mindmapRight))

        // A different spacing must fall back to a full pass and produce
        // exactly the wide-preset layout.
        let (wideFrames, _) = IncrementalLayout.update(
            rootID: tree.id, structure: .mindmapRight, spacing: .wide,
            state: defaultState, dirty: ["r1"],
            source: source(for: index))
        #expect(
            wideFrames == TreeLayout.layout(root: tree, structure: .mindmapRight, spacing: .wide))
    }

    @Test func dirtyOutsideTheTreeIsHarmless() {
        let tree = sampleTree()
        let index = sourceIndex(of: tree)
        let (frames, _) = IncrementalLayout.update(
            rootID: tree.id, structure: .mindmapBalanced,
            dirty: ["not-in-this-tree", "a1"],
            source: source(for: index))
        #expect(frames == TreeLayout.layout(root: tree, structure: .mindmapBalanced))
    }

    @Test func missingRootYieldsNoFrames() {
        let (frames, _) = IncrementalLayout.update(
            rootID: "missing", structure: .mindmapRight, dirty: ["x"],
            source: { _ in nil })
        #expect(frames.isEmpty)
    }

    @Test func missingChildIsSkippedLikeTheFullBuild() {
        // The source serves a child list containing an id it cannot
        // resolve: the incremental walk skips it and its subtree, exactly
        // as a full build prunes dangling children before layout.
        let tree = sampleTree()
        var index = sourceIndex(of: tree)
        index["a2"] = nil
        let (frames, _) = IncrementalLayout.update(
            rootID: tree.id, structure: .mindmapRight,
            state: LayoutState(), dirty: nil, source: source(for: index))
        #expect(frames["a2"] == nil)
        #expect(frames["a2x"] == nil)
        #expect(frames.count == 12)
        #expect(
            frames["a1"] != nil && frames["a3"] != nil && frames["root"] != nil)
    }

    // MARK: incremental performance smoke

    @Test func keystrokeRelayoutTouchesOnlyTheChain() {
        // A 5k-node tree, one title edit: the incremental pass must be far
        // below the full-layout cost (SPEC §9: incremental keystroke
        // relayout under 2 ms; the release-gated assertion keeps CI's
        // slower runners out, the print shows local numbers).
        let tree = bigTree(nodeCount: 5_000)
        var index = sourceIndex(of: tree)
        var state = LayoutState()
        do {
            let (frames, newState) = IncrementalLayout.update(
                rootID: tree.id, structure: .mindmapBalanced, state: state,
                dirty: nil, source: source(for: index))
            state = newState
            #expect(frames.count == 5_000)
        }

        // n600's size changes (a title edit re-measures one node).
        var edited = tree
        let target = "n600"
        func resize(_ node: inout LayoutNode) {
            if node.id == target {
                node.size = CGSize(width: node.size.width + 40, height: node.size.height + 6)
                return
            }
            node.children = node.children.map { child in
                var copy = child
                resize(&copy)
                return copy
            }
        }
        resize(&edited)
        index = sourceIndex(of: edited)

        var best: Double?
        for _ in 0..<10 {
            let start = DispatchTime.now()
            let (frames, newState) = IncrementalLayout.update(
                rootID: edited.id, structure: .mindmapBalanced, state: state,
                dirty: [target], source: source(for: index))
            let elapsed =
                Double(
                    DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            best = min(best ?? elapsed, elapsed)
            state = newState
            #expect(frames.count == 5_000)
        }
        let elapsed = best ?? 0
        print(
            "incremental keystroke relayout (5k, balanced, best of 10): "
                + String(format: "%.1f", elapsed * 1000) + " ms")
        #if !DEBUG
            if ProcessInfo.processInfo.environment["CI"] == nil {
                #expect(
                    elapsed < 0.002,
                    "SPEC §9 incremental keystroke relayout budget (2 ms): \(elapsed)")
            }
        #endif
    }
}

/// Shuffles with the seeded generator so edits reproduce from a seed.
extension Array {
    fileprivate mutating func shuffle(using generator: inout SeededGenerator) {
        for index in stride(from: count - 1, to: 0, by: -1) {
            let swap = Int(generator.next() % UInt64(index + 1))
            self.swapAt(index, swap)
        }
    }
}
