import CoreGraphics
import Foundation

/// An on-demand layout node for the incremental pass (SPEC §11.3's
/// `Layout.update(dirty:)`): the measured size, pinned side and child ids
/// of one node. Children are fetched only if the walk descends into them,
/// so a one-node title edit materializes a few dozen nodes of a 5,000-node
/// map instead of all of them.
public struct LayoutSourceNode: Sendable, Equatable {
    public let id: String
    public let size: CGSize
    public let side: LayoutSide?
    public let childIDs: [String]

    public init(id: String, size: CGSize, side: LayoutSide? = nil, childIDs: [String] = []) {
        self.id = id
        self.size = size
        self.side = side
        self.childIDs = childIDs
    }
}

/// Cached subtree placements between incremental passes — the "previous
/// layout state" `TreeLayout.update` reuses. One state per root tree.
///
/// The reuse contract (enforced per node, cheaply): a cached entry is
/// reused only when the node's own inputs are unchanged — same measured
/// size, same child ids in the same order, same root-class depth, same
/// working orientation. `dirty` (below) must additionally name every node
/// whose own inputs changed, so an untouched entry implies an untouched
/// subtree; over-marking dirty ids is always safe, under-marking is not.
public struct LayoutState: Sendable {
    /// One cached subtree placement, keyed by the subtree's root id.
    struct Entry: Sendable {
        /// Frames relative to the subtree root at `(0, 0)` plus contours —
        /// valid under any ancestor position.
        let placed: Placed
        /// The working-orientation size the placement was built from
        /// (transposed for vertical structures).
        let ownSize: CGSize
        let childIDs: [String]
        /// True when placed at depth 0, where the root gap applies.
        let rootClass: Bool
        let vertical: Bool

        func matches(_ raw: LayoutSourceNode, depth: Int, vertical: Bool) -> Bool {
            self.vertical == vertical
                && rootClass == (depth == 0)
                && ownSize
                    == (vertical
                        ? CGSize(width: raw.size.height, height: raw.size.width)
                        : raw.size)
                && childIDs == raw.childIDs
        }
    }

    /// Subtree placements by subtree root id.
    var entries: [String: Entry] = [:]
    /// Parent links of the tree this state was built from — used to close
    /// the dirty set under ancestors. Links of deleted nodes stay behind
    /// deliberately: a deleted id's stale link still resolves to the parent
    /// whose child list changed.
    var parents: [String: String?] = [:]

    /// `dirty` plus every ancestor reachable through the cached parent
    /// links (stale ones included — see `parents`): every node on a
    /// changed chain up to the root.
    func ancestorClosure(of dirty: Set<String>) -> Set<String> {
        var affected = dirty
        let cap = parents.count + 1
        for id in dirty {
            var current: String? = id
            var steps = 0
            while let node = current, steps <= cap {
                affected.insert(node)
                current = parents[node].flatMap { $0 }
                steps += 1
            }
        }
        return affected
    }
    /// The spacing the entries were built with; a change discards them.
    var spacing: LayoutSpacing = .default

    public init() {}
}

/// The incremental layout pass (SPEC §11.3's `Layout.update(dirty:)` and
/// §9's "incremental" bullet): reuses cached subtree placements for every
/// node outside `dirty`'s ancestor closure, recomputes the changed
/// subtrees and the ancestor chain up to the root, and emits exactly the
/// frames a full `TreeLayout.layout` produces.
///
/// `dirty` names the nodes whose own layout inputs changed (measured size,
/// child ids, pinned side, structure). Ancestors are closed automatically
/// through the state's parent links. `nil` means "everything": a full pass
/// that also fills the state for later reuse. Every output is
/// bit-identical to the full layout — the engine and `TreeLayout.layout`
/// share `TidyTree.place` and the same top-level transforms.
public enum IncrementalLayout {
    public static func update(
        rootID: String,
        structure: LayoutStructure,
        spacing: LayoutSpacing = .default,
        state: LayoutState = LayoutState(),
        dirty: Set<String>? = nil,
        source: @escaping (String) -> LayoutSourceNode?
    ) -> (frames: LayoutResult, state: LayoutState) {
        // F-LAY-4: the logic chart runs the one-sided engine at the
        // compact, uniform gap rhythm. The state's spacing tag keeps a
        // cached mind-map state from being reused (and vice versa).
        let spacing = structure == .logicChartRight ? LogicLayout.compacted(spacing) : spacing
        // A spacing change invalidates every entry: start from a clean
        // state so the pass recomputes everything.
        let fullPass = dirty == nil || state.spacing != spacing
        let baseState = fullPass ? LayoutState() : state
        let engine = IncrementalEngine(
            rootID: rootID,
            structure: structure,
            spacing: spacing,
            state: baseState,
            dirty: fullPass ? nil : dirty,
            source: source)
        guard source(rootID) != nil else {
            return ([:], state)
        }

        let frames: LayoutResult
        switch structure {
        case .mindmapRight, .mindmapLeft, .logicChartRight:
            // F-LAY-4's logic chart is the same one-sided placement at
            // the compacted spacing (applied before the engine was
            // built), so the tidy invariants carry over untouched.
            let placed = engine.placeOneSided()
            frames = MindmapLayout.assemble(placed, mirror: structure == .mindmapLeft)
        case .orgDown, .orgUp:
            let placed = engine.placeOneSided()
            frames = OrgLayout.assemble(placed, mirror: structure == .orgUp)
        case .mindmapBalanced:
            frames = engine.placeBalanced()
        }

        var entries = baseState.entries
        for (id, entry) in engine.updated {
            entries[id] = entry
        }
        var parents = baseState.parents
        for (id, parent) in engine.parents {
            parents[id] = parent
        }
        var newState = LayoutState()
        newState.entries = entries
        newState.parents = parents
        newState.spacing = spacing
        return (frames, newState)
    }
}

/// The walk itself: resolves each node either to a cached placement or to
/// a fresh `TidyTree.place` over its (lazily fetched) children.
final class IncrementalEngine {
    private let rootID: String
    private let spacing: LayoutSpacing
    private let vertical: Bool
    private let source: (String) -> LayoutSourceNode?
    private let previousEntries: [String: LayoutState.Entry]
    private let previousParents: [String: String?]
    /// nil = full pass (nothing reused).
    private let affected: Set<String>?
    /// Memo of this pass's placements — a balanced root child resolves once
    /// for the partition and again inside its side's stack.
    private(set) var updated: [String: LayoutState.Entry] = [:]
    private(set) var parents: [String: String?] = [:]
    /// Source lookups, once per node per pass.
    private var fetched: [String: LayoutSourceNode] = [:]

    init(
        rootID: String,
        structure: LayoutStructure,
        spacing: LayoutSpacing,
        state: LayoutState,
        dirty: Set<String>?,
        source: @escaping (String) -> LayoutSourceNode?
    ) {
        self.rootID = rootID
        self.spacing = spacing
        self.vertical = structure == .orgDown || structure == .orgUp
        self.source = source
        self.previousEntries = state.entries
        self.previousParents = state.parents
        // Stale links of deleted or moved ids are exactly what marks
        // their old parents: the closure walks the previous tree.
        self.affected = dirty.map(state.ancestorClosure(of:))
    }

    // MARK: source access

    fileprivate func raw(_ id: String) -> LayoutSourceNode? {
        if let cached = fetched[id] {
            return cached
        }
        guard let value = source(id) else { return nil }
        fetched[id] = value
        return value
    }

    // MARK: structures

    func placeOneSided() -> Placed {
        parents[rootID] = nil
        let node = EngineSourceNode(engine: self, id: rootID)
        if let placed = resolve(node, depth: 0, parent: nil) {
            return placed
        }
        // Unreachable: `update` guards on the root's existence. A
        // well-formed empty placement keeps the walk total anyway.
        return Placed(
            ids: [rootID], frames: [.zero], top: [], bottom: [],
            extentMaxX: 0, minY: 0, maxY: 0, predictedHeight: 0)
    }

    func placeBalanced() -> LayoutResult {
        parents[rootID] = nil
        guard let rawRoot = raw(rootID) else { return [:] }
        var frames: LayoutResult = [rootID: CGRect(origin: .zero, size: rawRoot.size)]
        let rootWidth = rawRoot.size.width
        let rootMidY = rawRoot.size.height / 2

        // Resolve every root child once — clean ones reuse their cached
        // placements — because the partition needs each subtree's
        // predicted height.
        struct Child {
            let id: String
            let side: LayoutSide?
            let placed: Placed
        }
        var children: [Child] = []
        for childID in rawRoot.childIDs {
            let node = EngineSourceNode(engine: self, id: childID)
            guard let placed = resolve(node, depth: 1, parent: rootID) else { continue }
            children.append(Child(id: childID, side: raw(childID)?.side, placed: placed))
        }

        var leftPinned: [Child] = []
        var rightPinned: [Child] = []
        var free: [Child] = []
        for child in children {
            switch child.side {
            case .left: leftPinned.append(child)
            case .right: rightPinned.append(child)
            case nil: free.append(child)
            }
        }

        func extentTotal(_ nodes: [Child]) -> CGFloat {
            var total: CGFloat = 0
            for (index, node) in nodes.enumerated() {
                total += node.placed.predictedHeight
                if index < nodes.count - 1 {
                    total += spacing.subtreeGap
                }
            }
            return total
        }

        var leftTotal = extentTotal(leftPinned)
        var rightTotal = extentTotal(rightPinned)
        var leftFree: [Child] = []
        var rightFree: [Child] = []
        for child in free {
            let height = child.placed.predictedHeight
            if leftTotal <= rightTotal {
                leftTotal += height + spacing.subtreeGap
                leftFree.append(child)
            } else {
                rightTotal += height + spacing.subtreeGap
                rightFree.append(child)
            }
        }

        let leftIDs = (leftPinned + leftFree).map(\.id)
        let rightIDs = (rightPinned + rightFree).map(\.id)

        if !rightIDs.isEmpty {
            let side = EngineSourceNode(engine: self, id: rootID, overrideChildIDs: rightIDs)
            let placed = TidyTree.place(
                side, spacing: spacing, depth: 0, vertical: false,
                resolve: { self.resolve($0, depth: $1, parent: self.rootID) })
            BalancedLayout.placeSide(
                placed, rootID: rootID, rootWidth: rootWidth, rootMidY: rootMidY,
                mirror: false, into: &frames)
        }
        if !leftIDs.isEmpty {
            let side = EngineSourceNode(engine: self, id: rootID, overrideChildIDs: leftIDs)
            let placed = TidyTree.place(
                side, spacing: spacing, depth: 0, vertical: false,
                resolve: { self.resolve($0, depth: $1, parent: self.rootID) })
            BalancedLayout.placeSide(
                placed, rootID: rootID, rootWidth: rootWidth, rootMidY: rootMidY,
                mirror: true, into: &frames)
        }
        return frames
    }

    // MARK: resolution

    private func resolve(_ node: EngineSourceNode, depth: Int, parent: String?) -> Placed? {
        guard let rawNode = raw(node.id) else { return nil }
        parents[node.id] = parent
        if let memo = updated[node.id] {
            return memo.placed
        }
        if let affected, !affected.contains(node.id),
            let entry = previousEntries[node.id],
            entry.matches(rawNode, depth: depth, vertical: vertical)
        {
            return entry.placed
        }
        let placed = TidyTree.place(
            node, spacing: spacing, depth: depth, vertical: vertical,
            resolve: { self.resolve($0, depth: $1, parent: node.id) })
        updated[node.id] = LayoutState.Entry(
            placed: placed,
            ownSize: vertical
                ? CGSize(width: rawNode.size.height, height: rawNode.size.width)
                : rawNode.size,
            childIDs: rawNode.childIDs,
            rootClass: depth == 0,
            vertical: vertical)
        return placed
    }
}

/// The engine's on-demand `EngineNode`: node data is fetched once (memoized
/// in the engine) and children materialize as wrappers only when the walk
/// descends. `overrideChildIDs` builds the synthetic balanced side roots,
/// which carry the real root's own data but only one side's children.
private struct EngineSourceNode: EngineNode {
    let engine: IncrementalEngine
    let id: String
    var overrideChildIDs: [String]?

    var size: CGSize { engine.raw(id)?.size ?? .zero }
    var children: [EngineSourceNode] {
        let childIDs = overrideChildIDs ?? engine.raw(id)?.childIDs ?? []
        return childIDs.map { EngineSourceNode(engine: engine, id: $0) }
    }
}
