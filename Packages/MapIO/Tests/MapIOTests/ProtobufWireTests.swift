import Foundation
import Testing

@testable import MapIO

/// The protobuf wire reader (ADR-0035): every encoding round-trips,
/// every kind of structural damage throws instead of trapping, and
/// fuzzed bytes never crash the parse.
@Suite
struct ProtobufWireTests {
    // MARK: encodings

    @Test func varintsRoundTrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 0xFFFF, 0xFFFF_FFFF, .max] {
            let fields = try ProtobufWire.parse(Data(PB.varint(1, value)))
            #expect(fields.first?.value.varintValue == value)
        }
    }

    @Test func fixedWidthAndDelimitedFieldsRoundTrip() throws {
        let payload = Array("héllo 🌍".utf8)
        let bytes =
            PB.double(1, -23.5) + PB.bytes(2, payload)
            + [0x2D, 0x00, 0x00, 0x80, 0x3F]  // field 5, fixed32 1.0f
        let fields = try ProtobufWire.parse(Data(bytes))
        #expect(fields[0].number == 1)
        #expect(fields[0].wireType == .fixed64)
        #expect(fields.double(1) == -23.5)
        #expect(fields[1].wireType == .lengthDelimited)
        #expect(fields.bytes(2) == Data(payload))
        #expect(fields[2].number == 5)
        #expect(fields[2].wireType == .fixed32)
    }

    @Test func repeatedFieldsKeepTheirEncodedOrder() throws {
        let bytes = PB.varint(3, 10) + PB.varint(3, 20) + PB.varint(3, 30)
        let fields = try ProtobufWire.parse(Data(bytes))
        #expect(fields.all(3).map(\.number) == [3, 3, 3])
        #expect(fields.all(3).compactMap { $0.value.varintValue } == [10, 20, 30])
    }

    @Test func nestedMessagesRideAlongAndStringsStayOpaque() throws {
        let nested = PB.message(4, PB.bytes(1, Array("2b".utf8)))
        let bytes = PB.message(11, nested + PB.bytes(10, Array(repeating: 0x5A, count: 16)))
        let fields = try ProtobufWire.parse(Data(bytes))
        let containerOptional = try fields.message(11)
        let container = try #require(containerOptional)
        // The nested value message parses and rides along; the 16
        // style bytes do not parse as a message and stay opaque —
        // readable either way.
        let innerOptional = try container.message(4)
        let inner = try #require(innerOptional)
        #expect(inner.text(1) == "2b")
        #expect(container.bytes(10) == Data(repeating: 0x5A, count: 16))
    }

    @Test func emptyAndZeroLengthInputParseToNothing() throws {
        #expect(try ProtobufWire.parse(Data()) == [])
        #expect(try ProtobufWire.parse(Data(PB.bytes(7, []))).count == 1)
    }

    // MARK: structural damage

    @Test func truncatedInputThrows() throws {
        let whole = PB.message(1, PB.bytes(2, Array("My own thought 1".utf8))) + PB.varint(3, 7)
        let data = Data(whole)
        // Cuts inside the 20-byte first field are all truncated.
        for cut in 1..<20 {
            #expect(throws: ProtobufWire.ProtobufError.self) {
                _ = try ProtobufWire.parse(data.prefix(cut))
            }
        }
        // Every other prefix either throws or parses — never traps.
        for cut in 0...data.count where cut == 0 || cut >= 20 {
            if let fields = try? ProtobufWire.parse(data.prefix(cut)) {
                #expect(fields.count <= 2)
            }
        }
    }

    @Test func hugeDeclaredLengthsThrowInsteadOfAllocating() {
        // field 1, length-delimited, claiming ~4 GiB.
        var bomb: [UInt8] = [0x0A, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F]
        bomb.append(contentsOf: [UInt8](repeating: 0, count: 16))
        #expect(throws: ProtobufWire.ProtobufError.self) {
            _ = try ProtobufWire.parse(Data(bomb))
        }
    }

    @Test func fieldZeroGroupsAndBadWireTypesThrow() throws {
        // Field number 0.
        #expect(throws: ProtobufWire.ProtobufError.self) {
            _ = try ProtobufWire.parse(Data([0x00]))
        }
        // Wire type 3 (group start) and 6/7 (invalid).
        for key: UInt8 in [0x0B, 0x0C, 0x16, 0x17] {
            #expect(throws: ProtobufWire.ProtobufError.self) {
                _ = try ProtobufWire.parse(Data([key, 0x00]))
            }
        }
        // An over-long varint (11 continuation bytes).
        let longVarint = [UInt8](repeating: 0x80, count: 11) + [0x01]
        #expect(throws: ProtobufWire.ProtobufError.self) {
            _ = try ProtobufWire.parse(Data([0x08] + longVarint))
        }
    }

    @Test func oversizedMessagesAndFieldCountsAreRefused() throws {
        var strict = ProtobufWire.Limits.standard
        strict.maxBytes = 8
        #expect(throws: ProtobufWire.ProtobufError.messageTooLarge) {
            _ = try ProtobufWire.parse(Data(repeating: 0, count: 9), limits: strict)
        }
        strict.maxBytes = ProtobufWire.Limits.standard.maxBytes
        strict.maxFields = 3
        let spam = PB.varint(1, 1) + PB.varint(1, 1) + PB.varint(1, 1) + PB.varint(1, 1)
        #expect(throws: ProtobufWire.ProtobufError.tooManyFields) {
            _ = try ProtobufWire.parse(Data(spam), limits: strict)
        }
    }

    // MARK: nesting bombs and fuzz

    @Test func deeplyNestedInputIsBoundedNotFatal() throws {
        // 2 000 nested length-delimited messages: the reader descends
        // only to its depth cap and keeps the rest as opaque bytes —
        // no stack overflow, no runaway work.
        var bytes = PB.varint(1, 1)
        for _ in 0..<2_000 {
            bytes = PB.message(2, bytes)
        }
        let fields = try ProtobufWire.parse(Data(bytes))
        #expect(fields.count == 1)
        var depth = 0
        var level = fields
        while let next = level.first(where: { $0.number == 2 })?.value.nestedFields {
            depth += 1
            level = next
        }
        #expect(depth < ProtobufWire.Limits.standard.maxDepth)
    }

    @Test func fuzzedBytesNeverCrashTheReader() throws {
        // Deterministic LCG so a failure is reproducible.
        var seed: UInt64 = 0x00C0_FFEE
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        for _ in 0..<2_000 {
            let count = Int(next() % 600)
            var data = Data()
            data.reserveCapacity(count)
            for _ in 0..<count {
                data.append(UInt8(next() % 256))
            }
            // Whatever the bytes: parse either throws or returns.
            if let fields = try? ProtobufWire.parse(data) {
                #expect(fields.count <= ProtobufWire.Limits.standard.maxFields)
            }
        }
    }
}

// MARK: - test-only value accessors

extension ProtobufWire.Value {
    var varintValue: UInt64? {
        guard case .varint(let raw) = self else { return nil }
        return raw
    }

    var nestedFields: [ProtobufWire.Field]? {
        guard case .delimited(_, let nested) = self else { return nil }
        return nested
    }
}
