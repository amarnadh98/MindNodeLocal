import Foundation

/// Encodes and decodes `map.json` deterministically: UTF-8, pretty-printed,
/// sorted keys, ISO-8601 dates with fractional seconds.
public enum MapDocumentCoder {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(CodableDate.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = CodableDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid ISO-8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }

    public static func encode(_ model: MapModel) throws -> Data {
        try makeEncoder().encode(model)
    }

    public static func encodeString(_ model: MapModel) throws -> String {
        guard let text = String(data: try encode(model), encoding: .utf8) else {
            throw ArborError.invalidMapJSON("map.json is not valid UTF-8")
        }
        return text
    }

    public static func decode(_ data: Data) throws -> MapModel {
        do {
            return try makeDecoder().decode(MapModel.self, from: data)
        } catch let error as DecodingError {
            throw ArborError.invalidMapJSON(String(describing: error))
        }
    }

    public static func roundTrip(_ model: MapModel) throws -> MapModel {
        try decode(try encode(model))
    }
}

/// `Date.ISO8601FormatStyle` is a Sendable value type, so one shared style
/// instance serves every encode and decode without per-date formatter
/// allocation (SPEC §11.8 open budget). Its parser accepts both fractional
/// and plain ISO-8601 timestamps.
enum CodableDate {
    private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func string(from date: Date) -> String {
        date.formatted(style)
    }

    static func parse(_ raw: String) -> Date? {
        try? Date(raw, strategy: style)
    }
}

public struct PackageMeta: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var appVersion: String
    public var created: Date
    public var modified: Date
    public var docID: String
    /// Who last mutated the document (F-AI-5): `nil` for pre-AI files,
    /// `.user` for every user edit, `.ai` after an AI mutation. A
    /// journal-only field — the save stamps the author of the most
    /// recent change, it is not a per-change history.
    public var lastModifiedBy: AuthorKind?

    public init(
        formatVersion: Int = ArborFormat.formatVersion,
        appVersion: String = "0.1.0",
        created: Date = Date(),
        modified: Date = Date(),
        docID: String,
        lastModifiedBy: AuthorKind? = nil
    ) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.created = created
        self.modified = modified
        self.docID = docID
        self.lastModifiedBy = lastModifiedBy
    }
}
