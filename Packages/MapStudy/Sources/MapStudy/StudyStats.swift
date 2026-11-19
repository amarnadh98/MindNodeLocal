import Foundation
import MapCore

/// F-STD-7's per-deck dashboard row.
public struct DeckDue: Sendable, Equatable, Identifiable {
    /// The deck node's id (a deck is a branch marked Study, F-STD-1).
    public let id: String
    /// The deck node's title.
    public let name: String
    /// Cards due right now in this deck (learning + review, not new).
    public let due: Int
    /// Every card attributed to the deck.
    public let total: Int

    public init(id: String, name: String, due: Int, total: Int) {
        self.id = id
        self.name = name
        self.due = due
        self.total = total
    }
}

/// Dashboard computations (F-STD-7), per document: due counts, the
/// 30-day forecast, retention, streak, the heatmap's daily counts and
/// the per-deck due breakdown. All pure over (cards, states, review
/// log, now) — the dashboard UI is a thin shell over these, and the
/// cross-map aggregation seam starts here too: a Library dashboard
/// later feeds several documents' cards and one merged log through
/// the same functions.
public enum StudyStats {
    /// Cards due now that are not new (learning + review states).
    public static func dueCount(cards: [Card], states: [String: FSRSCard], now: Date) -> Int {
        cards.filter { card in
            guard let state = states[card.id], state.state != .new else { return false }
            return state.due <= now
        }.count
    }

    /// F-STD-7 "due per deck": every branch marked Study (F-STD-1),
    /// in map order, with the cards attributed to their **nearest**
    /// deck ancestor — a nested deck owns its subtree's cards, the
    /// outer deck keeps the rest. Due follows `dueCount`'s rule.
    /// Decks with no cards still list (total 0) so the row a user
    /// just marked shows up.
    public static func deckBreakdown(
        model: MapModel, cards: [Card], states: [String: FSRSCard], now: Date
    ) -> [DeckDue] {
        // Deck ids in map order.
        var deckOrder: [String] = []
        var isDeck: Set<String> = []
        func visit(_ id: String) {
            guard let node = model.nodes[id] else { return }
            if node.study?.deck == true {
                deckOrder.append(id)
                isDeck.insert(id)
            }
            for child in node.children {
                visit(child)
            }
        }
        for root in model.roots {
            visit(root)
        }
        // Attribute each card to its nearest deck (itself included).
        var buckets: [String: (due: Int, total: Int)] = [:]
        buckets.reserveCapacity(deckOrder.count)
        for card in cards {
            var owner: String?
            var cursor: String? = card.nodeID
            while let id = cursor {
                if isDeck.contains(id) {
                    owner = id
                    break
                }
                cursor = model.nodes[id]?.parent
            }
            guard let deck = owner else { continue }
            var bucket = buckets[deck] ?? (0, 0)
            bucket.total += 1
            if let state = states[card.id], state.state != .new, state.due <= now {
                bucket.due += 1
            }
            buckets[deck] = bucket
        }
        return deckOrder.map { id in
            let bucket = buckets[id] ?? (0, 0)
            return DeckDue(
                id: id,
                name: model.nodes[id]?.title.text ?? "Deck",
                due: bucket.due,
                total: bucket.total)
        }
    }

    /// Reviews due per day for the next `days` days, index 0 = today
    /// (overdue cards land in today's bucket, like every SRS app's
    /// forecast). New cards are not scheduled, so they never appear.
    public static func forecast(
        cards: [Card],
        states: [String: FSRSCard],
        now: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [Int] {
        var buckets = [Int](repeating: 0, count: max(days, 0))
        let today = calendar.startOfDay(for: now)
        for card in cards {
            guard let state = states[card.id], state.state == .learning || state.state == .review else { continue }
            let dayOffset = calendar.dateComponents([.day], from: today, to: state.due).day ?? 0
            let bucket = max(dayOffset, 0)
            if bucket < buckets.count {
                buckets[bucket] += 1
            }
        }
        return buckets
    }

    /// Mean predicted retention over reviewed cards (nil when nothing
    /// has been studied yet) — the "retention stat" of F-STD-7.
    public static func retention(
        cards: [Card],
        states: [String: FSRSCard],
        now: Date,
        desiredRetention: Double = 0.9
    ) -> Double? {
        let scheduler = FSRSScheduler(options: .init(desiredRetention: desiredRetention))
        var sum = 0.0
        var reviewed = 0
        for card in cards {
            guard let state = states[card.id], state.state != .new else { continue }
            sum += scheduler.retrievability(of: state, at: now)
            reviewed += 1
        }
        return reviewed > 0 ? sum / Double(reviewed) : nil
    }

    /// Today's grading accuracy: the share of today's reviews answered
    /// better than Again. Nil when nothing was reviewed today.
    public static func accuracyToday(reviews: [ReviewLog], now: Date, calendar: Calendar = .current) -> Double? {
        let today = calendar.startOfDay(for: now)
        let todayReviews = reviews.filter { $0.ts >= today }
        guard !todayReviews.isEmpty else { return nil }
        let correct = todayReviews.filter { $0.grade != .again }.count
        return Double(correct) / Double(todayReviews.count)
    }

    /// The review streak: consecutive days with at least one review,
    /// counting back from today. A day with no reviews yet doesn't break
    /// the streak — the count starts at yesterday until today's first
    /// review lands.
    public static func streak(reviews: [ReviewLog], now: Date, calendar: Calendar = .current) -> Int {
        guard !reviews.isEmpty else { return 0 }
        var days = Set<Date>()
        for review in reviews {
            days.insert(calendar.startOfDay(for: review.ts))
        }
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Reviews per day for the heatmap calendar: `days` entries, index 0
    /// = `days - 1` days before today, the last entry = today.
    public static func dailyReviewCounts(
        reviews: [ReviewLog],
        now: Date,
        days: Int,
        calendar: Calendar = .current
    ) -> [Int] {
        var counts = [Int](repeating: 0, count: max(days, 0))
        guard !counts.isEmpty else { return counts }
        let today = calendar.startOfDay(for: now)
        for review in reviews {
            let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: review.ts)).day ?? 0
            let index = offset + counts.count - 1
            if (0..<counts.count).contains(index) {
                counts[index] += 1
            }
        }
        return counts
    }
}
