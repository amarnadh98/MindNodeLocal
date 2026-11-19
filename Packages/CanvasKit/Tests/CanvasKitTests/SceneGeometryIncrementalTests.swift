import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

/// Seeded property tests for the incremental scene path (SPEC §11.3's
/// `Layout.update(dirty:)`): after random command edits on random maps,
/// `SceneGeometry.update` (with the per-document caches and the
/// command-derived dirty set) must produce a scene *exactly* equal to a
/// full `SceneGeometry.build` of the same model — same frames, styles,
/// titles, levels, branch order and colors. The command → dirty-id
/// mapping (`dirtyIDs`) is exercised by the same rounds, so an
/// under-marked command shows up as a scene mismatch here.
struct SceneGeometryIncrementalTests {
    // MARK: seeded random maps

    private struct Generator {
        var state: UInt64

        init(seed: UInt64) {
            state = seed &+ 0x9E37_79B9_7F4A_7C15
        }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        mutating func count<T: BinaryInteger>(in range: ClosedRange<T>) -> T {
            T(next() % UInt64(range.upperBound - range.lowerBound + 1)) + range.lowerBound
        }

        mutating func pick<T>(_ list: [T]) -> T? {
            guard !list.isEmpty else { return nil }
            return list[Int(next() % UInt64(list.count))]
        }
    }

    /// A random multi-root map: some titles repeat (so equal sizes are
    /// common), a few nodes fold, a few carry manual offsets, and root
    /// children pin sides.
    private func randomMap(_ generator: inout Generator) -> MapModel {
        var model = MapModel.emptyDocument(docID: "seed")
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        // Titles from a small pool: duplicates are the interesting case
        // for the size cache and the entry validation.
        let titles = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta"]

        func makeNode() -> Node {
            var node = Node(
                id: UUID().uuidString,
                title: NodeTitle(text: generator.pick(titles) ?? "Alpha"),
                created: date, modified: date)
            if generator.count(in: 0...4) == 0 {
                node.offset = ModelOffset(x: Double(generator.count(in: -40...40)), y: 8)
            }
            return node
        }

        var pool: [String: Node] = [:]
        func makeTree(depth: Int) -> Node {
            var node = makeNode()
            if depth > 0 {
                let childCount = generator.count(in: 0...4)
                node.children = (0..<childCount).map { _ in makeTree(depth: depth - 1).id }
                if !node.children.isEmpty && generator.count(in: 0...6) == 0 {
                    node.folded = true
                }
            }
            pool[node.id] = node
            return node
        }

        let rootCount = generator.count(in: 1...3)
        var roots: [String] = []
        for _ in 0..<rootCount {
            roots.append(makeTree(depth: 4).id)
        }
        for (id, node) in pool {
            model.nodes[id] = node
        }
        model.roots = roots
        // Parent links: one walk per root.
        func link(_ id: String) {
            for childID in model.nodes[id]?.children ?? [] {
                model.nodes[childID]?.parent = id
                link(childID)
            }
        }
        for rootID in roots {
            link(rootID)
            // Pin some root children, the balanced structure's input.
            for childID in model.nodes[rootID]?.children ?? [] where generator.count(in: 0...3) == 0 {
                model.nodes[childID]?.side = generator.count(in: 0...1) == 0 ? .left : .right
            }
        }
        return model
    }

    private func allNodeIDs(_ model: MapModel) -> [String] {
        Array(model.nodes.keys)
    }

    // MARK: scene equality

    /// Full scene equality: node sets, frames, levels, level-1 indices,
    /// titles, widths, decorations, styles, branch arrays (order
    /// included) and canvas color. `==` on frames is exact — this is the
    /// same bar as the MapLayout property test.
    private func scenesEqual(_ incremental: CanvasScene, _ rebuilt: CanvasScene) -> Bool {
        guard incremental.nodes.count == rebuilt.nodes.count else { return false }
        for (id, left) in incremental.nodes {
            guard let right = rebuilt.nodes[id] else { return false }
            let equal =
                left.frame == right.frame
                && left.level == right.level
                && left.level1Index == right.level1Index
                && left.title == right.title
                && left.width == right.width
                && left.decorations == right.decorations
                && SceneDiffer.sameStyle(left.style, right.style)
            if !equal {
                return false
            }
        }
        guard incremental.branches.count == rebuilt.branches.count else { return false }
        for (left, right) in zip(incremental.branches, rebuilt.branches) {
            if left != right || !SceneDiffer.sameColor(left.color, right.color) {
                return false
            }
        }
        return SceneDiffer.sameColor(incremental.canvasColor, rebuilt.canvasColor)
    }

    private func firstDifference(
        _ incremental: CanvasScene, _ rebuilt: CanvasScene
    ) -> String? {
        if incremental.nodes.count != rebuilt.nodes.count {
            let onlyIncremental = incremental.nodes.keys.filter { rebuilt.nodes[$0] == nil }.sorted().prefix(3)
            let onlyRebuilt = rebuilt.nodes.keys.filter { incremental.nodes[$0] == nil }.sorted().prefix(3)
            return "node count \(incremental.nodes.count) vs \(rebuilt.nodes.count); "
                + "only-incremental \(onlyIncremental); only-full \(onlyRebuilt)"
        }
        for (id, left) in incremental.nodes {
            guard let right = rebuilt.nodes[id] else {
                return "id \(id) missing in full"
            }
            if left.frame != right.frame {
                return "frame \(id): \(left.frame) vs \(right.frame)"
            }
            if left.level != right.level {
                return "level \(id): \(left.level) vs \(right.level)"
            }
            if left.level1Index != right.level1Index {
                return "level1Index \(id): \(left.level1Index) vs \(right.level1Index)"
            }
            if left.title != right.title {
                return "title \(id)"
            }
            if left.width != right.width {
                return "width \(id)"
            }
            if left.decorations != right.decorations {
                return "decorations \(id): \(String(describing: left.decorations)) "
                    + "vs \(String(describing: right.decorations))"
            }
            if !SceneDiffer.sameStyle(left.style, right.style) {
                return "style \(id)"
            }
        }
        if incremental.branches.count != rebuilt.branches.count {
            return "branch count \(incremental.branches.count) vs \(rebuilt.branches.count)"
        }
        for (index, pair) in zip(incremental.branches, rebuilt.branches).enumerated()
        where pair.0 != pair.1 {
            return "branch \(index): \(pair.0.parentID)->\(pair.0.childID) vs \(pair.1.parentID)->\(pair.1.childID)"
        }
        return nil
    }

    private func assertScenesEqual(
        _ incremental: CanvasScene, _ full: CanvasScene,
        _ comment: String
    ) {
        #expect(
            scenesEqual(incremental, full),
            "\(comment): incremental scene differs from a full rebuild — \(firstDifference(incremental, full) ?? "?")")
    }

    // MARK: the property

    @Test func updateEqualsFullRebuildAcrossRandomCommands() throws {
        let measurer = TextMeasurer()
        for seed: UInt64 in 0..<40 {
            var generator = Generator(seed: seed &+ 900)
            var model = randomMap(&generator)
            let cache = SceneBuildCache(variant: .light)

            // A cache-filling full build equals the plain build.
            assertScenesEqual(
                SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer),
                SceneGeometry.build(model: model, variant: .light, measurer: measurer),
                "seed \(seed): cache-filling build")

            for round in 0..<8 {
                // Deletions can shrink a map until a category has no
                // candidate (nothing left to delete or move under); a
                // skipped round is fine, the map still changes often
                // enough across rounds.
                guard let command = randomCommand(&generator, model: model) else { continue }
                var edited = model
                do {
                    try command.apply(to: &edited)
                } catch {
                    continue
                }
                // Some commands are structural no-ops (clamped reorder);
                // they still must produce an equal scene.
                let dirty = SceneGeometry.dirtyIDs(for: command, in: edited)
                let full =
                    SceneGeometry.build(model: edited, variant: .light, measurer: measurer)
                // An unrecognized command would force the host's full
                // fallback; none of the generated ones is, so a nil here
                // means dirtyIDs regressed.
                #expect(
                    dirty != nil,
                    "seed \(seed) round \(round): unrecognized command \(command)")
                if let dirty {
                    let incremental = SceneGeometry.update(
                        model: edited, cache: cache, variant: .light, measurer: measurer,
                        dirty: dirty)
                    assertScenesEqual(
                        incremental, full, "seed \(seed) round \(round) \(command.displayName)")
                }
                model = edited
            }
        }
    }

    /// The command generator: every kind `dirtyIDs` claims to know. Each
    /// returns a command valid against `model` (or one that will throw
    /// and be skipped).
    private func randomCommand(
        _ generator: inout Generator, model: MapModel
    ) -> MapCommand? {
        let ids = allNodeIDs(model)
        guard let id = generator.pick(ids) else { return nil }
        func makeLeaf() -> Node {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            return Node(
                id: UUID().uuidString,
                title: NodeTitle(text: "New \(generator.count(in: 0...99))"),
                created: date, modified: date)
        }
        switch generator.count(in: 0...13) {
        case 0:
            return .editText(id: id, title: NodeTitle(text: "Renamed \(generator.count(in: 0...99))"))
        case 1:
            return .addChild(parent: id, index: nil, node: makeLeaf())
        case 2:
            return .addSibling(anchor: id, before: generator.count(in: 0...1) == 0, node: makeLeaf())
        case 3:
            return .insertParent(anchor: id, node: makeLeaf())
        case 4:
            return .addRoot(index: nil, node: makeLeaf())
        case 5:
            // Delete a topmost node so the model keeps its parent link
            // structure sane (covered ids are pruned by the command).
            let topmost = ids.filter { candidate in
                var parent = model.nodes[candidate]?.parent
                while let parentID = parent {
                    if parentID == candidate { return false }
                    parent = model.nodes[parentID]?.parent
                }
                return true
            }
            guard let victim = generator.pick(Array(Set(topmost).subtracting([id]))) else { return nil }
            return .deleteSubtrees(ids: [victim])
        case 6:
            return .deleteNodePromotingChildren(id: id)
        case 7:
            // Move under a random node that is not the node itself and
            // not one of its descendants (that command throws and would
            // waste the round).
            func isDescendant(_ candidate: String, of id: String) -> Bool {
                var current = model.nodes[candidate]?.parent
                while let parentID = current {
                    if parentID == id { return true }
                    current = model.nodes[parentID]?.parent
                }
                return false
            }
            let others = ids.filter { $0 != id && !isDescendant($0, of: id) }
            guard let parent = generator.pick(others) else { return nil }
            let childCount = model.nodes[parent]?.children.count ?? 0
            return .moveNode(id: id, parent: parent, index: Int(generator.count(in: 0...9)) % (childCount + 1))
        case 8:
            return .reorderSibling(id: id, delta: generator.count(in: 0...1) == 0 ? -1 : 1)
        case 9:
            return .promote(id: id)
        case 10:
            return .demote(id: id)
        case 11:
            return .detach(id: id)
        case 12:
            return .setFolded(id: id, folded: !(model.nodes[id]?.folded ?? false))
        default:
            let roll = generator.count(in: 0...2)
            let side: SidePin? = roll == 0 ? nil : (roll == 1 ? .left : .right)
            return .setSide(id: id, side: side)
        }
    }

    // MARK: focused behaviors

    @Test func editingDraftGrowsOnlyThroughTheIncrementalPath() {
        let measurer = TextMeasurer()
        var generator = Generator(seed: 7)
        var model = randomMap(&generator)
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        guard let id = model.nodes.keys.first(where: { model.nodes[$0]?.children.isEmpty == true }) else {
            return
        }
        let draft = NodeTitle(text: "A much longer draft title than the original")
        let reference = SceneGeometry.build(
            model: model, variant: .light, measurer: measurer, editingTitle: (id, draft))
        let incremental = SceneGeometry.update(
            model: model, cache: cache, variant: .light, measurer: measurer,
            dirty: [id], editingTitle: (id, draft))
        assertScenesEqual(incremental, reference, "editing draft")

        // And committing the draft through the store's semantics: the
        // model now carries the draft title.
        model.nodes[id]?.title = draft
        let committedFull = SceneGeometry.build(model: model, variant: .light, measurer: measurer)
        let committedIncremental = SceneGeometry.update(
            model: model, cache: cache, variant: .light, measurer: measurer,
            dirty: [id])
        assertScenesEqual(committedIncremental, committedFull, "committed draft")
    }

    @Test func overmarkedDirtyStaysCorrect() {
        let measurer = TextMeasurer()
        var generator = Generator(seed: 21)
        let model = randomMap(&generator)
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        var edited = model
        guard let id = generator.pick(allNodeIDs(model)) else { return }
        try? MapCommand.editText(id: id, title: NodeTitle(text: "Resized by rename")).apply(to: &edited)
        let full = SceneGeometry.build(model: edited, variant: .light, measurer: measurer)
        let overmarked = SceneGeometry.update(
            model: edited, cache: cache, variant: .light, measurer: measurer,
            dirty: Set(edited.nodes.keys))
        assertScenesEqual(overmarked, full, "every id dirty")
    }

    @Test func emptyDirtyOnUnchangedModelReusesEverything() {
        let measurer = TextMeasurer()
        var generator = Generator(seed: 33)
        let model = randomMap(&generator)
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)
        let full = SceneGeometry.build(model: model, variant: .light, measurer: measurer)
        let incremental = SceneGeometry.update(
            model: model, cache: cache, variant: .light, measurer: measurer, dirty: [])
        assertScenesEqual(incremental, full, "no change")
    }

    @Test func variantMismatchFallsBackToAFullBuild() {
        let measurer = TextMeasurer()
        var generator = Generator(seed: 44)
        let model = randomMap(&generator)
        let cache = SceneBuildCache(variant: .light)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: measurer)

        // A dark update against a light cache: full build, untouched
        // cache, still exactly the dark rebuild.
        let darkFull = SceneGeometry.build(model: model, variant: .dark, measurer: measurer)
        let darkIncremental = SceneGeometry.update(
            model: model, cache: cache, variant: .dark, measurer: measurer,
            dirty: Set(model.nodes.keys))
        assertScenesEqual(darkIncremental, darkFull, "variant mismatch")

        // The light cache still serves light updates afterwards.
        let lightFull = SceneGeometry.build(model: model, variant: .light, measurer: measurer)
        let lightIncremental = SceneGeometry.update(
            model: model, cache: cache, variant: .light, measurer: measurer, dirty: [])
        assertScenesEqual(lightIncremental, lightFull, "light after mismatch")
    }
}
