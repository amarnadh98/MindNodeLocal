import Foundation

/// `#tag` smart typing (F-EDT-10, F-TAG-1): on title commit, a word that
/// starts with `#` becomes a tag and the token is stripped from the
/// title. Pure — MapCore owns the parse so the canvas, outline and
/// paste paths all agree; the committing layer turns the result into
/// ONE grouped command.
///
/// Rules:
/// - A candidate is a whitespace-delimited word whose first scalar is
///   `#` with a non-empty remainder (a bare `#` is literal).
/// - Trailing punctuation (`.,;:!?)]}"'` plus CJK full stops) is part
///   of the sentence, not the tag: `#exam!` → `exam`.
/// - A word containing `://` is a URL — its `#fragment` is never a tag.
/// - `#` mid-word (like `a#b`) is literal; only word-leading `#` tags.
/// - Names keep their Unicode (CJK, accents); a name must contain at
///   least one letter or number.
public enum SmartTyping {
    /// The tags found in `text` and the title left once their tokens
    /// are removed (runs of spaces collapsed, ends trimmed).
    public static func parseTags(in text: String) -> (title: String, tags: [String]) {
        let result = scan(text)
        return (title: cleaned(result.text, removing: result.removals), tags: result.tags)
    }

    /// The NodeTitle variant the commit path uses: strips the tag
    /// tokens AND remaps the §8.3 style runs to the shrunken text, so
    /// a bold word before `#tag` stays bold. The full parse is in
    /// UTF-16 units — the indices runs carry.
    public static func parseTags(in title: NodeTitle) -> (title: NodeTitle, tags: [String]) {
        let result = scan(title.text)
        guard !result.removals.isEmpty else { return (title: title, tags: result.tags) }
        let cleanedText = cleaned(result.text, removing: result.removals)
        return (
            title: NodeTitle(text: cleanedText, runs: remapped(title.runs, removing: result.removals)),
            tags: result.tags
        )
    }

    // MARK: scan

    /// One word-shaped scan result: the untouched text, the tag names
    /// and the token ranges (UTF-16) to remove.
    private struct Scan {
        let text: String
        var tags: [String] = []
        var removals: [Range<Int>] = []
    }

    /// Finds tag tokens and their UTF-16 ranges in one pass.
    private static func scan(_ text: String) -> Scan {
        var scan = Scan(text: text)
        var index = text.startIndex
        var utf16Cursor = 0
        var wordStartIndex = text.startIndex
        var wordStartUTF16 = 0
        var insideWord = false
        var handledWord = false

        while index < text.endIndex {
            let character = text[index]
            if character.unicodeScalars.first!.properties.isWhitespace {
                insideWord = false
                handledWord = false
                utf16Cursor += character.utf16.count
                index = text.index(after: index)
                continue
            }

            if !insideWord {
                insideWord = true
                handledWord = false
                wordStartIndex = index
                wordStartUTF16 = utf16Cursor
            }

            if !handledWord, character == "#" {
                let wordEnd = endOfWord(text, from: index)
                // UTF-16 units between here and the word's end (a
                // word may carry multi-unit characters).
                var units = 0
                var walk = index
                while walk < wordEnd {
                    units += text[walk].utf16.count
                    walk = text.index(after: walk)
                }
                let wordEndUTF16 = utf16Cursor + units
                let word = String(text[wordStartIndex..<wordEnd])
                if let name = tagName(inWord: word) {
                    if !scan.tags.contains(name) {
                        scan.tags.append(name)
                    }
                    scan.removals.append(wordStartUTF16..<wordEndUTF16)
                }
                handledWord = true
                utf16Cursor = wordEndUTF16
                index = wordEnd
                continue
            }

            utf16Cursor += character.utf16.count
            index = text.index(after: index)
        }

        // Interior tokens (whitespace on both sides) also eat one of
        // the doubled spaces their removal leaves behind; recording
        // those units keeps the run remap aligned with the cleaned
        // text.
        let units = Array(text.utf16)
        var removals = scan.removals
        for range in scan.removals {
            let before = range.lowerBound - 1
            let after = range.upperBound
            guard before >= 0, after < units.count else { continue }
            if isPlainSpace(units[before]), isPlainSpace(units[after]) {
                removals.append(after..<(after + 1))
            }
        }
        scan.removals = removals.sorted { $0.lowerBound < $1.lowerBound }
        return scan
    }

    /// A space (not newline) UTF-16 unit.
    private static func isPlainSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09
    }

    /// Scans forward to the next whitespace (or the end).
    private static func endOfWord(_ text: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < text.endIndex, !text[cursor].unicodeScalars.first!.properties.isWhitespace {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// `#name` → `name` (nil for a bare `#`, a URL word, or a name with
    /// no letters or numbers).
    private static func tagName(inWord word: String) -> String? {
        guard word.hasPrefix("#") else { return nil }
        guard !word.contains("://") else { return nil }
        var name = String(word.dropFirst())
        // Trailing sentence punctuation is not part of the tag.
        while let last = name.unicodeScalars.last, trailingPunctuation.contains(last) {
            name.unicodeScalars.removeLast()
        }
        guard !name.isEmpty else { return nil }
        let meaningful = name.unicodeScalars.contains {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }
        guard meaningful else { return nil }
        return name
    }

    /// Punctuation that closes a sentence in Latin and CJK text.
    private static let trailingPunctuation = CharacterSet(
        charactersIn: ".,;:!?)]}\"'›»‥。．，、；：！？）】」』〕>")

    // MARK: rebuild

    /// Removes `ranges` (UTF-16) from `text` and collapses the runs of
    /// spaces the removals leave behind.
    private static func cleaned(_ text: String, removing ranges: [Range<Int>]) -> String {
        let utf16 = Array(text.utf16)
        var rebuilt = ""
        var cursor = 0
        for range in ranges {
            rebuilt += String(decoding: utf16[cursor..<range.lowerBound], as: UTF16.self)
            cursor = range.upperBound
        }
        rebuilt += String(decoding: utf16[cursor...], as: UTF16.self)

        var collapsed = ""
        var previousWasSpace = true
        for scalar in rebuilt.unicodeScalars {
            if scalar.properties.isWhitespace, scalar != "\n" {
                if !previousWasSpace {
                    collapsed.unicodeScalars.append(" ")
                }
                previousWasSpace = true
            } else {
                collapsed.unicodeScalars.append(scalar)
                previousWasSpace = false
            }
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remaps the title's style runs onto the shrunken text: a run's
    /// range shifts left by every removed unit before it and shrinks
    /// by its own overlap with the removals. Runs that end up empty
    /// drop.
    private static func remapped(_ runs: [Run], removing ranges: [Range<Int>]) -> [Run] {
        func removedUnits(upto position: Int) -> Int {
            var total = 0
            for range in ranges {
                let overlap = min(range.upperBound, position) - min(range.lowerBound, position)
                if overlap > 0 {
                    total += overlap
                }
            }
            return total
        }

        var result: [Run] = []
        for run in runs {
            guard run.range.count >= 2 else { continue }
            let start = run.range[0]
            let end = run.range[0] + run.range[1]
            let newStart = start - removedUnits(upto: start)
            let newEnd = end - removedUnits(upto: end)
            guard newEnd > newStart else { continue }
            var remappedRun = run
            remappedRun.range = [newStart, newEnd - newStart]
            result.append(remappedRun)
        }
        return result
    }
}
