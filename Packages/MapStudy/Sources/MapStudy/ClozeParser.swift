import Foundation

/// One `{{cN::answer}}` (or `{{cN::answer::hint}}`) deletion found in a node's
/// title or note (SPEC F-STD-2).
public struct ClozeDeletion: Sendable, Equatable {
    /// The deletion index `N`; all deletions sharing an index form one card.
    public let index: Int
    /// The hidden answer text.
    public let answer: String
    /// Optional hint shown in the mask, Anki's `{{c1::answer::hint}}`.
    public let hint: String?
}

/// Finds and renders `{{cN::…}}` cloze markup (SPEC F-STD-2).
///
/// A deletion runs from a `{{cN::` opener to the first `}}`; the first `::`
/// inside the content splits answer and hint (`{{c1::answer::hint}}`). Deletions
/// cannot nest: an inner opener's text is swallowed by the outer deletion, and
/// the first `::` of that swallowed text acts as its hint separator. Anything
/// that does not parse as a deletion (`{{c::}}`, `{{c1::` without a closing
/// `}}`, `{{c1}}` without content separator) stays literal text.
public enum ClozeParser {
    /// All deletions in `text`, in order of appearance.
    public static func deletions(in text: String) -> [ClozeDeletion] {
        parse(text).deletions
    }

    /// The distinct deletion indices in `text`, ascending.
    public static func indices(in text: String) -> [Int] {
        Array(Set(deletions(in: text).map(\.index))).sorted()
    }

    /// Renders `text` for the cloze card with index `clozeIndex`: deletions with
    /// a matching index are masked as `[…]` (or `[hint]`); other deletions show
    /// their answers; unparsed markup stays literal.
    public static func rendered(text: String, clozeIndex: Int) -> String {
        let parsed = parse(text)
        var output = String()
        output.reserveCapacity(text.utf16.count)
        var cursor = text.startIndex
        for piece in parsed.pieces {
            switch piece {
            case .text(let range):
                output += text[cursor..<range.lowerBound]
                output += text[range]
                cursor = range.upperBound
            case .deletion(let deletion, let range):
                output += text[cursor..<range.lowerBound]
                if deletion.index == clozeIndex {
                    output += "[" + (deletion.hint ?? "…") + "]"
                } else {
                    output += deletion.answer
                }
                cursor = range.upperBound
            }
        }
        output += text[cursor...]
        return output
    }

    /// Renders `text` with every deletion revealed (the answer side of a cloze
    /// card); `-1` matches no valid deletion index.
    public static func revealed(text: String) -> String {
        rendered(text: text, clozeIndex: -1)
    }

    // MARK: - Internals

    private enum Piece {
        case text(Range<String.Index>)
        case deletion(ClozeDeletion, Range<String.Index>)
    }

    private struct Parsed {
        var deletions: [ClozeDeletion] = []
        var pieces: [Piece] = []
    }

    private static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        var cursor = text.startIndex
        while let opener = findOpener(in: text, from: cursor) {
            guard let closer = findCloser(in: text, after: opener.contentStart) else {
                break  // unterminated: the rest stays literal
            }
            if cursor < opener.start {
                parsed.pieces.append(.text(cursor..<opener.start))
            }
            let content = String(text[opener.contentStart..<closer])
            let (answer, hint) = splitAnswerHint(content)
            let deletion = ClozeDeletion(index: opener.index, answer: answer, hint: hint)
            parsed.deletions.append(deletion)
            parsed.pieces.append(.deletion(deletion, opener.start..<text.index(closer, offsetBy: 2)))
            cursor = text.index(closer, offsetBy: 2)
        }
        return parsed
    }

    private struct Opener {
        var start: String.Index
        var contentStart: String.Index
        var index: Int
    }

    /// Finds the next `{{cN::` opener at or after `from`.
    private static func findOpener(in text: String, from: String.Index) -> Opener? {
        var scan = from
        while let brace = text.range(of: "{{", range: scan..<text.endIndex) {
            var cursor = brace.upperBound
            guard cursor < text.endIndex, text[cursor] == "c" else {
                scan = brace.upperBound
                continue
            }
            cursor = text.index(after: cursor)
            var digits = ""
            while cursor < text.endIndex, text[cursor].isNumber {
                digits.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard !digits.isEmpty, let index = Int(digits),
                let separator = text.range(of: "::", range: cursor..<text.endIndex),
                separator.lowerBound == cursor
            else {
                scan = brace.upperBound
                continue
            }
            return Opener(start: brace.lowerBound, contentStart: separator.upperBound, index: index)
        }
        return nil
    }

    /// The first `}}` at or after `index`: the index of its first brace.
    private static func findCloser(in text: String, after index: String.Index) -> String.Index? {
        text.range(of: "}}", range: index..<text.endIndex)?.lowerBound
    }

    /// Splits cloze content on the first `::` into answer and hint.
    private static func splitAnswerHint(_ content: String) -> (answer: String, hint: String?) {
        guard let separator = content.range(of: "::") else {
            return (content, nil)
        }
        return (String(content[content.startIndex..<separator.lowerBound]), String(content[separator.upperBound...]))
    }
}
