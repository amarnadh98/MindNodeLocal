import Foundation
import Testing

@testable import MapStudy

@Test func reviewLogCodableRoundTrip() throws {
    let log = ReviewLog(
        cardID: "node-42",
        ts: Date(timeIntervalSinceReferenceDate: 1_000),
        grade: .good,
        stateBefore: .new,
        stateAfter: .learning
    )
    let data = try JSONEncoder().encode(log)
    let decoded = try JSONDecoder().decode(ReviewLog.self, from: data)
    #expect(decoded == log)
}

@Test func gradesCoverTheFSRSLadder() {
    #expect(Grade.allCases == [.again, .hard, .good, .easy])
}
