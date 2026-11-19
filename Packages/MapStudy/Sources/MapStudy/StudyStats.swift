import Foundation
import MapCore

/// Dashboard computations (F-STD-7), per document: due counts, the
/// 30-day forecast, retention, streak and the heatmap's daily counts.
/// All pure over (cards, states, review log, now) — the dashboard UI is
/// a thin shell over these, and the cross-map aggregation seam starts
/// here too: a Library dashboard later feeds several documents' cards
/// and one merged log through the same functions.
public enum StudyStats {
    /// Cards due now that are not new (learning + review states).
    public static func dueCount(cards: [Card], states: [String: FSRSCard], now: Date) -> Int {
        cards.filter { card in
            guard let state = states[card.id], state.state != .new else { return false }
            return state.due <= now
        }.count
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
