import Foundation
import MapCore
import Testing

@testable import MapStudy

/// Daily queue building (SPEC §10): learning first, due reviews most-overdue
/// first, new cards in outline order, under the daily limits.
struct StudyQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00Z
    private let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func card(_ id: String) -> Card {
        Card(id: id, kind: .basic, nodeID: id, front: id, back: id)
    }

    private func state(
        _ kind: FSRSStateKind,
        due: Date,
        learningStep: Int = 0
    ) -> FSRSCard {
        var card = FSRSCard.new(now: now)
        card.state = kind
        card.due = due
        card.learningStep = learningStep
        card.stability = 10
        card.difficulty = 5
        card.lastReview = now
        return card
    }

    @Test func learningFirstThenOverdueThenNewInOutlineOrder() {
        let cards = [
            card("new1"),
            card("new2"),
            card("review-b"),
            card("review-a"),
            card("learn-1"),
            card("notdue"),
        ]
        let states: [String: FSRSCard] = [
            "learn-1": state(.learning, due: now.addingTimeInterval(-60)),
            "review-a": state(.review, due: now.addingTimeInterval(-86_400 * 10)),
            "review-b": state(.review, due: now.addingTimeInterval(-86_400 * 2)),
            "notdue": state(.review, due: now.addingTimeInterval(86_400 * 3)),
        ]
        let queue = StudyQueue.build(
            cards: cards,
            states: states,
            reviews: [],
            now: now,
            calendar: utcCalendar
        )
        let ids = queue.map { $0.card.id }
        #expect(ids == ["learn-1", "review-a", "review-b", "new1", "new2"])
        #expect(queue.map(\.reason) == [.learning, .review, .review, .new, .new])
    }

    @Test func dailyNewLimitComesFromStudySettings() {
        let cards = (0..<30).map { card("n\($0)") }
        let queue = StudyQueue.build(
            cards: cards,
            states: [:],
            reviews: [],
            now: now,
            studySettings: StudySettings(newPerDay: 5, retention: 0.9),
            calendar: utcCalendar
        )
        #expect(queue.count == 5)
        #expect(queue.allSatisfy { $0.reason == .new })

        // Default is 20 (SPEC F-STD-4).
        let defaultQueue = StudyQueue.build(
            cards: cards, states: [:], reviews: [], now: now, calendar: utcCalendar
        )
        #expect(defaultQueue.count == 20)
    }

    @Test func introductionsAlreadyLoggedTodayCountAgainstTheLimit() {
        let dayStart = utcCalendar.startOfDay(for: now)
        let earlierToday = dayStart.addingTimeInterval(3600)
        let yesterday = dayStart.addingTimeInterval(-60)
        let reviews = [
            ReviewLog(
                cardID: "n0", ts: earlierToday, grade: .good, elapsed: 0, stateBefore: .new, stateAfter: .learning),
            ReviewLog(cardID: "x", ts: yesterday, grade: .good, elapsed: 0, stateBefore: .new, stateAfter: .learning),
        ]
        let cards = (0..<10).map { card("n\($0)") }
        // n0 was introduced earlier today and is now a learning card due later.
        var states: [String: FSRSCard] = [:]
        states["n0"] = state(.learning, due: now.addingTimeInterval(600))
        let queue = StudyQueue.build(
            cards: cards,
            states: states,
            reviews: reviews,
            now: now,
            studySettings: StudySettings(newPerDay: 3, retention: 0.9),
            calendar: utcCalendar
        )
        // 1 of 3 new cards was already introduced today; n0 is in learning and
        // not due, so 2 fresh cards remain, in outline order.
        #expect(queue.map { $0.card.id } == ["n1", "n2"])
    }

    @Test func dailyReviewLimitCountsTodaySLoggedReviews() {
        let dayStart = utcCalendar.startOfDay(for: now)
        let earlierToday = dayStart.addingTimeInterval(3600)
        var reviews: [ReviewLog] = []
        for index in 0..<8 {
            reviews.append(
                ReviewLog(
                    cardID: "done\(index)",
                    ts: earlierToday,
                    grade: .good,
                    elapsed: 5,
                    stateBefore: .review,
                    stateAfter: .review
                )
            )
        }
        let cards = (0..<5).map { card("r\($0)") }
        let states = Dictionary(
            uniqueKeysWithValues: cards.map { ($0.id, state(.review, due: now.addingTimeInterval(-86_400))) }
        )
        let queue = StudyQueue.build(
            cards: cards,
            states: states,
            reviews: reviews,
            now: now,
            reviewsPerDay: 10,
            calendar: utcCalendar
        )
        // 8 of the 10 daily reviews are spent; 2 due cards remain.
        #expect(queue.count == 2)
        #expect(queue.allSatisfy { $0.reason == .review })
    }

    @Test func learningStepsAreNeverRationed() {
        let dayStart = utcCalendar.startOfDay(for: now)
        var reviews: [ReviewLog] = []
        for index in 0..<200 {
            reviews.append(
                ReviewLog(
                    cardID: "done\(index)",
                    ts: dayStart,
                    grade: .good,
                    elapsed: 0,
                    stateBefore: .review,
                    stateAfter: .review
                )
            )
        }
        let cards = [card("learn-a"), card("learn-b")]
        let states: [String: FSRSCard] = [
            "learn-a": state(.learning, due: now),
            "learn-b": state(.relearning, due: now.addingTimeInterval(-30)),
        ]
        let queue = StudyQueue.build(
            cards: cards,
            states: states,
            reviews: reviews,
            now: now,
            reviewsPerDay: 200,
            calendar: utcCalendar
        )
        #expect(queue.map { $0.card.id } == ["learn-b", "learn-a"])
        #expect(queue.allSatisfy { $0.reason == .learning })
    }

    @Test func cardsWithoutStateAreNewAndNotYetDueCardsWait() {
        let queue = StudyQueue.build(
            cards: [card("a"), card("b")],
            states: ["b": state(.review, due: now.addingTimeInterval(60))],
            reviews: [],
            now: now,
            calendar: utcCalendar
        )
        // "b" is not due yet and is not new, so only "a" is queued.
        #expect(queue.map { $0.card.id } == ["a"])
    }
}
