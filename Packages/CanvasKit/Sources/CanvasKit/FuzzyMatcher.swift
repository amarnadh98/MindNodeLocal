import Foundation

/// A pure, headless subsequence fuzzy matcher (F-FOC-4): case- and
/// diacritic-insensitive, greedy left-to-right over the folded
/// candidate, with bonuses that make the ranking feel like the
/// quick-openers users know:
///
/// - +1 per matched character (coverage);
/// - +4 when the match starts a word ("md" → "**m**ind**d**oc" beats
///   the same letters buried mid-word);
/// - +3 for the candidate's very first character (prefixes win);
/// - +2 per consecutive matched character (runs of adjacent letters
///   beat scattered ones).
///
/// A candidate that does not contain every query character in order
/// does not match at all. Highlight ranges come back in original
/// UTF-16 coordinates, so the panel can underline what matched.
public enum FuzzyMatcher {
    public struct Scored: Equatable, Sendable {
        public let score: Int
        public let matchedRanges: [MatchRange]
    }

    /// Scores `candidate` against `query`, or nil when the query is
    /// not a subsequence. An empty query matches everything with score
    /// 0 (the panel lists all candidates in document order).
    public static func score(query: String, candidate: String) -> Scored? {
        var cache = FoldCache()
        let needle = FoldedNeedle(query, cache: &cache)
        return score(needle: needle, candidate: candidate, cache: &cache)
    }

    /// The cache-sharing core: one folded needle, one fold cache, many
    /// candidates (how the Quick Open list ranks a whole document per
    /// keystroke without re-folding the query every row).
    static func score(
        needle: FoldedNeedle, candidate: String, cache: inout FoldCache
    ) -> Scored? {
        guard !needle.isEmpty else { return Scored(score: 0, matchedRanges: []) }
        var haystack = FoldedHaystack()
        haystack.load(candidate, cache: &cache)
        guard haystack.pieceCount > 0 else { return nil }

        // Greedy left-to-right subsequence over the folded pieces.
        var matchedPieceIndices: [Int] = []
        matchedPieceIndices.reserveCapacity(needle.scalars.count)
        var needleIndex = 0
        while needleIndex < needle.scalars.count {
            var pieceIndex = matchedPieceIndices.last.map { $0 + 1 } ?? 0
            var found: Int?
            while pieceIndex < haystack.pieceCount {
                if haystack.pieceScalar(at: pieceIndex) == needle.scalars[needleIndex] {
                    found = pieceIndex
                    break
                }
                pieceIndex += 1
            }
            guard let hit = found else { return nil }
            matchedPieceIndices.append(hit)
            needleIndex += 1
        }

        var score = 0
        var previous: Int?
        for hit in matchedPieceIndices {
            score += 1
            if let previous, hit == previous + 1 {
                score += 2
            }
            if haystack.startsWord(at: hit) {
                score += 4
                if hit == 0 {
                    score += 3
                }
            }
            previous = hit
        }

        var ranges: [MatchRange] = []
        for hit in matchedPieceIndices {
            let range = haystack.originalRange(at: hit)
            // Two pieces of one scalar (e.g. both halves of "ﬁ") share
            // a source range; keep it once.
            if ranges.last?.location != range.location {
                ranges.append(range)
            }
        }
        return Scored(score: score, matchedRanges: ranges)
    }

    /// Ranks `candidates` by score, descending, ties broken by the
    /// original order. Non-matching candidates drop out. The needle
    /// and the fold cache are built once and shared across the whole
    /// list.
    public static func ranked<T>(
        query: String, candidates: [T], text: (T) -> String
    ) -> [(candidate: T, scored: Scored)] {
        var cache = FoldCache()
        let needle = FoldedNeedle(query, cache: &cache)
        var result: [(T, Scored, Int)] = []
        for (index, candidate) in candidates.enumerated() {
            if let scored = score(needle: needle, candidate: text(candidate), cache: &cache) {
                result.append((candidate, scored, index))
            }
        }
        return
            result
            .sorted { lhs, rhs in
                if lhs.1.score != rhs.1.score {
                    return lhs.1.score > rhs.1.score
                }
                return lhs.2 < rhs.2
            }
            .map { (candidate: $0.0, scored: $0.1) }
    }
}
