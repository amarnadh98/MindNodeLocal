import Foundation
import MapCore

/// Builds the "Make Cloze" edit (F-STD-2: ⌘⇧C wraps the selected title
/// text in `{{cN::…}}` with the next free deletion index N across the
/// node's title AND note, so a fresh cloze never collides with an
/// existing one).
///
/// Pure: title in, title out. The caller performs the resulting edit as
/// one undoable command; an empty selection is a no-op (nil back).
public enum ClozeMaker {
    /// The smallest deletion index not yet used by `title` or `note`
    /// (1 when neither has markup; gaps are filled first, so `c1, c3`
    /// yields 2).
    public static func nextFreeIndex(title: String, note: String?) -> Int {
        let used = Set(ClozeParser.indices(in: title) + ClozeParser.indices(in: note ?? ""))
        var candidate = 1
        while used.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    /// `title` with the UTF-16 range `(location, length)` wrapped in
    /// `{{cN::…}}`, N being the next free index over `title`/`note`.
    /// Style runs shift around the insertions (a run crossing an
    /// insertion point simply extends — the §8.3 allow-list keeps the
    /// file valid either way). Nil when the selection is empty or out
    /// of bounds, so the caller can no-op cleanly.
    public static func wrapped(
        title: NodeTitle,
        note: String?,
        location: Int,
        length: Int
    ) -> NodeTitle? {
        let text = title.text
        guard length > 0, location >= 0, location + length <= text.utf16.count else { return nil }
        let index = nextFreeIndex(title: text, note: note)
        let prefix = "{{c\(index)::"
        let suffix = "}}"
        let prefixAt = String.Index(utf16Offset: location, in: text)
        let suffixAt = String.Index(utf16Offset: location + length, in: text)
        var newText = String()
        newText.reserveCapacity(text.utf16.count + prefix.utf16.count + suffix.utf16.count)
        newText += text[..<prefixAt]
        newText += prefix
        newText += text[prefixAt..<suffixAt]
        newText += suffix
        newText += text[suffixAt...]

        var runs = title.runs
        shift(&runs, insertAt: location, count: prefix.utf16.count)
        shift(&runs, insertAt: location + length + prefix.utf16.count, count: suffix.utf16.count)
        return NodeTitle(text: newText, runs: runs)
    }

    /// Every run starting at or after `insertAt` moves by `count`
    /// UTF-16 units; a run crossing the boundary keeps its start (its
    /// styling extends over the inserted markup).
    private static func shift(_ runs: inout [Run], insertAt: Int, count: Int) {
        guard count > 0 else { return }
        for position in runs.indices where runs[position].range[0] >= insertAt {
            runs[position].range[0] += count
        }
    }
}
