import Foundation
import MapCore

/// Markdown paste parsing (F-EDT-9, §8.3): headings `#`..`######` create
/// levels; `-`/`*`/`+`/`1.` list items nest under the nearest open heading
/// (or the paste root when no heading is open), nested by indentation; and
/// plain paragraphs become nodes under the nearest heading. Block constructs
/// beyond that (quotes, fences, tables) are out of scope here — they arrive
/// with the full M5 importer; their lines paste as plain paragraph nodes.
enum MarkdownOutlineParser {
    static func parse(_ text: String) -> [PastedSubtree]? {
        var roots: [MutableOutline] = []
        var headings: [(level: Int, box: MutableOutline)] = []
        var listStack: [(indent: Int, box: MutableOutline)] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (indent, content) = OutlineIndent.split(String(rawLine)) else { continue }

            if let (level, headingText) = headingMarker(content) {
                listStack.removeAll()
                while let top = headings.last, top.level >= level {
                    headings.removeLast()
                }
                let box = boxFor(headingText)
                attach(box, underHeading: headings.last?.box, into: &roots)
                headings.append((level, box))
                continue
            }

            if let listText = listMarker(content) {
                listStack.removeAll { $0.indent >= indent }
                let box = boxFor(listText)
                let parent = listStack.last?.box ?? headings.last?.box
                attach(box, underHeading: parent, into: &roots)
                listStack.append((indent, box))
                continue
            }

            // A paragraph closes any open list, then nests under the
            // nearest heading (or the paste root).
            listStack.removeAll()
            attach(boxFor(content), underHeading: headings.last?.box, into: &roots)
        }

        return OutlineBoxConverter.subtrees(from: roots)
    }

    /// Attaches `box` under `parent`, or as a paste root when `parent` is
    /// nil. The nearest-heading rule needs the box itself, not its level.
    private static func attach(
        _ box: MutableOutline, underHeading parent: MutableOutline?, into roots: inout [MutableOutline]
    ) {
        if let parent {
            parent.children.append(box)
        } else {
            roots.append(box)
        }
    }

    private static func boxFor(_ content: String) -> MutableOutline {
        let title = MarkdownInline.parse(content)
        return MutableOutline(titleText: title.text, titleRuns: title.runs)
    }

    /// `## Heading` → `(2, "Heading")`; a bare `###` is an empty heading.
    private static func headingMarker(_ content: String) -> (level: Int, text: String)? {
        var level = 0
        var characters = Substring(content).makeIterator()
        while let character = characters.next(), character == "#" {
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        let rest = String(content.dropFirst(level))
        guard rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    /// `- item`, `* item`, `+ item`, `1. item`, `2) item` → the item text;
    /// anything else is not a list line. Requires whitespace after the
    /// marker so `*emphasis*` stays a paragraph.
    private static func listMarker(_ content: String) -> String? {
        guard let first = content.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            return afterMarker(content, marker: first)
        }
        if let markerEnd = orderedMarkerEnd(content) {
            return afterMarker(content, marker: content[markerEnd])
        }
        return nil
    }

    private static func afterMarker(_ content: String, marker: Character) -> String? {
        guard let markerIndex = content.firstIndex(of: marker) else { return nil }
        let rest = content[content.index(after: markerIndex)...]
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// `1.` / `1)` marker end index, or nil when the line does not start
    /// with digits followed by `.` or `)`.
    private static func orderedMarkerEnd(_ content: String) -> String.Index? {
        var index = content.startIndex
        while index < content.endIndex, content[index].isNumber {
            index = content.index(after: index)
        }
        guard index > content.startIndex, index < content.endIndex else { return nil }
        guard content[index] == "." || content[index] == ")" else { return nil }
        return index
    }
}
