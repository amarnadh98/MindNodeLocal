import Foundation
import MapCore
import Testing

@testable import MapStudy

@Test func gradesCoverTheFSRSLadder() {
    #expect(Grade.allCases == [.again, .hard, .good, .easy])
}

@Test func reviewLogCodableRoundTrip() throws {
    let log = ReviewLog(
        cardID: "node-42",
        ts: Date(timeIntervalSinceReferenceDate: 1_000),
        grade: .good,
        elapsed: 3,
        stateBefore: .new,
        stateAfter: .learning
    )
    let data = try JSONEncoder().encode(log)
    let decoded = try JSONDecoder().decode(ReviewLog.self, from: data)
    #expect(decoded == log)
}

@Test func jsonlRoundTripPreservesOrderAndFormat() throws {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let logs = [
        ReviewLog(cardID: "b", ts: base, grade: .good, elapsed: 0, stateBefore: .new, stateAfter: .learning),
        ReviewLog(
            cardID: "a#c1", ts: base.addingTimeInterval(60), grade: .again, elapsed: 0, stateBefore: .review,
            stateAfter: .relearning),
        ReviewLog(
            cardID: "a", ts: base.addingTimeInterval(600), grade: .easy, elapsed: 12, stateBefore: .learning,
            stateAfter: .review),
    ]
    let text = try ReviewLogCodec.encode(logs)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 3)
    #expect(text.hasSuffix("\n"), "jsonl files end with a newline for appends")

    // One JSON object per line, keys sorted (SPEC §8.1).
    #expect(lines[0].hasPrefix("{\"cardID\":"))
    #expect(lines[1].contains("\"elapsed\""))
    #expect(
        lines[1].range(of: "\"grade\".*\"stateAfter\".*\"stateBefore\".*\"ts\"", options: .regularExpression) != nil)

    let decoded = try ReviewLogCodec.decode(text)
    #expect(decoded == logs)
}

@Test func jsonlToleratesTruncatedLastLine() throws {
    let logs = [
        ReviewLog(
            cardID: "a", ts: Date(timeIntervalSince1970: 1_800_000_000), grade: .good, elapsed: 0, stateBefore: .new,
            stateAfter: .learning),
        ReviewLog(
            cardID: "b", ts: Date(timeIntervalSince1970: 1_800_000_060), grade: .hard, elapsed: 1,
            stateBefore: .learning, stateAfter: .review),
    ]
    let text = try ReviewLogCodec.encode(logs)

    // Half a line lost to an interrupted append.
    let truncated = String(text.dropLast(20))
    let decoded = try ReviewLogCodec.decode(truncated)
    #expect(decoded == [logs[0]])

    // A cut that lands inside the last line's JSON but past its newline is fine too.
    let cutAtNewline = String(text.dropLast(25))
    #expect(try ReviewLogCodec.decode(cutAtNewline).count >= 1)
}

@Test func jsonlRejectsCorruptMiddleLine() throws {
    let good = ReviewLog(
        cardID: "a", ts: Date(timeIntervalSince1970: 1_800_000_000), grade: .good, elapsed: 0, stateBefore: .new,
        stateAfter: .learning
    )
    let goodLine = String(data: try ReviewLogCodec.appendLine(for: good).dropLast(), encoding: .utf8)!
    let text = goodLine + "\nnot json at all\n" + goodLine + "\n"
    #expect(throws: ReviewLogError.corruptLine(2)) {
        _ = try ReviewLogCodec.decode(text)
    }
}

@Test func schedulerReviewsProduceLogRecords() {
    let scheduler = FSRSScheduler()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = scheduler.review(FSRSCard.new(now: now), at: now, grade: .good)
    let record = first.record(cardID: "n1")
    #expect(record.cardID == "n1")
    #expect(record.grade == .good)
    #expect(record.stateBefore == .new)
    #expect(record.stateAfter == .learning)
    #expect(record.elapsed == 0)
    #expect(record.ts == now)

    // Graduate to review (second good, same day), then lapse a day later:
    // the record carries the elapsed UTC calendar days and both states.
    let graduated = scheduler.review(first.card, at: now.addingTimeInterval(600), grade: .good)
    #expect(graduated.card.state == .review)
    let lapse = scheduler.review(graduated.card, at: now.addingTimeInterval(86_400), grade: .again)
    let lapseRecord = lapse.record(cardID: "n1")
    #expect(lapseRecord.elapsed == 1)
    #expect(lapseRecord.stateBefore == .review)
    #expect(lapseRecord.stateAfter == .relearning)
}
