import Foundation
import MapCore

/// A card's scheduling state — the port of the reference `Card`
/// (`ts-fsrs` 6.0.0, legacy shape), stored per card on its node (SPEC §10).
public struct FSRSCard: Sendable, Equatable, Codable {
    /// When the card is next due.
    public var due: Date
    /// Memory stability, in days (the interval at 90% retrievability).
    public var stability: Double
    /// Memory difficulty, in [1, 10].
    public var difficulty: Double
    /// The scheduled interval of the current due date, in days (0 for learning steps).
    public var scheduledDays: Double
    /// Total reviews.
    public var reps: Int
    /// Total lapses (reviews of a review-state card answered `again`).
    public var lapses: Int
    /// Index into the learning/relearning step list.
    public var learningStep: Int
    /// The scheduling state.
    public var state: FSRSStateKind
    /// The previous review, or nil for a never-reviewed card.
    public var lastReview: Date?

    public init(
        due: Date,
        stability: Double = 0,
        difficulty: Double = 0,
        scheduledDays: Double = 0,
        reps: Int = 0,
        lapses: Int = 0,
        learningStep: Int = 0,
        state: FSRSStateKind = .new,
        lastReview: Date? = nil
    ) {
        self.due = due
        self.stability = stability
        self.difficulty = difficulty
        self.scheduledDays = scheduledDays
        self.reps = reps
        self.lapses = lapses
        self.learningStep = learningStep
        self.state = state
        self.lastReview = lastReview
    }

    /// A fresh, never-reviewed card due `now` (the reference `createEmptyCard`).
    public static func new(now: Date) -> FSRSCard {
        FSRSCard(due: now)
    }
}

extension FSRSCard {
    /// Builds the card from the state persisted on a node (SPEC §8.2 `study.fsrs`).
    /// `elapsedDays` is not read back: the scheduler always derives it from `lastReview`.
    public init(persisted state: FSRSState) {
        self.init(
            due: state.due,
            stability: state.stability,
            difficulty: state.difficulty,
            scheduledDays: state.scheduledDays,
            reps: state.reps,
            lapses: state.lapses,
            learningStep: state.learningSteps ?? 0,
            state: state.state,
            lastReview: state.lastReview
        )
    }

    /// The state to persist on the node. `elapsedDays` is a snapshot field in the
    /// on-disk schema (SPEC F-STD-3) and is derived at review time, so it is
    /// written as 0 here; `learningSteps` preserves the learning-step position.
    public func persisted() -> FSRSState {
        FSRSState(
            due: due,
            stability: stability,
            difficulty: difficulty,
            elapsedDays: 0,
            scheduledDays: scheduledDays,
            reps: reps,
            lapses: lapses,
            state: state,
            lastReview: lastReview,
            learningSteps: learningStep
        )
    }
}
