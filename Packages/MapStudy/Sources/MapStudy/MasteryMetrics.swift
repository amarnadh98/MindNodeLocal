import Foundation
import MapCore

/// F-STD-6's retrievability buckets. The bucket, not the raw R, is what
/// the overlay colors by: ≥ 0.9 green, 0.7–0.9 yellow, 0.5–0.7 orange,
/// < 0.5 red, a never-reviewed card gray.
public enum MasteryBucket: String, Sendable, CaseIterable, Equatable {
    /// R ≥ 0.9 — green.
    case strong
    /// 0.7 ≤ R < 0.9 — yellow.
    case good
    /// 0.5 ≤ R < 0.7 — orange.
    case fading
    /// R < 0.5 — red.
    case forgotten
    /// Never reviewed — gray outline.

    case fresh

    /// The bucket of a retrievability; `nil` R (a new card) is `fresh`.
    public static func bucket(retrievability: Double?) -> MasteryBucket {
        guard let retrievability else { return .fresh }
        switch retrievability {
        case ..<0.5: return .forgotten
        case ..<0.7: return .fading
        case ..<0.9: return .good
        default: return .strong
        }
    }
}

/// One card-owning node's mastery: the mean retrievability over its
/// REVIEWED cards (a node with several cards — basic, reversed, clozes —
/// shows one tint, so the node aggregates them), nil when every card is
/// new. Card ids ride along so the host can scope sessions.
public struct NodeMastery: Sendable, Equatable {
    /// The node's card ids whose mastery this entry aggregates.
    public let cardIDs: [String]
    /// Mean retrievability over reviewed cards; nil when all are new.
    public let retrievability: Double?
    public let bucket: MasteryBucket
}

/// The mastery view of a document at one instant (F-STD-6): per-node
/// tints, per-ancestor aggregates for the parent rings, and the weakest
/// branch a "Study Weakest Branch" session starts on. Pure — computed
/// from the model, a `now`, and the scheduler's forgetting curve, never
/// from view state.
public struct MasteryReport: Sendable, Equatable {
    /// Card-owning node id → its mastery tint (one entry per node that
    /// derives at least one card, document scope per F-STD-1).
    public let nodes: [String: NodeMastery]
    /// Node id → mean retrievability over ALL cards in its subtree,
    /// never-reviewed cards counting as 0 (an unstudied branch has no
    /// mastery). Ancestors of card nodes only; the value drives the
    /// aggregate rings and the weakest-branch pick.
    public let aggregates: [String: Double]
    /// The level-1 branch with the lowest mean mastery, or nil when no
    /// branch has cards. Ties keep outline order (first wins), so the
    /// pick is deterministic.
    public let weakestBranchID: String?

    /// Computes the report for `now`.
    ///
    /// - `cards` defaults to the document's deck-gated cards
    ///   (`CardExtractor.extract(from:)`) — the mastery overlay is a
    ///   document view, not a session scope.
    /// - `now` must be pinned by the host (and by tests) so the buckets
    ///   are deterministic.
    public static func compute(
        map: MapModel,
        now: Date,
        cards: [Card]? = nil,
        desiredRetention: Double = 0.9
    ) -> MasteryReport {
        let cards = cards ?? CardExtractor.extract(from: map)
        let scheduler = FSRSScheduler(options: .init(desiredRetention: desiredRetention))

        var cardsByNode: [String: [Card]] = [:]
        for card in cards {
            cardsByNode[card.nodeID, default: []].append(card)
        }

        // Per-node tint: mean R over reviewed cards, nil when all new.
        var nodes: [String: NodeMastery] = [:]
        for (nodeID, nodeCards) in cardsByNode {
            var sum = 0.0
            var reviewed = 0
            for card in nodeCards {
                let state = StudyStates.cardState(for: card, in: map.nodes[nodeID]?.study, now: now)
                guard state.state != .new else { continue }
                sum += scheduler.retrievability(of: state, at: now)
                reviewed += 1
            }
            let mean = reviewed > 0 ? sum / Double(reviewed) : nil
            nodes[nodeID] = NodeMastery(
                cardIDs: nodeCards.map(\.id),
                retrievability: mean,
                bucket: MasteryBucket.bucket(retrievability: mean))
        }

        // Subtree aggregates: post-order accumulation of (sum R, card
        // count) with new cards as R 0 — an ancestor ring shows the mean
        // mastery of everything below it.
        var aggregates: [String: Double] = [:]
        func accumulate(_ nodeID: String) -> (sum: Double, count: Int) {
            guard let node = map.nodes[nodeID] else { return (0, 0) }
            var sum = 0.0
            var count = 0
            for card in cardsByNode[nodeID] ?? [] {
                let state = StudyStates.cardState(for: card, in: node.study, now: now)
                sum += state.state == .new ? 0 : scheduler.retrievability(of: state, at: now)
                count += 1
            }
            for child in node.children {
                let below = accumulate(child)
                sum += below.sum
                count += below.count
            }
            if count > 0 {
                aggregates[nodeID] = sum / Double(count)
            }
            return (sum, count)
        }
        for root in map.roots {
            _ = accumulate(root)
        }

        // The weakest branch: level-1 nodes (every root's direct child),
        // lowest mean first, outline order on ties. A root without
        // children is its own branch.
        var candidates: [String] = []
        for root in map.roots {
            let children = map.nodes[root]?.children ?? []
            if children.isEmpty {
                candidates.append(root)
            } else {
                candidates.append(contentsOf: children)
            }
        }
        let weakest =
            candidates
            .filter { aggregates[$0] != nil }
            .min { lhs, rhs in
                let lhsR = aggregates[lhs]!
                let rhsR = aggregates[rhs]!
                return lhsR != rhsR
                    ? lhsR < rhsR
                    : (candidates.firstIndex(of: lhs)! < candidates.firstIndex(of: rhs)!)
            }

        return MasteryReport(nodes: nodes, aggregates: aggregates, weakestBranchID: weakest)
    }
}
