import Foundation
import MapCore
import MapStudy
import Testing

@testable import MapAutomation

/// F-INT-1 GetDueCardsCount: the queue counts learning / review / new
/// from node-carried FSRS state plus the package's review log.
struct DueCardsTests {
    /// A map whose "paint" node is a due review card (stability 5, due
    /// two days ago, reviewed once) and whose "sage" node is a fresh
    /// new card (children make it a card by the auto rule). The auto
    /// policy keeps "paint" to its basic card, so the counts below stay
    /// exact.
    private static func studiedModel() -> MapModel {
        var model = FixtureMap.model()
        model.nodes["paint"]?.study = NodeStudy(
            card: .auto,
            fsrs: FSRSState(
                due: Date(timeIntervalSinceNow: -2 * 86_400),
                stability: 5,
                difficulty: 5,
                reps: 1,
                state: .review,
                lastReview: Date(timeIntervalSinceNow: -10 * 86_400)
            ))
        return model
    }

    @Test func dueReviewCounts() {
        let summary = DueCards.summary(model: Self.studiedModel(), reviews: [], now: Date())
        // "paint" is the due review; the root and "sage" are never-reviewed
        // cards under the daily new limit.
        #expect(summary.review == 1)
        #expect(summary.new == 2)
        #expect(summary.learning == 0)
        #expect(summary.total == 3)
    }

    @Test func newCardCountingRespectsTheDailyLimit() {
        let model = Self.studiedModel()
        // One review already logged today for a new card → allowance 20-1
        // would still be plenty; instead exercise the clamp directly.
        var settings = StudySettings()
        settings.newPerDay = 1
        var limited = model
        limited.studySettings = settings
        let reviews = [
            ReviewLog(
                cardID: "sage", ts: Date(), grade: .good, elapsed: 0,
                stateBefore: .new, stateAfter: .learning)
        ]
        let summary = DueCards.summary(model: limited, reviews: reviews, now: Date())
        #expect(summary.new == 0)
    }

    @Test func emptyMapHasNothingDue() {
        let summary = DueCards.summary(model: MapModel.emptyDocument(), reviews: [], now: Date())
        #expect(summary.total == 0)
    }
}
