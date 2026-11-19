import Foundation
import MapCore

/// A mutable outline tree used while parsing text formats. Parsing is a
/// strictly local, synchronous pass, so a non-Sendable builder class keeps
/// the stack-based assembly simple; it never escapes the parse call.
final class MutableOutline {
    var titleText: String = ""
    var titleRuns: [Run] = []
    var note: String?
    var children: [MutableOutline] = []

    init(titleText: String = "", titleRuns: [Run] = [], note: String? = nil) {
        self.titleText = titleText
        self.titleRuns = titleRuns
        self.note = note
    }
}

/// Indentation measurement shared by the plain-text and Markdown parsers.
/// A tab advances to the next multiple of `tabWidth`; spaces count 1 each,
/// so mixed tab/space outlines get one consistent width scale.
enum OutlineIndent {
    static let tabWidth = 4

    /// The leading-whitespace width of a line, and its content with that
    /// whitespace (and any trailing whitespace) removed.
    static func split(_ line: String) -> (indent: Int, content: String)? {
        var width = 0
        var scalarIndex = line.unicodeScalars.startIndex
        let scalars = line.unicodeScalars
        while scalarIndex < scalars.endIndex {
            let scalar = scalars[scalarIndex]
            if scalar == "\t" {
                width += tabWidth - (width % tabWidth)
            } else if scalar == " " {
                width += 1
            } else {
                break
            }
            scalarIndex = scalars.index(after: scalarIndex)
        }
        let content = String(line.unicodeScalars[scalarIndex...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (width, content)
    }
}

/// Plain-text paste parsing: one line per node, depth from indentation
/// (F-EDT-9 "pasting text with indentation creates a hierarchy"). The
/// indent unit is auto-detected as the smallest positive indent in the
/// paste, so tabs, 2-space and 4-space outlines all work (SPEC §5.17).
enum OutlineTextParser {
    /// Parses an indented outline; `nil` when there is nothing to paste
    /// (empty or all-whitespace input).
    static func parse(_ text: String) -> [PastedSubtree]? {
        var lines: [(indent: Int, content: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if let split = OutlineIndent.split(line) {
                lines.append(split)
            }
        }
        guard !lines.isEmpty else { return nil }

        let unit = lines.map(\.indent).filter { $0 > 0 }.min() ?? 1
        var roots: [MutableOutline] = []
        var stack: [(depth: Int, box: MutableOutline)] = []
        var previousDepth = -1
        for line in lines {
            let depth = min(line.indent / unit, previousDepth + 1)
            while let top = stack.last, top.depth >= depth {
                stack.removeLast()
            }
            let box = MutableOutline(titleText: line.content)
            if let parent = stack.last {
                parent.box.children.append(box)
            } else {
                roots.append(box)
            }
            stack.append((depth, box))
            previousDepth = depth
        }
        return OutlineBoxConverter.subtrees(from: roots)
    }
}

/// Converts the parsed builder tree into the value-type `PastedSubtree`
/// forest, stamping fresh placeholder ids (replaced again by the command
/// builder) and clean timestamps.
enum OutlineBoxConverter {
    static func subtrees(from boxes: [MutableOutline], sourceDocID: String? = nil) -> [PastedSubtree] {
        boxes.map { subtree(from: $0, sourceDocID: sourceDocID) }
    }

    private static func subtree(from box: MutableOutline, sourceDocID: String?) -> PastedSubtree {
        let snapshot = Node(
            id: UUID().uuidString,
            title: NodeTitle(text: box.titleText, runs: box.titleRuns),
            note: box.note,
            created: fixedDate,
            modified: fixedDate
        )
        return PastedSubtree(
            snapshot: snapshot,
            children: subtrees(from: box.children, sourceDocID: sourceDocID),
            sourceDocID: sourceDocID
        )
    }

    /// A stable placeholder stamp: every parsed node is re-stamped by the
    /// insert-command builder, so parse results never depend on the clock.
    private static let fixedDate = Date(timeIntervalSince1970: 0)
}
