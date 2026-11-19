import Foundation

/// Case-, diacritic- and width-insensitive text folding with index
/// maps back to original UTF-16 offsets (the coordinates `Run` ranges
/// and `NSAttributedString` use, SPEC §8.3).
///
/// Folding is per Unicode scalar — a scalar can fold to several
/// ("ﬁ" → "fi", "ß" → "ss") or to none — and every folded piece
/// remembers which scalar produced it, so a match located in folded
/// space maps back onto an exact original range. ASCII (the
/// overwhelming case) folds inline with no cache traffic, and the
/// offsets are identity, so the common path allocates nothing.
///
/// The scalar fold is memoized through a caller-owned cache (strict
/// concurrency: no shared mutable statics), so a scan over thousands
/// of titles folds each distinct non-ASCII scalar at most once.
struct FoldCache {
    private var foldedScalars: [UInt32: String] = [:]

    /// Case + diacritic + width folding of one non-ASCII scalar.
    mutating func fold(_ scalar: Unicode.Scalar) -> String {
        if let cached = foldedScalars[scalar.value] {
            return cached
        }
        let folded = String(
            String(scalar).folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
        foldedScalars[scalar.value] = folded
        return folded
    }
}

/// The folded query, ready to scan against: one folded scalar per
/// entry, in order. An empty query folds to nothing.
struct FoldedNeedle: Equatable, Sendable {
    let scalars: [Unicode.Scalar]

    init(_ raw: String, cache: inout FoldCache) {
        var folded: [Unicode.Scalar] = []
        folded.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if scalar.value < 0x80 {
                folded.append(Self.lowerASCII(scalar))
            } else {
                for produced in cache.fold(scalar).unicodeScalars {
                    folded.append(produced)
                }
            }
        }
        scalars = folded
    }

    init(_ raw: String) {
        var cache = FoldCache()
        self.init(raw, cache: &cache)
    }

    var isEmpty: Bool { scalars.isEmpty }

    static func lowerASCII(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.value >= 65, scalar.value <= 90 {
            return Unicode.Scalar(scalar.value + 32)!
        }
        return scalar
    }
}

/// One folded piece: what it folded to and which original scalar it
/// came from (start offset, and the offset just past that scalar).
private struct FoldedPiece {
    let scalar: Unicode.Scalar
    let sourceStart: Int
    let sourceEnd: Int
    /// True when this piece is the FIRST piece of its source scalar
    /// (word-boundary scoring) — a piece that is also the LAST piece
    /// ends its scalar's original range.
    let isScalarStart: Bool
    let isScalarEnd: Bool
}

/// The folded pieces of one haystack string, built into buffers the
/// caller reuses across a whole scan (the find engine over 5k titles
/// allocates nothing after the first warmup).
struct FoldedHaystack {
    private var pieces: [FoldedPiece] = []
    private(set) var originalLength = 0

    mutating func load(_ raw: String, cache: inout FoldCache) {
        pieces.removeAll(keepingCapacity: true)
        var utf16Offset = 0
        for scalar in raw.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if scalar.value < 0x80 {
                pieces.append(
                    FoldedPiece(
                        scalar: FoldedNeedle.lowerASCII(scalar), sourceStart: utf16Offset,
                        sourceEnd: utf16Offset + width, isScalarStart: true, isScalarEnd: true))
                utf16Offset += width
                continue
            }
            let folded = cache.fold(scalar)
            let produced = Array(folded.unicodeScalars)
            if !produced.isEmpty {
                for (index, pieceScalar) in produced.enumerated() {
                    pieces.append(
                        FoldedPiece(
                            scalar: pieceScalar, sourceStart: utf16Offset,
                            sourceEnd: utf16Offset + width,
                            isScalarStart: index == 0, isScalarEnd: index == produced.count - 1))
                }
            }
            utf16Offset += width
        }
        originalLength = utf16Offset
    }

    var pieceCount: Int { pieces.count }

    /// True when the piece at `index` starts a word for fuzzy scoring:
    /// the first piece of its scalar, and the previous piece belongs
    /// to a non-word scalar (or does not exist).
    func startsWord(at index: Int) -> Bool {
        guard pieces[index].isScalarStart else { return false }
        guard index > 0 else { return true }
        // The previous piece is word-alphabetical iff its scalar is
        // alphanumerical — for the boundary test the piece's own
        // scalar is the scalar's FIRST piece by construction.
        let previous = pieces[index - 1].scalar
        return !isWordCharacter(previous)
    }

    func pieceScalar(at index: Int) -> Unicode.Scalar { pieces[index].scalar }

    func previousPieceScalar(before index: Int) -> Unicode.Scalar? {
        index > 0 ? pieces[index - 1].scalar : nil
    }

    func pieceIsScalarStart(at index: Int) -> Bool { pieces[index].isScalarStart }

    /// The original UTF-16 range of the source scalar behind the
    /// piece at `index`.
    func originalRange(at index: Int) -> MatchRange {
        let piece = pieces[index]
        return MatchRange(location: piece.sourceStart, length: piece.sourceEnd - piece.sourceStart)
    }

    func originalRange(spanningPieces from: Int, to: Int) -> MatchRange {
        // `to` is exclusive. The range covers from the source scalar
        // of piece `from` to just past the source scalar of the last
        // matched piece.
        let start = pieces[from].sourceStart
        let end = pieces[to - 1].sourceEnd
        return MatchRange(location: start, length: end - start)
    }

    /// All original ranges where `needle` occurs contiguously, in
    /// order — the find engine's core scan. One pass over the piece
    /// buffers; no string searches, no allocations beyond the result.
    func ranges(of needle: FoldedNeedle) -> [MatchRange] {
        let count = pieces.count
        let needleCount = needle.scalars.count
        guard needleCount > 0, count >= needleCount else { return [] }
        var result: [MatchRange] = []
        var start = 0
        while start <= count - needleCount {
            var offset = 0
            while offset < needleCount, pieces[start + offset].scalar == needle.scalars[offset] {
                offset += 1
            }
            if offset == needleCount {
                result.append(originalRange(spanningPieces: start, to: start + needleCount))
                start += needleCount
            } else {
                start += 1
            }
        }
        return result
    }

    private func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || (scalar.value >= 48 && scalar.value <= 57)
    }
}
