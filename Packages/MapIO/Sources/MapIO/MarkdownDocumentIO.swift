import Foundation
import MapCore

/// Options for Markdown export (F-IO, SPEC §5.17 "headings depth").
public struct MarkdownExportOptions: Sendable, Hashable {
    /// Roots export as heading level 1, their children level 2, …, up to
    /// this many heading levels; deeper nodes — and task nodes at any
    /// depth, whose `- [ ]` state only a list item can carry — export as
    /// nested list items. `nil` exports the whole map as lists.
    public var headingDepth: Int?

    public init(headingDepth: Int? = 2) {
        self.headingDepth = headingDepth
    }
}

/// Markdown whole-document exchange (F-IO, SPEC §5.17): headings nest by
/// level, list items nest by indentation, GFM `- [ ]` / `- [x]` task
/// markers become node tasks, and a plain paragraph following a node
/// line becomes that node's note (notes export as indented paragraphs).
/// Inline styles follow the §8.3 allow-list via `MarkdownInline`.
///
/// Lossy fields (docs/io/format-matrix.md): structure, folded, tags,
/// task due/priority, side pins, links, connections, and the §8.3 runs
/// outside the allow-list (underline, color, highlight, font, size).
/// Blank lines inside notes are not representable and collapse.
public enum MarkdownDocumentIO {
    /// Parses a Markdown document into a validated `MapModel`. Markdown
    /// never fails structurally; only empty input throws.
    public static func importDocument(_ text: String) throws -> MapModel {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentIOError.emptyDocument(format: DocumentFormats.markdown.id)
        }
        var roots: [DocumentBox] = []
        var headings: [(level: Int, box: DocumentBox)] = []
        var listStack: [(indent: Int, box: DocumentBox)] = []
        var lastBox: DocumentBox?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            guard let (indent, content) = OutlineIndent.split(line) else { continue }

            if let (level, headingText) = headingMarker(content) {
                listStack.removeAll()
                while let top = headings.last, top.level >= level {
                    headings.removeLast()
                }
                let box = DocumentBox(title: MarkdownInline.parse(headingText))
                attach(box, under: headings.last?.box, into: &roots)
                headings.append((level, box))
                lastBox = box
                continue
            }

            if let listText = listMarker(content) {
                let (done, itemText) = taskMarker(in: listText)
                listStack.removeAll { $0.indent >= indent }
                let box = DocumentBox(title: MarkdownInline.parse(itemText))
                if let done {
                    box.task = NodeTask(done: done)
                }
                let parent = listStack.last?.box ?? headings.last?.box
                attach(box, under: parent, into: &roots)
                listStack.append((indent, box))
                lastBox = box
                continue
            }

            // A plain paragraph is the note of the most recent node
            // (multi-line notes join with "\n"); before any node it
            // becomes the first root.
            if let box = lastBox {
                box.note = (box.note.map { $0 + "\n" } ?? "") + content
            } else {
                let box = DocumentBox(title: MarkdownInline.parse(content))
                roots.append(box)
                lastBox = box
            }
        }
        guard !roots.isEmpty else {
            throw DocumentIOError.emptyDocument(format: DocumentFormats.markdown.id)
        }
        let assembler = DocumentAssembler(title: nil)
        for root in roots {
            assembler.addRoot(root)
        }
        return assembler.result
    }

    /// Renders the whole document as Markdown. Deterministic: no
    /// timestamps, roots in document order.
    public static func exportDocument(
        _ model: MapModel, options: MarkdownExportOptions = MarkdownExportOptions()
    ) -> String {
        let headingMax = max(options.headingDepth ?? 0, 0)
        var lines: [String] = []
        for rootID in model.roots {
            emit(
                rootID, in: model, depth: 1, listDepth: nil, headingMax: headingMax, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func attach(
        _ box: DocumentBox, under parent: DocumentBox?, into roots: inout [DocumentBox]
    ) {
        if let parent {
            parent.children.append(box)
        } else {
            roots.append(box)
        }
    }

    private static func emit(
        _ nodeID: String, in model: MapModel, depth: Int, listDepth: Int?, headingMax: Int,
        into lines: inout [String]
    ) {
        guard let node = model.nodes[nodeID] else { return }
        // Once a branch is in list mode it stays there, so a task node
        // below heading depth keeps its children as deeper list items.
        let inListMode = listDepth != nil || depth > headingMax || node.task != nil
        if let level = listDepth {
            emitListItem(node, level: level, into: &lines)
            for childID in node.children {
                emit(childID, in: model, depth: depth + 1, listDepth: level + 1, headingMax: headingMax, into: &lines)
            }
        } else if inListMode {
            emitListItem(node, level: 0, into: &lines)
            for childID in node.children {
                emit(childID, in: model, depth: depth + 1, listDepth: 1, headingMax: headingMax, into: &lines)
            }
        } else {
            lines.append(String(repeating: "#", count: depth) + " " + MarkdownInline.render(node.title))
            appendNoteParagraphs(node, indent: "", into: &lines)
            for childID in node.children {
                emit(childID, in: model, depth: depth + 1, listDepth: nil, headingMax: headingMax, into: &lines)
            }
        }
    }

    private static func emitListItem(
        _ node: Node, level: Int, into lines: inout [String]
    ) {
        let indent = String(repeating: "    ", count: level)
        let title = MarkdownInline.render(node.title)
        if let task = node.task {
            lines.append(indent + (task.done ? "- [x] " : "- [ ] ") + title)
        } else {
            lines.append(indent + "- " + title)
        }
        appendNoteParagraphs(node, indent: indent + "    ", into: &lines)
    }

    /// One indented paragraph per non-empty note line. Blank note lines
    /// carry no meaning in this layout and are dropped.
    private static func appendNoteParagraphs(_ node: Node, indent: String, into lines: inout [String]) {
        guard let note = node.note else { return }
        for noteLine in note.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = noteLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append(indent + trimmed)
            }
        }
    }

    /// `## Heading` → `(2, "Heading")`; a bare `###` is an empty heading.
    private static func headingMarker(_ content: String) -> (level: Int, text: String)? {
        var level = 0
        for character in content {
            guard character == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        let rest = content.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (level, String(rest).trimmingCharacters(in: .whitespaces))
    }

    /// `- item`, `* item`, `+ item`, `1. item`, `2) item` → the item
    /// text; requires whitespace after the marker so `*emphasis*` stays
    /// a paragraph.
    private static func listMarker(_ content: String) -> String? {
        guard let first = content.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let rest = content.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return nil }
            return String(rest).trimmingCharacters(in: .whitespaces)
        }
        var index = content.startIndex
        while index < content.endIndex, content[index].isNumber {
            index = content.index(after: index)
        }
        guard index > content.startIndex, index < content.endIndex else { return nil }
        guard content[index] == "." || content[index] == ")" else { return nil }
        let rest = content[index...].dropFirst()
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    /// GFM task list marker at the start of a list item's text:
    /// `[ ] buy milk` → `(false, "buy milk")`, `[x] done` → `(true, …)`;
    /// anything else → `(nil, unchanged)`.
    private static func taskMarker(in itemText: String) -> (done: Bool?, text: String) {
        let view = Substring(itemText)
        guard view.count >= 4, view.first == "[", view[view.index(view.startIndex, offsetBy: 2)] == "]"
        else { return (nil, itemText) }
        let afterClose = view.index(view.startIndex, offsetBy: 3)
        guard view[afterClose] == " " || view[afterClose] == "\t" else { return (nil, itemText) }
        let mark = view[view.index(after: view.startIndex)]
        let done = mark == "x" || mark == "X"
        return (done, String(view[view.index(after: afterClose)...]).trimmingCharacters(in: .whitespaces))
    }
}
