import Testing

@testable import CanvasKit

/// Pure F-FOC-4 matcher coverage: subsequence semantics, the
/// word-boundary/consecutive bonuses, fold-insensitivity, and the
/// ranking order.
struct FuzzyMatcherTests {
    @Test func emptyQueryMatchesEverythingAtZero() {
        #expect(FuzzyMatcher.score(query: "", candidate: "anything")?.score == 0)
        #expect(FuzzyMatcher.score(query: "", candidate: "anything")?.matchedRanges.isEmpty == true)
    }

    @Test func nonSubsequencesDoNotMatch() {
        #expect(FuzzyMatcher.score(query: "zqx", candidate: "anything") == nil)
        #expect(FuzzyMatcher.score(query: "ab", candidate: "ba") == nil)
        #expect(FuzzyMatcher.score(query: "longer than the candidate", candidate: "short") == nil)
    }

    @Test func matchingIsCaseAndDiacriticInsensitive() {
        #expect(FuzzyMatcher.score(query: "CAFE", candidate: "café") != nil)
        #expect(FuzzyMatcher.score(query: "resume", candidate: "Résumé") != nil)
    }

    @Test func prefixBeatsInnerMatch() {
        // "no" at the very start (word boundary + first-character
        // bonus) outscores the same letters buried mid-word.
        let prefix = FuzzyMatcher.score(query: "no", candidate: "notes")?.score
        let inner = FuzzyMatcher.score(query: "no", candidate: "xenon zone")?.score
        #expect(prefix != nil)
        #expect(inner != nil)
        #expect(prefix! > inner!)
    }

    @Test func wordBoundaryBeatsMidWord() {
        let boundary = FuzzyMatcher.score(query: "md", candidate: "mind doc")?.score
        let midWord = FuzzyMatcher.score(query: "md", candidate: "xmedal")?.score
        #expect(boundary != nil)
        #expect(midWord != nil)
        #expect(boundary! > midWord!)
    }

    @Test func consecutiveRunBeatsScatteredMatch() {
        // Neither match starts at a word boundary, so only the
        // consecutive bonus separates them.
        let consecutive = FuzzyMatcher.score(query: "bc", candidate: "xxabcxx")?.score
        let scattered = FuzzyMatcher.score(query: "bc", candidate: "xbxcxx")?.score
        #expect(consecutive != nil)
        #expect(scattered != nil)
        #expect(consecutive! > scattered!)
    }

    @Test func rangesMapBackToOriginalOffsets() {
        // "é" folds to "e": the matched folded index still maps onto
        // the original one-unit scalar.
        let scored = FuzzyMatcher.score(query: "rf", candidate: "Résumé file")
        #expect(scored != nil)
        #expect(scored?.matchedRanges.first == MatchRange(location: 0, length: 1))
        #expect(scored?.matchedRanges.count == 2)
    }

    @Test func rankingIsDescendingWithOriginalOrderTies() {
        struct Candidate {
            let text: String
        }
        let candidates = [
            Candidate(text: "xenon zone"),
            Candidate(text: "notes"),
            Candidate(text: "annotated"),
        ]
        let ranked = FuzzyMatcher.ranked(query: "no", candidates: candidates) { $0.text }
        #expect(ranked.first?.candidate.text == "notes")
        #expect(ranked.count == 3)
        #expect(ranked[0].scored.score >= ranked[1].scored.score)
        #expect(ranked[1].scored.score >= ranked[2].scored.score)
    }
}
