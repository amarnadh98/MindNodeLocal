import Foundation
import MapCore

/// F-STD-5's canvas recall, as a pure value: the selected branch's
/// descendants hide behind placeholders, and the caller moves a
/// `revealed` set through three gestures — `revealNext` (the → key,
/// map order one at a time), `reveal(id:)` (a click on one
/// placeholder) and `revealSubtree(id:)` (⌥-click, the RevealEngine's
/// own subtree collection). The hierarchy semantics live in exactly
/// one place: the machine holds a `RevealEngine` built over the model
/// and delegates the ⌥-click expansion to `RevealEngine.subtree(of:)`.
///
/// Recall is **view state** — the machine never touches the model.
/// Grading happens in the host: `markingTarget(for:)` answers the
/// node's basic card under the branch's session scope (ADR-0015: a
/// branch session treats its root as an implicit deck), and the host
/// feeds it Good/Again through the document's non-undoable write path.
///
/// The reveal order is depth-first pre-order in `children` order (the
/// map's own outline order), matching how the cards' backs list their
/// children and how CardExtractor walks the tree.
public struct RecallMachine: Equatable, Sendable {
    /// The branch being recalled (stays visible — it is the prompt).
    public let branchID: String
    /// The branch's descendants in reveal order, filtered to the ids
    /// the caller could see on the canvas at start.
    public private(set) var order: [String]
    /// The ids revealed so far.
    public private(set) var revealed: Set<String>

    /// The branch's basic cards keyed by node id — F-STD-5's "that
    /// node's card if it is one" under the branch session's implicit
    /// deck. Clozes, reversed and summary cards are session-UI cards;
    /// recall grades the node as a whole, so only the basic card
    /// carries the mark.
    public let basicCards: [String: Card]

    private let positions: [String: Int]
    private let subtreeEngine: RevealEngine

    /// - Parameters:
    ///   - model: the document model (read-only; the machine is view state).
    ///   - branchID: the selected branch's node.
    ///   - visible: which ids exist on the canvas right now — folded-away
    ///     descendants stay out of the order so → never stalls on a
    ///     node the user cannot see.
    public init(model: MapModel, branchID: String, visible: (String) -> Bool = { _ in true }) {
        self.branchID = branchID
        var order: [String] = []
        var visited = Set<String>()
        func visit(_ id: String) {
            guard let node = model.nodes[id], visited.insert(id).inserted else { return }
            if id != branchID, visible(id) {
                order.append(id)
            }
            for child in node.children {
                visit(child)
            }
        }
        visit(branchID)
        self.order = order
        self.revealed = []
        var positions: [String: Int] = [:]
        for (index, id) in order.enumerated() {
            positions[id] = index
        }
        self.positions = positions
        var basic: [String: Card] = [:]
        // Only descendants can be revealed, so only they can be marked —
        // the branch node itself is a card under the session's implicit
        // deck, but it stays visible as the prompt and never grades.
        for card in CardExtractor.extract(from: model, subtreeRoot: branchID)
        where card.kind == .basic && positions[card.nodeID] != nil {
            basic[card.nodeID] = card
        }
        self.basicCards = basic
        // The engine's steps stay empty — the machine owns its own
        // reveal set; only `subtree(of:)` is consulted (⌥-click).
        self.subtreeEngine = RevealEngine(model: model, steps: [], placeholders: [], baseVisible: [])
    }

    // MARK: gestures

    /// → : the next node in map order, or nil when everything is
    /// revealed. Revealing never cascades — one node per press, unlike
    /// a presentation build step (F-STD-5 "one at a time").
    @discardableResult
    public mutating func revealNext() -> String? {
        guard let next = order.first(where: { !revealed.contains($0) }) else { return nil }
        revealed.insert(next)
        return next
    }

    /// A click on one placeholder: reveals exactly that node. Returns
    /// false (and changes nothing) for ids the branch does not manage
    /// or that are already revealed.
    @discardableResult
    public mutating func reveal(id: String) -> Bool {
        guard positions[id] != nil, !revealed.contains(id) else { return false }
        revealed.insert(id)
        return true
    }

    /// ⌥-click: the node and everything below it, in reveal order.
    /// Returns the ids that were actually newly revealed (empty when
    /// the click missed the machine's order).
    public mutating func revealSubtree(id: String) -> [String] {
        let fresh = subtreeEngine.subtree(of: id).filter { positions[$0] != nil && !revealed.contains($0) }
        guard !fresh.isEmpty else { return [] }
        revealed.formUnion(fresh)
        return fresh.sorted { positions[$0]! < positions[$1]! }
    }

    // MARK: querying

    /// How many nodes still hide behind placeholders.
    public var remainingCount: Int {
        order.count - revealed.count
    }

    /// True when every managed node is revealed.
    public var isComplete: Bool {
        remainingCount == 0
    }

    /// The basic card the node's ✓/✗ mark feeds, or nil when the node
    /// is not a card under the branch's session scope (F-STD-5 "if it
    /// is one") — a nil answer means the mark is session feedback
    /// only, with no FSRS write.
    public func markingTarget(for nodeID: String) -> Card? {
        basicCards[nodeID]
    }

    /// The per-node reveal states for the canvas overlay (SPEC §10:
    /// the renderer reads a `RevealState` overlay). Ids outside
    /// `order` are absent — the canvas leaves unmentioned ids fully
    /// visible, so the rest of the map and the branch node itself
    /// stay drawn.
    public func states() -> [String: RevealState] {
        var states: [String: RevealState] = [:]
        for id in order {
            states[id] = revealed.contains(id) ? .visible : .placeholder
        }
        return states
    }
}
