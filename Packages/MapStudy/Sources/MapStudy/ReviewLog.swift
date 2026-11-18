import Foundation

/// A reviewer's answer quality during a study session.
public enum Grade: String, Sendable, CaseIterable, Codable {
    case again
    case hard
    case good
    case easy
}

/// The scheduling state a card is in.
public enum CardState: String, Sendable, Codable {
    case new
    case learning
    case review
    case relearning
}

/// One scheduled review of a card (SPEC §5.14).
public struct ReviewLog: Sendable, Equatable, Codable {
    public let cardID: String
    public let ts: Date
    public let grade: Grade
    public let stateBefore: CardState
    public let stateAfter: CardState

    public init(
        cardID: String,
        ts: Date,
        grade: Grade,
        stateBefore: CardState,
        stateAfter: CardState
    ) {
        self.cardID = cardID
        self.ts = ts
        self.grade = grade
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
    }
}
