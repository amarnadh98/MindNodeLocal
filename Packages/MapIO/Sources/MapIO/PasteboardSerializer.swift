import Foundation
import MapCore

/// Serializes a selection of nodes to the four pasteboard representations
/// (F-EDT-9): the internal payload (the only lossless one), plain text,
/// Markdown and OPML 2.0.
public enum PasteboardSerializer {
    /// The ids actually copied, in document (outline) order: unknown ids are
    /// dropped, duplicates collapse, and an id whose ancestor is also
    /// selected is skipped — the ancestor's snapshot already covers it.
    public static func normalizedSelection(in model: MapModel, selection: [String]) -> [String] {
        let selected = Set(selection)
        var ordered: [String] = []
        func visit(_ id: String) {
            guard model.nodes[id] != nil else { return }
            if selected.contains(id) {
                ordered.append(id)
                return
            }
            for child in model.nodes[id]?.children ?? [] {
                visit(child)
            }
        }
        for root in model.roots {
            visit(root)
        }
        return ordered
    }

    /// The internal paste payload (see `PastePayload`) as deterministic JSON.
    public static func payload(from model: MapModel, selection: [String]) throws -> Data {
        let topIDs = normalizedSelection(in: model, selection: selection)
        var nodes: [String: Node] = [:]
        for id in topIDs {
            collectSubtree(id, in: model, into: &nodes)
        }
        return try PastePayload(docID: model.docID, topIDs: topIDs, nodes: nodes).encoded()
    }

    /// Tab-indented outline of titles.
    public static func plainText(from model: MapModel, selection: [String]) -> String {
        let topIDs = normalizedSelection(in: model, selection: selection)
        var lines: [String] = []
        for id in topIDs {
            appendOutline(id, in: model, depth: 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Nested `- ` list, preserving the §8.3 inline allow-list (bold, italic,
    /// code, strikethrough, link).
    public static func markdown(from model: MapModel, selection: [String]) -> String {
        let topIDs = normalizedSelection(in: model, selection: selection)
        var lines: [String] = []
        for id in topIDs {
            appendMarkdownItem(id, in: model, depth: 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// OPML 2.0 document (`<outline text=…>`, notes in `_note`).
    public static func opml(from model: MapModel, selection: [String]) -> String {
        OPMLDocument.render(model, topIDs: normalizedSelection(in: model, selection: selection))
    }

    private static func collectSubtree(_ id: String, in model: MapModel, into nodes: inout [String: Node]) {
        guard let node = model.nodes[id], nodes[id] == nil else { return }
        nodes[id] = node
        for child in node.children {
            collectSubtree(child, in: model, into: &nodes)
        }
    }

    private static func appendOutline(_ id: String, in model: MapModel, depth: Int, into lines: inout [String]) {
        guard let node = model.nodes[id] else { return }
        lines.append(String(repeating: "\t", count: depth) + MarkdownInline.flatTitle(node.title))
        for child in node.children {
            appendOutline(child, in: model, depth: depth + 1, into: &lines)
        }
    }

    private static func appendMarkdownItem(_ id: String, in model: MapModel, depth: Int, into lines: inout [String]) {
        guard let node = model.nodes[id] else { return }
        lines.append(String(repeating: "    ", count: depth) + "- " + MarkdownInline.render(node.title))
        for child in node.children {
            appendMarkdownItem(child, in: model, depth: depth + 1, into: &lines)
        }
    }
}
