import Foundation

/// A strict, fully bounds-checked Protocol Buffers **wire-format**
/// reader — no `.proto` compiler, no generated types, no third-party
/// dependency (SPEC §11.1 budget; ADR-0035). It knows only the three
/// wire encodings every producer emits — varint, fixed32/64,
/// length-delimited — and deliberately refuses the rest (groups,
/// invalid wire types, field number 0), because malformed or hostile
/// bytes are an expected input and must never crash an importer.
///
/// The reader is *generic*: it returns the field tree and lets the
/// caller (e.g. the MindNode current-format decoder) interpret the
/// field numbers. Length-delimited payloads keep their raw bytes, and
/// when those bytes also parse cleanly as a nested message the parsed
/// fields ride along (`nested`); a payload that does not parse stays
/// opaque bytes, so a string that happens to look like a message is
/// never destroyed. Recursion is capped (`Limits.maxDepth`): a
/// deeply-nested bomb neither overflows the stack nor spins — fields
/// at the cap are kept as plain bytes and never descended into.
///
/// Pure type: `import Foundation` only, nothing AppKit, so `MapIO`
/// stays command-line testable (SPEC §11.2).
enum ProtobufWire {
    /// The wire types the reader accepts. 3/4 (groups) and 6/7 are
    /// rejected as malformed — proto3 never emits them and no importer
    /// should ever honor them.
    enum WireType: UInt8, Sendable {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    /// One decoded field: the field number, its wire type and value,
    /// in stream order (repeated fields keep their encoded order).
    struct Field: Sendable, Equatable {
        let number: Int
        let wireType: WireType
        let value: Value
    }

    /// A field's value. `delimited` always carries the raw payload;
    /// `nested` is set only when that payload parses cleanly as a
    /// message within the depth budget.
    enum Value: Sendable, Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case delimited(data: Data, nested: [Field]?)
    }

    /// Defensive caps. Real map documents are a few hundred KiB; a
    /// crafted archive claiming more than `maxBytes`, a message with
    /// more than `maxFields` records, or nesting beyond `maxDepth` is
    /// refused rather than parsed.
    struct Limits: Sendable {
        var maxDepth: Int
        var maxFields: Int
        var maxBytes: Int

        static let standard = Limits(maxDepth: 48, maxFields: 1_000_000, maxBytes: 64 << 20)
    }

    enum ProtobufError: Error, Equatable, Sendable {
        /// The buffer ends mid-field (truncated varint, fixed value or
        /// length-delimited payload).
        case truncated
        /// A varint longer than the 10 bytes a UInt64 needs.
        case varintTooLong
        /// A group start/end marker (wire type 3/4) or an invalid wire
        /// type (6/7).
        case unsupportedWireType(UInt8)
        /// Protobuf field numbers start at 1.
        case invalidFieldNumber(Int)
        /// More fields in one message than `Limits.maxFields`.
        case tooManyFields
        /// The input (or a nested payload) exceeds `Limits.maxBytes`.
        case messageTooLarge
    }

    /// Decodes `data` as one protobuf message. Throws `ProtobufError`
    /// on any structural damage; never traps on any byte sequence.
    static func parse(_ data: Data, depth: Int = 0, limits: Limits = .standard) throws -> [Field] {
        guard data.count <= limits.maxBytes else { throw ProtobufError.messageTooLarge }
        var fields: [Field] = []
        var cursor = data.startIndex

        while cursor < data.endIndex {
            // Every field starts with the key: a varint of
            // (field_number << 3) | wire_type.
            let (key, afterKey) = try readVarint(data, at: cursor)
            cursor = afterKey
            let number = Int(key >> 3)
            let rawWire = UInt8(key & 0x7)
            guard number > 0 else { throw ProtobufError.invalidFieldNumber(number) }
            guard let wireType = WireType(rawValue: rawWire) else {
                throw ProtobufError.unsupportedWireType(rawWire)
            }

            let value: Value
            switch wireType {
            case .varint:
                let (varint, after) = try readVarint(data, at: cursor)
                cursor = after
                value = .varint(varint)
            case .fixed64:
                let payload = try fixedBytes(data, at: cursor, count: 8)
                cursor = payload.endIndex
                value = .fixed64(
                    UInt64(
                        littleEndian: payload.withUnsafeBytes {
                            $0.loadUnaligned(as: UInt64.self)
                        }))
            case .fixed32:
                let payload = try fixedBytes(data, at: cursor, count: 4)
                cursor = payload.endIndex
                value = .fixed32(
                    UInt32(
                        littleEndian: payload.withUnsafeBytes {
                            $0.loadUnaligned(as: UInt32.self)
                        }))
            case .lengthDelimited:
                let (length, afterLength) = try readVarint(data, at: cursor)
                guard length <= UInt64(data.endIndex - afterLength) else {
                    throw ProtobufError.truncated
                }
                let payloadEnd = data.index(afterLength, offsetBy: Int(length))
                let payload = data[afterLength..<payloadEnd]
                cursor = payloadEnd
                value = .delimited(
                    data: Data(payload),
                    nested: nestedAttempt(payload, depth: depth, limits: limits))
            }
            fields.append(Field(number: number, wireType: wireType, value: value))
            guard fields.count <= limits.maxFields else { throw ProtobufError.tooManyFields }
        }
        return fields
    }

    /// Tries a payload as a nested message *without* failing the
    /// outer parse: only a payload that consumes cleanly becomes
    /// `nested`, everything else stays opaque bytes. At the depth cap
    /// nothing is attempted, so recursion is bounded by construction.
    private static func nestedAttempt(
        _ payload: Data.SubSequence, depth: Int, limits: Limits
    ) -> [Field]? {
        guard depth + 1 < limits.maxDepth, !payload.isEmpty else { return nil }
        // A parse failure of any kind leaves the payload opaque — the
        // caller keeps the raw bytes and decides what they mean.
        return try? parse(Data(payload), depth: depth + 1, limits: limits)
    }

    // MARK: Bounds-checked primitives

    /// Reads one base-128 varint. A varint is at most ⌈64/7⌉ = 10
    /// bytes; a longer continuation is damaged input.
    private static func readVarint(_ data: Data, at index: Data.Index) throws -> (UInt64, Data.Index) {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var cursor = index
        while true {
            guard cursor < data.endIndex else { throw ProtobufError.truncated }
            let byte = data[cursor]
            data.formIndex(after: &cursor)
            if shift >= 64 { throw ProtobufError.varintTooLong }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, cursor) }
            shift += 7
        }
    }

    /// Slices exactly `count` bytes at `index`, throwing when the
    /// buffer ends early.
    private static func fixedBytes(_ data: Data, at index: Data.Index, count: Int) throws
        -> Data.SubSequence
    {
        guard
            let end = data.index(index, offsetBy: count, limitedBy: data.endIndex)
        else { throw ProtobufError.truncated }
        return data[index..<end]
    }
}

// MARK: - Field access for schema decoders

/// The lookups a hand-written schema decoder needs over a parsed
/// field list. Each getter returns the first field with that number
/// in the requested shape; `all` returns every occurrence in stream
/// order (repeated fields keep their encoded order — that order is
/// data, e.g. MindNode's child lists).
extension [ProtobufWire.Field] {
    func all(_ number: Int) -> [ProtobufWire.Field] {
        filter { $0.number == number }
    }

    func first(_ number: Int) -> ProtobufWire.Field? {
        first { $0.number == number }
    }

    /// The first varint field `number`, as `Int` (truncating).
    func varint(_ number: Int) -> Int? {
        guard case .varint(let raw)? = first(number)?.value else { return nil }
        return Int(clamping: raw)
    }

    /// The first fixed64 field `number` read as a little-endian
    /// IEEE-754 double (protobuf's `double`).
    func double(_ number: Int) -> Double? {
        guard case .fixed64(let raw)? = first(number)?.value else { return nil }
        return Double(bitPattern: raw)
    }

    /// The first length-delimited field `number` as raw bytes.
    func bytes(_ number: Int) -> Data? {
        guard case .delimited(let data, _)? = first(number)?.value else { return nil }
        return data
    }

    /// The first length-delimited field `number` as UTF-8 text.
    func text(_ number: Int) -> String? {
        guard let data = bytes(number) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The first length-delimited field `number` as a nested message,
    /// parsing it on demand when the auto-attempt kept it opaque
    /// (payloads at the depth cap stay opaque; a schema decoder that
    /// knows better may still descend one more level).
    func message(_ number: Int) throws -> [ProtobufWire.Field]? {
        guard let field = first(number) else { return nil }
        if case .delimited(_, let nested?) = field.value { return nested }
        guard case .delimited(let data, _) = field.value else { return nil }
        return try ProtobufWire.parse(data)
    }
}
