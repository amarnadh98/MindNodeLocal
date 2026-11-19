import Foundation
import MapCore

/// A fuzz random-number source: one uniform [0, 1) draw per seed string.
/// Injectable so hosts can pin or perturb fuzz deterministically; the default
/// is the reference's `fnv1a-mulberry32`. A single draw per seed is all the
/// scheduler ever needs — the reference invokes `rng(seed)()` once per
/// interval decision — and it keeps the closure stateless (strict concurrency).
public struct FuzzRNG: Sendable {
    public let draw: @Sendable (_ seed: String) -> Double

    public init(draw: @escaping @Sendable (_ seed: String) -> Double) {
        self.draw = draw
    }

    /// The reference RNG: FNV-1a over the seed's UTF-16 units feeding one
    /// mulberry32 step.
    public static let fnv1aMulberry32 = FuzzRNG { seed in
        var hash: UInt32 = 2_166_136_261
        for unit in seed.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 1_677_761_9
        }
        var mixed = hash &+ 1_831_565_813
        mixed = (mixed ^ (mixed >> 15)) &* (mixed | 1)
        mixed ^= mixed &+ ((mixed ^ (mixed >> 7)) &* (mixed | 61))
        return Double(mixed ^ (mixed >> 14)) / 4_294_967_296
    }
}

/// The FSRS-6 scheduler (SPEC §10): one grade in, the next card state out.
/// A faithful port of the reference implementation's default configuration
/// (`ts-fsrs` 6.0.0 legacy `FSRS` class / `BasicScheduler`, i.e.
/// `enable_short_term: true`), with fuzz OFF so scheduling is deterministic.
public struct FSRSScheduler: Sendable {
    /// Scheduler configuration, defaults per SPEC F-STD-3.
    public struct Options: Sendable {
        /// FSRS-6 weights `w[0…20]`.
        public var weights: [Double]
        /// Target retrievability when scheduling review intervals.
        public var desiredRetention: Double
        /// Cap for review-state intervals (days).
        public var maximumInterval: Int
        /// Learning steps in minutes (Anki-style: the delay shown after answering
        /// step k is `learningSteps[k]`).
        public var learningSteps: [Double]
        /// Relearning steps in minutes.
        public var relearningSteps: [Double]
        /// Enables same-day short-term scheduling.
        public var enableShortTerm: Bool
        /// Interval fuzzing; OFF by default so schedules are deterministic.
        public var enableFuzz: Bool
        /// The fuzz RNG; used only when `enableFuzz` is true.
        public var fuzzRNG: FuzzRNG

        public init(
            weights: [Double] = FSRSModel.defaultWeights,
            desiredRetention: Double = 0.9,
            maximumInterval: Int = 36_500,
            learningSteps: [Double] = [1, 10],
            relearningSteps: [Double] = [10],
            enableShortTerm: Bool = true,
            enableFuzz: Bool = false,
            fuzzRNG: FuzzRNG = .fnv1aMulberry32
        ) {
            self.weights = weights
            self.desiredRetention = desiredRetention
            self.maximumInterval = maximumInterval
            self.learningSteps = learningSteps
            self.relearningSteps = relearningSteps
            self.enableShortTerm = enableShortTerm
            self.enableFuzz = enableFuzz
            self.fuzzRNG = fuzzRNG
        }

        /// Options from the document's `studySettings` (SPEC §8.2); only the
        /// desired retention applies to the scheduler.
        public init(studySettings: StudySettings?) {
            self.init(desiredRetention: studySettings?.retention ?? 0.9)
        }
    }

    /// The outcome of one review: the next card plus the details the
    /// review log needs (SPEC §8.1, §10).
    public struct Review: Sendable, Equatable {
        public let card: FSRSCard
        public let grade: Grade
        public let reviewDate: Date
        public let stateBefore: FSRSStateKind
        public let stateAfter: FSRSStateKind
        /// Whole days between the previous review and this one, as the scheduler
        /// measured them (UTC calendar days, like the reference `init()`).
        public let elapsedDays: Double
        public let stabilityBefore: Double
        public let difficultyBefore: Double
        public let scheduledDaysBefore: Double

        /// The append-only `reviews.jsonl` record for this review.
        public func record(cardID: String) -> ReviewLog {
            ReviewLog(
                cardID: cardID,
                ts: reviewDate,
                grade: grade,
                elapsed: elapsedDays,
                stateBefore: stateBefore,
                stateAfter: stateAfter
            )
        }
    }

    public let options: Options
    private let model: FSRSModel

    public init(options: Options = Options()) {
        self.options = options
        self.model = FSRSModel(weights: options.weights, enableShortTerm: options.enableShortTerm)
    }

    /// Predicted recall probability now: 0 for never-reviewed cards, otherwise
    /// the forgetting curve at the number of whole 24-hour periods since the
    /// last review (the reference `FSRS.retrievability`).
    public func retrievability(of card: FSRSCard, at now: Date) -> Double {
        guard card.state != .new, let lastReview = card.lastReview, card.stability > 0 else { return 0 }
        let elapsed = max(floor(now.timeIntervalSince(lastReview) / 86_400), 0)
        return model.retrievability(elapsedDays: elapsed, stability: card.stability)
    }

    /// Schedules `card` for the given `grade` answered at `now`, returning the
    /// next card state.
    public func review(_ card: FSRSCard, at now: Date, grade: Grade) -> Review {
        let elapsed = elapsedDays(of: card, at: now)
        var next = card
        next.reps = card.reps + 1
        next.lastReview = now
        let seed = fuzzSeed(now: now, reps: next.reps, difficulty: card.difficulty, stability: card.stability)

        switch card.state {
        case .new:
            let memory = model.nextMemoryState(difficulty: 0, stability: 0, elapsedDays: 0, grade: grade)
            next.difficulty = memory.difficulty
            next.stability = memory.stability
            applyLearningSteps(
                &next, stateBefore: .new, grade: grade, toState: .learning, at: now, elapsed: elapsed, seed: seed
            )

        case .learning, .relearning:
            let memory = model.nextMemoryState(
                difficulty: card.difficulty,
                stability: card.stability,
                elapsedDays: elapsed,
                grade: grade
            )
            next.difficulty = memory.difficulty
            next.stability = memory.stability
            applyLearningSteps(
                &next, stateBefore: card.state, grade: grade, toState: card.state, at: now, elapsed: elapsed, seed: seed
            )

        case .review:
            let retrievability = model.retrievability(elapsedDays: elapsed, stability: card.stability)
            if grade == .again {
                let memory = model.nextMemoryState(
                    difficulty: card.difficulty,
                    stability: card.stability,
                    elapsedDays: elapsed,
                    grade: .again,
                    retrievability: retrievability
                )
                next.difficulty = memory.difficulty
                next.stability = memory.stability
                applyLearningSteps(
                    &next, stateBefore: .review, grade: .again, toState: .relearning, at: now, elapsed: elapsed,
                    seed: seed
                )
                next.lapses = card.lapses + 1
            } else {
                var intervals: [Double] = []
                var memories: [Grade: (difficulty: Double, stability: Double)] = [:]
                for candidateGrade in [Grade.hard, .good, .easy] {
                    let memory = model.nextMemoryState(
                        difficulty: card.difficulty,
                        stability: card.stability,
                        elapsedDays: elapsed,
                        grade: candidateGrade,
                        retrievability: retrievability
                    )
                    memories[candidateGrade] = memory
                    intervals.append(rawInterval(memory.stability, elapsed: elapsed, seed: seed))
                }
                intervals = monotonicScheduleDays(intervals, maximumInterval: Double(options.maximumInterval))
                let memory = memories[grade] ?? memories[.good]!
                next.difficulty = memory.difficulty
                next.stability = memory.stability
                next.state = .review
                next.learningStep = 0
                let slot = Grade.ascending.firstIndex(of: grade)! - 1
                next.scheduledDays = intervals[slot]
                next.due = now.addingTimeInterval(next.scheduledDays * 86_400)
            }
        }

        return Review(
            card: next,
            grade: grade,
            reviewDate: now,
            stateBefore: card.state,
            stateAfter: next.state,
            elapsedDays: elapsed,
            stabilityBefore: card.stability,
            difficultyBefore: card.difficulty,
            scheduledDaysBefore: card.scheduledDays
        )
    }

    // MARK: - Learning steps

    /// The per-grade learning-step schedule for a card in `stateBefore` at
    /// `learningStep`, in minutes (the reference `calculateLearningSteps`).
    private func learningStepSchedule(
        stateBefore: FSRSStateKind,
        learningStep: Int
    ) -> [Grade: (minutes: Double, nextStep: Int)] {
        let steps =
            (stateBefore == .relearning || stateBefore == .review)
            ? options.relearningSteps : options.learningSteps
        guard !steps.isEmpty, learningStep < steps.count else { return [:] }
        if stateBefore == .review {
            return [.again: (steps[learningStep], 0)]
        }
        let first = steps[0]
        let second = steps.count > 1 ? steps[1] : nil
        let hard = second.map { (first + $0) / 2 } ?? first * 1.5
        var schedule: [Grade: (minutes: Double, nextStep: Int)] = [
            .again: (first, 0),
            .hard: (hard, learningStep),
        ]
        if learningStep + 1 < steps.count {
            let nextMinutes = steps[learningStep + 1]
            if nextMinutes > 0 {
                schedule[.good] = (nextMinutes, learningStep + 1)
            }
        }
        return schedule
    }

    /// Applies the learning-step schedule: a step delay keeps the card in
    /// `toState`; a grade without a step (or an empty step list) graduates it
    /// to the review state at the model interval.
    private func applyLearningSteps(
        _ next: inout FSRSCard,
        stateBefore: FSRSStateKind,
        grade: Grade,
        toState: FSRSStateKind,
        at now: Date,
        elapsed: Double,
        seed: String
    ) {
        let step = learningStepSchedule(stateBefore: stateBefore, learningStep: next.learningStep)[grade]
            .map { step in (minutes: jsRound(max(0, step.minutes) * 60) / 60, nextStep: step.nextStep) }
        if let step, step.minutes > 0, step.minutes < 1440 {
            next.learningStep = step.nextStep
            next.scheduledDays = 0
            next.state = toState
            next.due = now.addingTimeInterval(step.minutes * 60)
        } else {
            next.state = .review
            if let step, step.minutes >= 1440 {
                next.learningStep = step.nextStep
                next.due = now.addingTimeInterval(step.minutes * 60)
                next.scheduledDays = floor(step.minutes / 1440)
            } else {
                next.learningStep = 0
                let interval = rawInterval(next.stability, elapsed: elapsed, seed: seed)
                next.scheduledDays = interval
                next.due = now.addingTimeInterval(interval * 86_400)
            }
        }
    }

    // MARK: - Intervals

    /// The model interval for `stability`, fuzzed when enabled
    /// (the reference `scheduler_next_interval` + `withFuzzing`).
    private func rawInterval(_ stability: Double, elapsed: Double, seed: String) -> Double {
        let base = model.nextInterval(stability: stability, desiredRetention: options.desiredRetention)
        guard options.enableFuzz, base >= 2.5 else { return jsRound(base) }
        let range = fuzzRange(of: base, elapsed: elapsed)
        let draw = options.fuzzRNG.draw(seed)
        return floor(draw * (range.max - range.min + 1) + range.min)
    }

    /// The reference `getFuzzRange` (SPEC F-STD-3 "optional fuzz").
    private func fuzzRange(of interval: Double, elapsed: Double) -> (min: Double, max: Double) {
        let ranges: [(start: Double, end: Double, factor: Double)] = [
            (2.5, 7, 0.15),
            (7, 20, 0.1),
            (20, .infinity, 0.05),
        ]
        var delta = 1.0
        for range in ranges {
            delta += range.factor * max(min(interval, range.end) - range.start, 0)
        }
        let capped = min(interval, Double(options.maximumInterval))
        var minInterval = max(2, jsRound(capped - delta))
        let maxInterval = min(jsRound(capped + delta), Double(options.maximumInterval))
        if capped > elapsed {
            minInterval = max(minInterval, elapsed + 1)
        }
        return (min(minInterval, maxInterval), maxInterval)
    }

    // MARK: - Reference details

    /// Elapsed days as the reference scheduler measures them: whole UTC
    /// calendar days since the last review (`dateDiffInDays`), 0 for new cards.
    private func elapsedDays(of card: FSRSCard, at now: Date) -> Double {
        guard card.state != .new, let lastReview = card.lastReview else { return 0 }
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let lastDay = utcCalendar.startOfDay(for: lastReview)
        let nowDay = utcCalendar.startOfDay(for: now)
        return Double(utcCalendar.dateComponents([.day], from: lastDay, to: nowDay).day ?? 0)
    }

    /// The legacy reference fuzz seed: review time, reps and memory state.
    private func fuzzSeed(now: Date, reps: Int, difficulty: Double, stability: Double) -> String {
        "\(Int64(now.timeIntervalSince1970 * 1000))_\(reps)_\(difficulty * stability)"
    }
}

/// The reference `calculateScheduleDays`: keeps `hard`/`good`/`easy` intervals
/// monotone (each at least one day past the previous) and caps them at
/// `maximumInterval`.
private func monotonicScheduleDays(_ candidates: [Double], maximumInterval: Double) -> [Double] {
    let first = min(candidates[0], maximumInterval)
    let second = min(max(candidates[1], first == 0 ? 0 : first + 1), maximumInterval)
    let third = min(max(candidates[2], second == 0 ? 0 : second + 1), maximumInterval)
    return [first, second, third]
}
