import Compression
import Foundation

/// A minimal read-only ZIP reader for the import-only container formats
/// (`.xmind`, SPEC §5.17). It supports the two methods every producer
/// writes — stored (0) and raw DEFLATE (8) — decoding DEFLATE with
/// Apple's `Compression` framework (whose `COMPRESSION_ZLIB` is raw
/// DEFLATE without the zlib wrapper, exactly what ZIP stores), and
/// verifies every entry's CRC-32. This keeps Arbor free of a third-party
/// zip dependency for import (ADR-0010). ZIP *writing* is not needed:
/// the formats that produce archives are import-only.
enum MiniZip {
    struct Entry: Equatable, Sendable {
        let name: String
        let data: Data
    }

    enum ZipError: Error, Equatable, Sendable {
        case notAZipFile
        case corruptEntry(String)
        case unsupportedCompression(String, method: UInt16)
        case crcMismatch(String)
    }

    /// The archive's entries in central-directory order. Throws on any
    /// structural damage — malformed archives are an expected input and
    /// must never crash the importer.
    static func entries(of archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        guard let end = findEndOfCentralDirectory(in: bytes) else {
            throw ZipError.notAZipFile
        }
        let entryCount = try readUInt16(bytes, at: end + 10)
        var entries: [Entry] = []
        var cursor = try Int(readUInt32(bytes, at: end + 16))
        for _ in 0..<entryCount {
            guard try readUInt32(bytes, at: cursor) == centralDirectorySignature else {
                throw ZipError.notAZipFile
            }
            let method = try readUInt16(bytes, at: cursor + 10)
            let crc = try readUInt32(bytes, at: cursor + 16)
            let compressedSize = try Int(readUInt32(bytes, at: cursor + 20))
            let uncompressedSize = try Int(readUInt32(bytes, at: cursor + 24))
            let nameLength = try Int(readUInt16(bytes, at: cursor + 28))
            let extraLength = try Int(readUInt16(bytes, at: cursor + 30))
            let commentLength = try Int(readUInt16(bytes, at: cursor + 32))
            let localOffset = try Int(readUInt32(bytes, at: cursor + 42))
            let nameStart = try checked(cursor + 46, plus: nameLength, in: bytes)
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)

            let content = try entryData(
                bytes, localOffset: localOffset, compressedSize: compressedSize,
                uncompressedSize: uncompressedSize, method: method, name: name)
            guard UInt32(truncatingIfNeeded: crc32(content)) == crc else {
                throw ZipError.crcMismatch(name)
            }
            entries.append(Entry(name: name, data: content))
            let commentStart = try checked(
                nameStart + nameLength + extraLength, plus: commentLength, in: bytes)
            cursor = commentStart + commentLength
        }
        return entries
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50

    /// The EOCD record is in the last 64 KiB + 22 bytes; scan backwards.
    private static func findEndOfCentralDirectory(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var index = bytes.count - 22
        let lowerBound = max(0, bytes.count - 22 - 65_536)
        while index >= lowerBound {
            if littleEndian32(bytes, at: index) == endOfCentralDirectorySignature {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func entryData(
        _ bytes: [UInt8], localOffset: Int, compressedSize: Int, uncompressedSize: Int,
        method: UInt16, name: String
    ) throws -> Data {
        guard try readUInt32(bytes, at: localOffset) == localFileHeaderSignature else {
            throw ZipError.corruptEntry(name)
        }
        let nameLength = try Int(readUInt16(bytes, at: localOffset + 26))
        let extraLength = try Int(readUInt16(bytes, at: localOffset + 28))
        let dataStart = try checked(localOffset + 30 + nameLength, plus: extraLength, in: bytes)
        _ = try checked(dataStart, plus: compressedSize, in: bytes)
        let raw = Data(bytes[dataStart..<dataStart + compressedSize])
        switch method {
        case 0:
            return raw
        case 8:
            return try inflate(raw, uncompressedSize: uncompressedSize, name: name)
        default:
            throw ZipError.unsupportedCompression(name, method: method)
        }
    }

    /// Raw DEFLATE via `compression_decode_buffer`. Returns 0 when the
    /// stream is damaged or the destination is too small.
    /// 256 MB: far above any real map document entry.
    static let maxEntrySize = 256 << 20

    private static func inflate(
        _ data: Data, uncompressedSize: Int, name: String
    ) throws -> Data {
        guard !data.isEmpty else { return Data() }
        // The header's size is untrusted input; refuse entries no mind map
        // needs rather than allocate whatever a crafted archive claims.
        guard uncompressedSize <= maxEntrySize else { throw ZipError.corruptEntry(name) }
        let capacity = min(max(uncompressedSize, data.count * 8, 256), maxEntrySize)
        var destination = Data(count: capacity)
        let decodedCount = destination.withUnsafeMutableBytes { destinationBytes in
            data.withUnsafeBytes { sourceBytes in
                compression_decode_buffer(
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                    destinationBytes.count,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB)
            }
        }
        guard decodedCount > 0 else {
            throw ZipError.corruptEntry(name)
        }
        return destination.prefix(decodedCount)
    }

    // MARK: Bounds-checked little-endian reads

    /// Validates `start + length` against the buffer and returns `start`,
    /// so every slice arithmetic stays inside the archive bytes.
    private static func checked(_ start: Int, plus length: Int, in bytes: [UInt8]) throws -> Int {
        guard start >= 0, length >= 0, start + length <= bytes.count else {
            throw ZipError.notAZipFile
        }
        return start
    }

    private static func readUInt16(_ bytes: [UInt8], at index: Int) throws -> UInt16 {
        _ = try checked(index, plus: 2, in: bytes)
        return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) throws -> UInt32 {
        _ = try checked(index, plus: 4, in: bytes)
        return littleEndian32(bytes, at: index)
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    // MARK: CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320)

    private static let crcTable: [UInt32] = {
        (0..<256).map { value -> UInt32 in
            var cell = UInt32(value)
            for _ in 0..<8 {
                cell = (cell & 1) != 0 ? (cell >> 1) ^ 0xEDB8_8320 : cell >> 1
            }
            return cell
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
