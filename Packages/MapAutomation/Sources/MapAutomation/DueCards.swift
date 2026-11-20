import Foundation
import MapCore
import MapStudy

/// Due-card counting over a map (F-INT-1 GetDueCardsCount, MCP
/// `get_due_cards`): the F-STD queue — learning first, then due reviews
/// under the daily limit, then new cards under the document's
/// `newPerDay` — counted per reason.
public struct DueSummary: Sendable, Equatable, Codable {
    public let docID: String
    public let title: String
    public let total: Int
    public let learning: Int
    public let review: Int
    public let new: Int

    public init(docID: String, title: String, total: Int, learning: Int, review: Int, new: Int) {
        self.docID = docID
        self.title = title
        self.total = total
        self.learning = learning
        self.review = review
        self.new = new
    }
}

public enum DueCards {
    /// The day's queue for `model` at `now`, given its review log. Pure.
    public static func summary(
        model: MapModel, reviews: [ReviewLog], now: Date = Date(), calendar: Calendar = .current
    ) -> DueSummary {
        let cards = CardExtractor.extract(from: model)
        let states = states(for: cards, in: model)
        let queue = StudyQueue.build(
            cards: cards,
            states: states,
            reviews: reviews,
            now: now,
            studySettings: model.studySettings,
            calendar: calendar
        )
        let learning = queue.filter { $0.reason == .learning }.count
        let review = queue.filter { $0.reason == .review }.count
        let fresh = queue.filter { $0.reason == .new }.count
        return
            DueSummary(
                docID: model.docID,
                title: FileSystemMapDirectory.title(of: model, fallback: ""),
                total: queue.count,
                learning: learning,
                review: review,
                new: fresh
            )
    }

    /// The queue length only — the number Shortcuts asks for.
    public static func dueCount(
        model: MapModel, reviews: [ReviewLog], now: Date = Date(), calendar: Calendar = .current
    ) -> Int {
        summary(model: model, reviews: reviews, now: now, calendar: calendar).total
    }

    /// Per-card scheduling state from the nodes that own the cards
    /// (SPEC §5.14: state travels with the node). A card with no stored
    /// state is new; the queue counts it accordingly.
    static func states(for cards: [Card], in model: MapModel) -> [String: FSRSCard] {
        var states: [String: FSRSCard] = [:]
        for card in cards {
            guard let node = model.nodes[card.nodeID], let persisted = node.study?.fsrs else {
                continue
            }
            states[card.id] = FSRSCard(persisted: persisted)
        }
        return states
    }
}
