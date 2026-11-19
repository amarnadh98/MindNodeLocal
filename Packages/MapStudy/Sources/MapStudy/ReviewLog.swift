import Foundation
import MapCore

/// One record of the append-only `study/reviews.jsonl` log (SPEC §8.1, §10):
/// `{cardID, ts, grade, elapsed, stateBefore, stateAfter}`, one JSON object per
/// line with sorted keys and ISO-8601 UTC timestamps.
public struct ReviewLog: Sendable, Equatable, Codable {
    public let cardID: String
    public let ts: Date
    public let grade: Grade
    /// Whole days between the previous review and this one (0 for same-day).
    public let elapsed: Double
    public let stateBefore: FSRSStateKind
    public let stateAfter: FSRSStateKind

    public init(
        cardID: String,
        ts: Date,
        grade: Grade,
        elapsed: Double,
        stateBefore: FSRSStateKind,
        stateAfter: FSRSStateKind
    ) {
        self.cardID = cardID
        self.ts = ts
        self.grade = grade
        self.elapsed = elapsed
        self.stateBefore = stateBefore
        self.stateAfter = stateAfter
    }
}

/// A defect found while decoding `reviews.jsonl`.
public enum ReviewLogError: Error, Equatable, Sendable {
    /// A complete-looking line could not be decoded (1-based line number).
    /// A truncated final line is tolerated and never reported.
    case corruptLine(Int)
}

/// Encodes and decodes the append-only `reviews.jsonl` (SPEC §8.1):
/// one JSON object per line, sorted keys, ISO-8601 dates, tolerant of a
/// truncated last line (an interrupted append), since the log is append-only
/// and only its tail can be partial.
public enum ReviewLogCodec {
    /// `StudyDate` mirrors MapCore's `map.json` date format (ISO-8601 UTC with
    /// fractional seconds) so study files read consistently with the document.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func makeEncoder() throws -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = try? Date(raw, strategy: dateStyle) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid ISO-8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }

    /// Encodes `logs` as newline-delimited JSON with a trailing newline, the
    /// shape the document writer appends to.
    public static func encode(_ logs: [ReviewLog]) throws -> String {
        let encoder = try makeEncoder()
        var lines: [String] = []
        for log in logs {
            let data = try encoder.encode(log)
            guard let line = String(data: data, encoding: .utf8) else {
                throw CocoaError(.coderInvalidValue)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// Decodes the log. A final line that is truncated (never terminated by a
    /// valid JSON object) is skipped; a corrupt line anywhere else throws.
    public static func decode(_ text: String) throws -> [ReviewLog] {
        let decoder = makeDecoder()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var logs: [ReviewLog] = []
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let data = Data(line.utf8)
            guard let log = try? decoder.decode(ReviewLog.self, from: data) else {
                if lineNumber == lines.count {
                    return logs  // truncated append tail: tolerate and stop
                }
                throw ReviewLogError.corruptLine(lineNumber)
            }
            logs.append(log)
        }
        return logs
    }

    /// The bytes to append for one new review (newline-terminated single line).
    public static func appendLine(for log: ReviewLog) throws -> Data {
        let encoder = try makeEncoder()
        let data = try encoder.encode(log)
        return data + Data("\n".utf8)
    }
}
