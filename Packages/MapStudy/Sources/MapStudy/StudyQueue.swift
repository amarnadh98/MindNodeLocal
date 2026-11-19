import Foundation
import MapCore

/// Builds a day's study session queue (SPEC §10, F-STD-4):
/// learning cards first, then due reviews most-overdue first, then new cards
/// in map (outline) order — under the daily limits.
public enum StudyQueue {
    /// Why a card is queued.
    public enum Reason: String, Sendable {
        /// A card inside its learning/relearning steps (same-day commitment).
        case learning
        /// A review-state card whose due date has passed.
        case review
        /// A never-reviewed card.
        case new
    }

    /// One queued card.
    public struct Entry: Sendable, Equatable {
        public let card: Card
        public let reason: Reason

        public init(card: Card, reason: Reason) {
            self.card = card
            self.reason = reason
        }
    }

    /// The default daily review limit (SPEC F-STD-4); the new-card limit comes
    /// from the document's `studySettings`.
    public static let defaultReviewsPerDay = 200

    /// Builds the queue for `now`.
    ///
    /// - Learning cards (state `learning`/`relearning`, due now) are never
    ///   rationed: they are same-day commitments.
    /// - Due reviews (state `review`, due now) are limited by
    ///   `reviewsPerDay` minus the review-state reviews already logged today.
    /// - New cards are limited by `studySettings.newPerDay` (default 20) minus
    ///   the cards introduced (first-ever review) today, and keep the
    ///   extractor's outline order.
    public static func build(
        cards: [Card],
        states: [String: FSRSCard],
        reviews: [ReviewLog],
        now: Date,
        studySettings: StudySettings? = nil,
        reviewsPerDay: Int = StudyQueue.defaultReviewsPerDay,
        calendar: Calendar = .current
    ) -> [Entry] {
        let dayStart = calendar.startOfDay(for: now)
        func doneToday(_ predicate: (ReviewLog) -> Bool) -> Int {
            reviews.filter { $0.ts >= dayStart && predicate($0) }.count
        }
        let newIntroducedToday = doneToday { $0.stateBefore == .new }
        let reviewsDoneToday = doneToday { $0.stateBefore == .review }

        var queue: [Entry] = []

        // 1. Learning cards first, earliest due first.
        let learning =
            cards
            .filter { card in isDue(card, in: states, now: now) { $0.state == .learning || $0.state == .relearning } }
            .sorted { lhs, rhs in dueDate(lhs, in: states) < dueDate(rhs, in: states) }
        queue.append(contentsOf: learning.map { Entry(card: $0, reason: .learning) })

        // 2. Due reviews, most overdue first, under the daily review limit.
        let reviewAllowance = max(0, reviewsPerDay - reviewsDoneToday)
        let dueReviews =
            cards
            .filter { card in isDue(card, in: states, now: now) { $0.state == .review } }
            .sorted { lhs, rhs in dueDate(lhs, in: states) < dueDate(rhs, in: states) }
        queue.append(contentsOf: dueReviews.prefix(reviewAllowance).map { Entry(card: $0, reason: .review) })

        // 3. New cards in map order, under the daily new-card limit.
        let newAllowance = max(0, (studySettings?.newPerDay ?? 20) - newIntroducedToday)
        let newCards = cards.filter { card in states[card.id]?.state == nil || states[card.id]?.state == .new }
        queue.append(contentsOf: newCards.prefix(newAllowance).map { Entry(card: $0, reason: .new) })

        return queue
    }

    private static func isDue(
        _ card: Card,
        in states: [String: FSRSCard],
        now: Date,
        where predicate: (FSRSCard) -> Bool
    ) -> Bool {
        guard let state = states[card.id], predicate(state) else { return false }
        return state.due <= now
    }

    private static func dueDate(_ card: Card, in states: [String: FSRSCard]) -> Date {
        states[card.id]?.due ?? .distantPast
    }
}
