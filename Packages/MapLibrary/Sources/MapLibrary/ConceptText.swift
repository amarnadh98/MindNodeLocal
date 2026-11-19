import Foundation

/// Canonical concept normalization (F-LIB-4): one concept is every node
/// title with the same normalized text across maps. Folds a title with
/// NFKC compatibility decomposition, case folding, diacritic removal,
/// full-width folding and whitespace collapse, so "Café", "CAFE " and
/// "ｃａｆｅ" are one concept.
public enum ConceptText {
    public static func normalize(_ text: String) -> String {
        let compatibility = text.precomposedStringWithCompatibilityMapping
        let folded = compatibility.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
