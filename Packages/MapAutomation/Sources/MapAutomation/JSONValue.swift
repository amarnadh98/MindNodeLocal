import Foundation

/// A JSON value tree: what MCP arguments, tool results and the socket
/// frames carry. Decoding is permissive (an `Int` that fits decodes as
/// `.number`), encoding emits sorted keys so output is deterministic and
/// diffable — the same policy `map.json` uses (SPEC §8.1).
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: accessors

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Any numeric payload as `Double` (JSON has one number type).
    public var number: Double? {
        switch self {
        case .number(let value): value
        case .bool, .string, .array, .object, .null: nil
        }
    }

    public var intValue: Int? {
        guard let value = number, value.rounded() == value, abs(value) < 9.007199254740992e15 else {
            return nil
        }
        return Int(value)
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integral values render without a decimal point, matching
            // every JSON encoder's output for integer literals.
            if value.rounded() == value && abs(value) < 9.007199254740992e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        var values: [String: JSONValue] = [:]
        for (key, value) in pairs {
            values[key] = value ?? .null
        }
        return .object(values)
    }

    /// Integral sugar so `JSONValue.number(3)` reads as an integer literal.
    public static func number(_ value: Int) -> JSONValue {
        .number(Double(value))
    }
}

/// JSON coding for `JSONValue` (and any Codable) with the MapCore policy:
/// sorted keys, no pretty-printing — one compact line, which is also what
/// the newline-delimited stdio transport requires.
public enum JSONLine {
    public static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> JSONValue {
        let decoder = JSONDecoder()
        return try decoder.decode(JSONValue.self, from: Data(text.utf8))
    }

    public static func decode<T: Decodable>(_ text: String, as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(text.utf8))
    }
}
