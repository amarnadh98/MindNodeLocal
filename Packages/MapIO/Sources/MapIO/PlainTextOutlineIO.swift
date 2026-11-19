import Foundation
import MapCore

/// Options for plain-text outline export.
public struct PlainTextExportOptions: Sendable, Hashable {
    public enum Indent: Sendable, Hashable {
        case tab
        case spaces(Int)
    }

    /// One step per outline level. Import auto-detects tabs, 2- and
    /// 4-space indents alike (SPEC §5.17), so this only shapes output.
    public var indent: Indent

    public init(indent: Indent = .tab) {
        self.indent = indent
    }
}

/// Plain indented-text whole-document exchange (F-IO, SPEC §5.17):
/// one line per node, depth from indentation — tabs, 2-space or 4-space
/// outlines are auto-detected on import (the shared `OutlineTextParser`
/// derives the indent unit from the smallest positive indent).
///
/// Lossy fields (docs/io/format-matrix.md): everything but the hierarchy
/// and the flat title text — notes, tasks, tags, structure, folded,
/// inline runs, links, connections.
public enum PlainTextOutlineIO {
    /// Parses an indented outline into a validated `MapModel`; throws
    /// `emptyDocument` when the text has no content lines.
    public static func importDocument(_ text: String) throws -> MapModel {
        guard let subtrees = OutlineTextParser.parse(text) else {
            throw DocumentIOError.emptyDocument(format: DocumentFormats.plainText.id)
        }
        let assembler = DocumentAssembler(title: nil)
        for subtree in subtrees {
            assembler.addRoot(box(from: subtree))
        }
        return assembler.result
    }

    /// Renders the whole document as an indented outline. Deterministic.
    public static func exportDocument(
        _ model: MapModel, options: PlainTextExportOptions = PlainTextExportOptions()
    ) -> String {
        var lines: [String] = []
        for rootID in model.roots {
            appendOutline(rootID, in: model, depth: 0, options: options, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func box(from subtree: PastedSubtree) -> DocumentBox {
        DocumentBox(
            title: subtree.snapshot.title,
            note: subtree.snapshot.note,
            children: subtree.children.map(box(from:)))
    }

    private static func appendOutline(
        _ nodeID: String, in model: MapModel, depth: Int,
        options: PlainTextExportOptions, into lines: inout [String]
    ) {
        guard let node = model.nodes[nodeID] else { return }
        lines.append(indentStep(options, depth) + MarkdownInline.flatTitle(node.title))
        for childID in node.children {
            appendOutline(childID, in: model, depth: depth + 1, options: options, into: &lines)
        }
    }

    private static func indentStep(_ options: PlainTextExportOptions, _ depth: Int) -> String {
        switch options.indent {
        case .tab:
            return String(repeating: "\t", count: depth)
        case .spaces(let width):
            return String(repeating: " ", count: depth * max(width, 1))
        }
    }
}
