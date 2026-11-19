import Foundation
import MapCore
import Testing

@testable import MapStudy

/// Mastery computation (F-STD-6): buckets, aggregates and the weakest
/// branch, all pure at a pinned `now`.
struct MasteryMetricsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scheduler = FSRSScheduler()

    private func deckModel() -> (MapModel, [String]) {
        // Root with two card-bearing children per branch: "strong" cards
        // reviewed just now, "old" cards reviewed 40 days ago.
        var model = MapModel.emptyDocument()
        let root = Node(id: "root", title: NodeTitle(text: "Biology"), study: NodeStudy(deck: true))
        model.nodes[root.id] = root
        model.roots = [root.id]
        var ids: [String] = []
        for (branch, name) in [("b1", "Anatomy"), ("b2", "Physiology")] {
            var branchNode = Node(id: branch, parent: "root", title: NodeTitle(text: name))
            branchNode.children = []
            model.nodes[branch] = branchNode
            model.nodes["root"]?.children.append(branch)
            for child in 0..<2 {
                let id = "\(branch)-\(child)"
                model.nodes[id] = Node(
                    id: id, parent: branch, title: NodeTitle(text: "\(name) \(child)"), note: "n")
                model.nodes[branch]?.children.append(id)
                ids.append(id)
            }
        }
        return (model, ids)
    }

    private func reviewed(_ id: String, stability: Double, agoDays: Double, in model: inout MapModel) {
        let lastReview = now.addingTimeInterval(-86_400 * agoDays)
        let state = FSRSState(
            due: now.addingTimeInterval(86_400), stability: stability, difficulty: 5, reps: 1,
            state: .review, lastReview: lastReview)
        model.nodes[id]?.study = StudyStates.writing(
            state, for: Card(id: id, kind: .basic, nodeID: id, front: "", back: ""), in: nil)
    }

    @Test func bucketsFollowTheFSTDThresholds() {
        #expect(MasteryBucket.bucket(retrievability: nil) == .fresh)
        #expect(MasteryBucket.bucket(retrievability: 0.95) == .strong)
        #expect(MasteryBucket.bucket(retrievability: 0.9) == .strong)
        #expect(MasteryBucket.bucket(retrievability: 0.89) == .good)
        #expect(MasteryBucket.bucket(retrievability: 0.7) == .good)
        #expect(MasteryBucket.bucket(retrievability: 0.69) == .fading)
        #expect(MasteryBucket.bucket(retrievability: 0.5) == .fading)
        #expect(MasteryBucket.bucket(retrievability: 0.49) == .forgotten)
        #expect(MasteryBucket.bucket(retrievability: 0) == .forgotten)
    }

    @Test func freshCardsAreFreshAndReviewedCardsFollowStability() throws {
        var (model, ids) = deckModel()
        let report = MasteryReport.compute(map: model, now: now)
        // Everything is new.
        for id in ids {
            #expect(report.nodes[id]?.bucket == .fresh)
            #expect(report.nodes[id]?.retrievability == nil)
        }
        // A brand-new deck has a weakest branch (tie → outline order) but
        // no card nodes are reviewed yet; aggregates are all 0.
        #expect(report.weakestBranchID == "b1")
        #expect(report.aggregates["b1"] == 0)
        #expect(report.aggregates["root"] == 0)

        // One strong card: its node is green, the aggregates rise.
        reviewed(ids[0], stability: 40, agoDays: 0.5, in: &model)
        let updated = MasteryReport.compute(map: model, now: now)
        let mean = try #require(updated.nodes[ids[0]]?.retrievability)
        #expect(mean > 0.9)
        #expect(updated.nodes[ids[0]]?.bucket == .strong)
        #expect(updated.aggregates["b1"]! > 0)
        #expect(updated.aggregates["root"]! < updated.aggregates["b1"]!)
        // The other branch stays at 0 and is now the weakest.
        #expect(updated.weakestBranchID == "b2")
    }

    @Test func aForgottenCardColorsRedAndDragsItsBranch() throws {
        var (model, ids) = deckModel()
        reviewed(ids[0], stability: 1, agoDays: 120, in: &model)
        // The other branch studied well today, so the forgotten card's
        // branch is the weaker one.
        reviewed(ids[2], stability: 40, agoDays: 0.5, in: &model)
        let report = MasteryReport.compute(map: model, now: now)
        let retrievability = try #require(report.nodes[ids[0]]?.retrievability)
        #expect(retrievability < 0.5)
        #expect(report.nodes[ids[0]]?.bucket == .forgotten)
        // Branch aggregate is a mean including the fresh zeros.
        #expect(report.aggregates["b1"]! < retrievability)
        #expect(report.weakestBranchID == "b1")
    }

    @Test func multiCardNodesAggregateTheirCards() throws {
        var (model, ids) = deckModel()
        // A node with a strong basic card and a forgotten cloze card:
        // the node's tint is the mean of the two.
        let node = ids[0]
        reviewed(node, stability: 40, agoDays: 0.5, in: &model)
        var title = model.nodes[node]!.title
        title.text = "{{c1::masked}}"
        model.nodes[node]?.title = title
        let cards = CardExtractor.extract(from: model)
        let report = MasteryReport.compute(map: model, now: now, cards: cards)
        let mastery = try #require(report.nodes[node])
        #expect(mastery.cardIDs.contains(node) && mastery.cardIDs.contains("\(node)#c1"))
        // Mean of ~0.95 and a new (excluded) cloze: still strong, since
        // the un-reviewed cloze does not count in the mean.
        #expect(mastery.bucket == .strong)
    }

    @Test func theWeakestBranchSkipsCardlessBranchesAndTiesKeepOrder() {
        var model = MapModel.emptyDocument()
        let root = Node(id: "root", title: NodeTitle(text: "R"), study: NodeStudy(deck: true))
        model.nodes[root.id] = root
        model.roots = [root.id]
        // One cardless branch, two with reviewed cards.
        for (id, hasCard, stability) in [("empty", false, 0.0), ("weak", true, 1.0), ("strong", true, 30.0)] {
            model.nodes[id] = Node(id: id, parent: "root", title: NodeTitle(text: id))
            model.nodes["root"]?.children.append(id)
            if hasCard {
                model.nodes["\(id)-c"] = Node(id: "\(id)-c", parent: id, title: NodeTitle(text: "c"), note: "n")
                model.nodes[id]?.children.append("\(id)-c")
                reviewed("\(id)-c", stability: stability, agoDays: 20, in: &model)
            }
        }
        let report = MasteryReport.compute(map: model, now: now)
        #expect(report.aggregates["empty"] == nil)
        #expect(report.weakestBranchID == "weak")

        // All-new branches tie at 0: the first in outline order wins.
        var fresh = model
        for id in ["weak-c", "strong-c"] {
            fresh.nodes[id]?.study = nil
        }
        #expect(MasteryReport.compute(map: fresh, now: now).weakestBranchID == "weak")
    }

    @Test func reportIgnoresCardsOutsideDecks() {
        var model = MapModel.emptyDocument()
        model.nodes["root"] = Node(id: "root", title: NodeTitle(text: "R"))
        model.roots = ["root"]
        model.nodes["orphan"] = Node(id: "orphan", parent: "root", title: NodeTitle(text: "O"), note: "n")
        model.nodes["root"]?.children = ["orphan"]
        // No deck anywhere: the document has no cards, no aggregates.
        let report = MasteryReport.compute(map: model, now: now)
        #expect(report.nodes.isEmpty)
        #expect(report.aggregates.isEmpty)
        #expect(report.weakestBranchID == nil)
    }

    @Test func retrievabilityMatchesTheScheduler() throws {
        var (model, ids) = deckModel()
        reviewed(ids[0], stability: 10, agoDays: 5, in: &model)
        let state = StudyStates.cardState(
            for: Card(id: ids[0], kind: .basic, nodeID: ids[0], front: "", back: ""),
            in: model.nodes[ids[0]]?.study, now: now)
        let expected = scheduler.retrievability(of: state, at: now)
        let report = MasteryReport.compute(map: model, now: now)
        #expect(abs((report.nodes[ids[0]]?.retrievability ?? -1) - expected) < 1e-9)
    }
}

/// Dashboard stats (F-STD-7): due counts, forecast, retention, streak,
/// accuracy and heatmap counts.
struct StudyStatsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15T08:00Z
    private let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func card(_ id: String) -> Card {
        Card(id: id, kind: .basic, nodeID: id, front: id, back: id)
    }

    private func state(_ kind: FSRSStateKind, due: Date) -> FSRSCard {
        var card = FSRSCard.new(now: now)
        card.state = kind
        card.due = due
        card.stability = 10
        card.lastReview = now
        return card
    }

    @Test func dueCountCountsOnlyDueNonNewCards() {
        let cards = [card("learn"), card("due"), card("future"), card("new")]
        let states: [String: FSRSCard] = [
            "learn": state(.learning, due: now.addingTimeInterval(-60)),
            "due": state(.review, due: now),
            "future": state(.review, due: now.addingTimeInterval(86_400)),
            "new": state(.new, due: now),
        ]
        #expect(StudyStats.dueCount(cards: cards, states: states, now: now) == 2)
    }

    @Test func forecastBucketsByDayWithOverdueInToday() {
        let cards = (0..<3).map { card("c\($0)") }
        let states: [String: FSRSCard] = [
            "c0": state(.review, due: now.addingTimeInterval(-86_400 * 3)),
            "c1": state(.review, due: now.addingTimeInterval(86_400)),
            "c2": state(.review, due: now.addingTimeInterval(86_400 * 29.5)),
        ]
        let forecast = StudyStats.forecast(cards: cards, states: states, now: now, days: 30, calendar: utcCalendar)
        #expect(forecast[0] == 1)  // overdue lands today
        #expect(forecast[1] == 1)
        #expect(forecast[29] == 1)
        #expect(forecast.reduce(0, +) == 3)
        // A due date beyond the window is dropped, not wrapped.
        let far = StudyStats.forecast(
            cards: cards, states: ["c0": state(.review, due: now.addingTimeInterval(86_400 * 40))],
            now: now, days: 30, calendar: utcCalendar)
        #expect(far.reduce(0, +) == 0)
    }

    @Test func retentionIsTheMeanPredictedRecall() {
        let cards = [card("a"), card("b"), card("new")]
        var states: [String: FSRSCard] = [
            "a": state(.review, due: now),
            "b": state(.review, due: now),
        ]
        for id in ["a", "b"] {
            states[id]?.lastReview = now.addingTimeInterval(-86_400 * 10)
        }
        let retention = StudyStats.retention(cards: cards, states: states, now: now)
        #expect(retention != nil && abs(retention! - 0.9) < 0.02)
        #expect(StudyStats.retention(cards: [card("new")], states: [:], now: now) == nil)
    }

    private func review(_ daysAgo: Int, grade: Grade) -> ReviewLog {
        ReviewLog(
            cardID: "x", ts: now.addingTimeInterval(TimeInterval(-daysAgo) * 86_400), grade: grade,
            elapsed: 0, stateBefore: .new, stateAfter: .review)
    }

    @Test func streakCountsConsecutiveDaysAndSurvivesAnEmptyToday() {
        let reviews = [
            review(0, grade: .good), review(0, grade: .again), review(1, grade: .good), review(2, grade: .hard),
        ]
        #expect(StudyStats.streak(reviews: reviews, now: now, calendar: utcCalendar) == 3)
        // Today empty: the streak holds through yesterday.
        let yesterday = reviews.dropFirst(2)
        #expect(StudyStats.streak(reviews: Array(yesterday), now: now, calendar: utcCalendar) == 2)
        // A hole breaks it.
        let holey = [review(0, grade: .good), review(2, grade: .good)]
        #expect(StudyStats.streak(reviews: holey, now: now, calendar: utcCalendar) == 1)
        #expect(StudyStats.streak(reviews: [], now: now, calendar: utcCalendar) == 0)
    }

    @Test func accuracyTodayCountsNonAgainGrades() {
        let reviews = [
            review(0, grade: .good), review(0, grade: .easy), review(0, grade: .again), review(1, grade: .good),
        ]
        #expect(
            abs((StudyStats.accuracyToday(reviews: reviews, now: now, calendar: utcCalendar) ?? 0) - 2.0 / 3.0) < 1e-9)
        #expect(StudyStats.accuracyToday(reviews: [], now: now, calendar: utcCalendar) == nil)
    }

    @Test func dailyCountsAlignTodayLast() {
        var reviews: [ReviewLog] = []
        for _ in 0..<3 { reviews.append(review(0, grade: .good)) }
        reviews.append(review(6, grade: .good))
        let counts = StudyStats.dailyReviewCounts(reviews: reviews, now: now, days: 7, calendar: utcCalendar)
        #expect(counts.count == 7)
        #expect(counts.last == 3)  // today
        #expect(counts[0] == 1)  // 6 days ago
        #expect(counts.reduce(0, +) == 4)
    }
}
