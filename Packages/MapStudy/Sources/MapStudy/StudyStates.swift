import Foundation
import MapCore

/// Per-card FSRS state storage on the owning node (SPEC §10: "card state
/// is stored on the node, keyed by card subtype"; ADR-0015).
///
/// The basic card (`nodeID`) keeps using the `study.fsrs` field the
/// schema has always had, so files written before companion cards
/// existed read exactly as before. Every other card of the node lives in
/// `study.fsrsByCard`, keyed by:
/// - `"r"` — the reversed card `nodeID#r`,
/// - `"cN"` — the cloze card `nodeID#cN`,
/// - `"s:<summaryID>"` — a summary card owned by this node (its card id
///   is the summary's id, not node-derived).
public enum StudyStates {
    /// The `fsrsByCard` key for `card`, or nil when the card's state
    /// lives in the basic `study.fsrs` field.
    public static func stateKey(for card: Card) -> String? {
        switch card.kind {
        case .basic:
            return nil
        case .reversed:
            return "r"
        case .cloze:
            // id == nodeID + "#c" + index.
            return String(card.id.dropFirst(card.nodeID.count + 1))
        case .summary:
            return "s:" + card.id
        }
    }

    /// The card's persisted scheduling state on `study`, or a fresh
    /// never-reviewed card due `now` when none is stored.
    public static func cardState(for card: Card, in study: NodeStudy?, now: Date) -> FSRSCard {
        switch stateKey(for: card) {
        case .some(let key):
            if let state = study?.fsrsByCard?[key] {
                return FSRSCard(persisted: state)
            }
        case .none:
            if let state = study?.fsrs {
                return FSRSCard(persisted: state)
            }
        }
        return FSRSCard.new(now: now)
    }

    /// `study` with `state` stored for `card`, creating the section when
    /// the node has none yet. A nil `study` starts from defaults.
    public static func writing(_ state: FSRSState, for card: Card, in study: NodeStudy?) -> NodeStudy {
        var updated = study ?? NodeStudy()
        if let key = stateKey(for: card) {
            var byCard = updated.fsrsByCard ?? [:]
            byCard[key] = state
            updated.fsrsByCard = byCard
        } else {
            updated.fsrs = state
        }
        return updated
    }

    /// The scheduling states of `cards` in `map`, keyed by card id — the
    /// input shape `StudyQueue.build` wants. Cards without stored state
    /// are absent (the queue reads absence as new).
    public static func states(for cards: [Card], in map: MapModel) -> [String: FSRSCard] {
        var states: [String: FSRSCard] = [:]
        for card in cards {
            guard let study = map.nodes[card.nodeID]?.study else { continue }
            guard hasStoredState(for: card, in: study) else { continue }
            states[card.id] = cardState(for: card, in: study, now: Date())
        }
        return states
    }

    /// True when `study` holds a persisted state for `card`.
    private static func hasStoredState(for card: Card, in study: NodeStudy) -> Bool {
        if let key = stateKey(for: card) {
            return study.fsrsByCard?[key] != nil
        }
        return study.fsrs != nil
    }

    // MARK: Command payload helpers (the App builds `setStudy` commands)

    /// `study` with the deck flag flipped (F-STD-1 "Make Study Deck"):
    /// `nil`/false becomes true, true becomes false.
    public static func togglingDeck(in study: NodeStudy?) -> NodeStudy {
        var updated = study ?? NodeStudy()
        updated.deck = !(study?.deck ?? false)
        return updated
    }

    /// `study` with the card policy replaced (F-STD-1 "Card / Not a
    /// Card / Auto").
    public static func settingPolicy(_ policy: CardPolicy, in study: NodeStudy?) -> NodeStudy {
        var updated = study ?? NodeStudy()
        updated.card = policy
        return updated
    }
}
