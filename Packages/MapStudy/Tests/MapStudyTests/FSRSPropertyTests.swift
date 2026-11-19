import Foundation
import MapCore
import Testing

@testable import MapStudy

/// A seeded, reproducible generator for property tests.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// Property tests over the FSRS-6 math and scheduler (SPEC §14).
struct FSRSPropertyTests {
    private static let seeds: [UInt64] = [1, 42, 2026]

    @Test(arguments: seeds) func memoryStateStaysInBounds(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let model = FSRSModel()
        for _ in 0..<500 {
            let difficulty = Double.random(in: 1...10, using: &rng)
            let stability = Double.random(in: 0.001...36_500, using: &rng)
            let elapsedDays = Double.random(in: 0...365, using: &rng).rounded(.down)
            let grade = Grade.allCases.randomElement(using: &rng)!
            let next = model.nextMemoryState(
                difficulty: difficulty, stability: stability, elapsedDays: elapsedDays, grade: grade
            )
            #expect(next.stability > 0)
            #expect(next.stability <= FSRSModel.stabilityMax)
            #expect(next.difficulty >= FSRSModel.difficultyMin)
            #expect(next.difficulty <= FSRSModel.difficultyMax)
        }
    }

    @Test(arguments: seeds) func retrievabilityIsBoundedAndFades(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let model = FSRSModel()
        for _ in 0..<500 {
            let stability = Double.random(in: 0.001...36_500, using: &rng)
            let earlier = Double.random(in: 0...364, using: &rng).rounded(.down)
            let later = earlier + Double.random(in: 1...365, using: &rng).rounded(.down)
            let earlierRecall = model.retrievability(elapsedDays: earlier, stability: stability)
            let laterRecall = model.retrievability(elapsedDays: later, stability: stability)
            #expect(earlierRecall > 0 && earlierRecall <= 1)
            #expect(laterRecall > 0 && laterRecall <= 1)
            #expect(laterRecall <= earlierRecall, "retrievability decreases with elapsed time")
        }
        // A fresh memory recalls perfectly.
        #expect(FSRSModel().retrievability(elapsedDays: 0, stability: 5) == 1)
    }

    @Test(arguments: seeds) func intervalsAreMonotoneInGrade(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let scheduler = FSRSScheduler()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<200 {
            let state = makeCard(seed: &rng)
            var previousDue = Date.distantPast
            for grade in Grade.ascending {
                let due = scheduler.review(state, at: now, grade: grade).card.due
                #expect(due >= previousDue, "dues are monotone in grade for the same card")
                previousDue = due
            }
        }
    }

    @Test(arguments: seeds) func reviewIntervalsAreMonotoneAcrossGrades(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let scheduler = FSRSScheduler()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<200 {
            var card = makeCard(seed: &rng)
            card.state = .review
            var previousInterval = -Double.infinity
            for grade in [Grade.hard, .good, .easy] {
                let interval = scheduler.review(card, at: now, grade: grade).card.scheduledDays
                #expect(interval >= previousInterval, "review intervals are monotone in grade")
                previousInterval = interval
            }
        }
    }

    @Test(arguments: seeds) func successfulRecallsDoNotReduceStability(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let model = FSRSModel()
        for _ in 0..<300 {
            let difficulty = Double.random(in: 1...10, using: &rng)
            let stability = Double.random(in: 0.001...36_500, using: &rng)
            let elapsedDays = Double.random(in: 1...365, using: &rng).rounded(.down)
            for grade in [Grade.good, .easy] {
                let next = model.nextMemoryState(
                    difficulty: difficulty, stability: stability, elapsedDays: elapsedDays, grade: grade
                )
                #expect(next.stability >= stability, "a successful recall never reduces stability")
            }
        }
    }

    @Test func shortTermSameDayReviewsAreStable() {
        var rng = SeededGenerator(seed: 7)
        let scheduler = FSRSScheduler()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<100 {
            var card = makeCard(seed: &rng)
            card.state = .review
            card.lastReview = now  // reviewed moments ago: same-day path (t = 0)
            card.learningStep = 0  // review cards always graduate with step 0
            // Same-day good/hard/easy: stability never meaningfully decreases
            // (the reference rounds memory state to 8 decimals, which can shave
            // an unchanged stability by up to 5e-9).
            for grade in [Grade.hard, .good, .easy] {
                let next = scheduler.review(card, at: now, grade: grade).card
                #expect(next.stability >= card.stability - 1e-6)
            }
            // Same-day again lapses into relearning with a 10-minute step.
            let lapse = scheduler.review(card, at: now, grade: .again)
            #expect(lapse.card.state == .relearning)
            #expect(lapse.card.lapses == card.lapses + 1)
            #expect(lapse.card.due == now.addingTimeInterval(10 * 60))
        }
    }

    @Test func fuzzIsDeterministicAndBounded() throws {
        var card = FSRSCard.new(now: Date(timeIntervalSince1970: 1_800_000_000))
        card.state = .review
        card.stability = 50
        card.difficulty = 5
        card.lastReview = Date(timeIntervalSince1970: 1_800_000_000 - 30 * 86_400)
        card.due = Date(timeIntervalSince1970: 1_800_000_000 - 20 * 86_400)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let fuzzed = FSRSScheduler(options: .init(enableFuzz: true))
        let first = fuzzed.review(card, at: now, grade: .good)
        let second = fuzzed.review(card, at: now, grade: .good)
        #expect(first.card.scheduledDays == second.card.scheduledDays, "fuzz is deterministic per seed")
        #expect(first.card.scheduledDays >= 2)
        #expect(first.card.scheduledDays <= 36_500)

        let injectable = FuzzRNG { _ in 0.5 }
        let custom = FSRSScheduler(options: .init(enableFuzz: true, fuzzRNG: injectable))
        let customReview = custom.review(card, at: now, grade: .good)
        let customAgain = custom.review(card, at: now, grade: .good)
        // The injected 0.5 draw lands strictly inside the fuzz range and is deterministic.
        #expect(customReview.card.scheduledDays == customAgain.card.scheduledDays)
        #expect(customReview.card.scheduledDays >= 2)
        #expect(customReview.card.scheduledDays <= 36_500)

        // Fuzz off is the deterministic default.
        let plain = FSRSScheduler()
        let plainReview = plain.review(card, at: now, grade: .good)
        let expected = FSRSModel().nextInterval(stability: plainReview.card.stability, desiredRetention: 0.9)
        #expect(plainReview.card.scheduledDays == max(jsRound(expected), 1))
    }

    @Test func persistedStateRoundTripsThroughNodeStorage() {
        var card = FSRSCard.new(now: Date(timeIntervalSince1970: 1_800_000_000))
        let scheduler = FSRSScheduler()
        let result = scheduler.review(card, at: card.due, grade: .good)
        card = result.card
        let persisted = card.persisted()
        let restored = FSRSCard(persisted: persisted)
        #expect(restored == card)

        // Old files (no learningSteps key) decode as step 0.
        let legacy = FSRSState(
            due: card.due,
            stability: card.stability,
            difficulty: card.difficulty,
            scheduledDays: card.scheduledDays,
            reps: card.reps,
            lapses: card.lapses,
            state: card.state
        )
        #expect(FSRSCard(persisted: legacy).learningStep == 0)
    }

    // MARK: - Fixtures

    private func makeCard(seed: inout SeededGenerator) -> FSRSCard {
        var card = FSRSCard.new(now: Date(timeIntervalSince1970: 1_799_000_000))
        card.stability = Double.random(in: 0.001...36_500, using: &seed)
        card.difficulty = Double.random(in: 1...10, using: &seed)
        card.reps = Int.random(in: 0...100, using: &seed)
        card.lapses = Int.random(in: 0...10, using: &seed)
        card.lastReview = Date(timeIntervalSince1970: 1_799_000_000)
        let states: [FSRSStateKind] = [.new, .learning, .relearning, .review]
        card.state = states.randomElement(using: &seed)!
        card.learningStep = Int.random(in: 0...2, using: &seed)
        card.due = Date(timeIntervalSince1970: 1_799_000_000)
        return card
    }
}
