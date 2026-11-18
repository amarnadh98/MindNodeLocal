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

enum CodableDate {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        return plain.date(from: raw)
    }
}

public struct PackageMeta: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var appVersion: String
    public var created: Date
    public var modified: Date
    public var docID: String

    public init(
        formatVersion: Int = ArborFormat.formatVersion,
        appVersion: String = "0.1.0",
        created: Date = Date(),
        modified: Date = Date(),
        docID: String
    ) {
        self.formatVersion = formatVersion
        self.appVersion = appVersion
        self.created = created
        self.modified = modified
        self.docID = docID
    }
}
