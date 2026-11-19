import Foundation
import MapCore

/// Parses pasteboard content into fresh subtrees and builds the
/// `MapCommand.insertSubtrees` that inserts them (F-EDT-9): from the
/// internal payload, plain indented text, Markdown or OPML. Every inserted
/// node gets a fresh UUID and fresh timestamps, and inherits no FSRS study
/// state — a pasted node is a new node, like `MapCommand.duplicate`.
public enum PasteboardParser {
    // MARK: Parsing

    /// The format of a pasteboard string: OPML when it parses as an `<opml>`
    /// document, Markdown when it has list/heading markers, otherwise
    /// indented plain text. `nil` for empty input.
    public static func detectFormat(_ text: String) -> PasteFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let root = OPMLDocument.rootElementName(of: text), root.lowercased() == "opml" {
            return .opml
        }
        if hasMarkdownMarkers(text) {
            return .markdown
        }
        return .plainText
    }

    /// Parses pasteboard text (auto-detected unless `format` is given) into
    /// pasted subtrees. `nil` when there is nothing to paste.
    public static func parseText(_ text: String, format: PasteFormat? = nil) -> [PastedSubtree]? {
        guard trimmedNonEmpty(text) else { return nil }
        guard let resolved = format ?? detectFormat(text) else { return nil }
        switch resolved {
        case .opml:
            return OPMLDocument.parse(text)
        case .markdown:
            return MarkdownOutlineParser.parse(text)
        case .plainText:
            return OutlineTextParser.parse(text)
        }
    }

    /// Parses the internal paste payload into pasted subtrees, or nil when
    /// the payload has no nodes. Malformed data throws.
    public static func parsePayload(_ data: Data) throws -> [PastedSubtree]? {
        let payload = try PastePayload.decode(data)
        guard !payload.topIDs.isEmpty else { return nil }
        var subtrees: [PastedSubtree] = []
        var seen = Set<String>()
        for topID in payload.topIDs {
            subtrees.append(try subtree(forTopID: topID, payload: payload, seen: &seen))
        }
        return subtrees.isEmpty ? nil : subtrees
    }

    /// Rebuilds the payload's hierarchy from its flat node map. Throws on a
    /// dangling child reference or a cyclic payload.
    private static func subtree(
        forTopID topID: String, payload: PastePayload, seen: inout Set<String>
    ) throws -> PastedSubtree {
        guard let snapshot = payload.nodes[topID] else {
            throw ArborError.commandFailure("paste payload is missing node \(topID)")
        }
        guard seen.insert(topID).inserted else {
            throw ArborError.commandFailure("paste payload contains a cycle at node \(topID)")
        }
        var children: [PastedSubtree] = []
        for childID in snapshot.children {
            children.append(try subtree(forTopID: childID, payload: payload, seen: &seen))
        }
        return PastedSubtree(snapshot: snapshot, children: children, sourceDocID: payload.docID)
    }

    // MARK: Paste placement

    /// F-EDT-9 paste placement: the pasted subtrees land under the
    /// document-order-FIRST selected node as its last children, or are
    /// appended as roots when nothing is selected. An ancestor/descendant
    /// selection collapses onto the ancestor's slot (its snapshot already
    /// covers the descendant). Pure, so the host's menu wiring can be
    /// thin and the rule itself headless-tested.
    public static func pasteAnchor(
        selection: [String], in model: MapModel
    ) -> (parent: String?, index: Int) {
        let top = PasteboardSerializer.normalizedSelection(in: model, selection: selection)
        guard let first = top.first, let node = model.nodes[first] else {
            return (nil, model.roots.count)
        }
        return (first, node.children.count)
    }

    // MARK: Paste commands

    /// The command that pastes `subtrees` as children of `parent` at
    /// `index` — or as roots when `parent` is nil.
    ///
    /// Inserted nodes get fresh ids and timestamps and never inherit FSRS
    /// state. A plain paste (`keepStyle: false`, the F-EDT-9 default) drops
    /// per-node style overrides so the nodes adopt the target's theme;
    /// `keepStyle: true` (⇧⌥⌘V) keeps them. Tags are filtered to ids the
    /// target document declares, and asset references from a foreign
    /// document are dropped, so the result always passes `MapValidator`.
    public static func insertCommand(
        _ subtrees: [PastedSubtree],
        parent: String?,
        index: Int,
        keepStyle: Bool = false,
        in target: MapModel
    ) throws -> MapCommand {
        guard !subtrees.isEmpty else {
            throw ArborError.commandFailure("nothing to paste")
        }
        if let parent {
            guard target.nodes[parent] != nil else {
                throw ArborError.commandFailure("missing paste parent \(parent)")
            }
        }

        let now = Date()
        let declaredTags = Set((target.tags ?? []).map(\.id))
        var mapping: [String: Node] = [:]
        var anchors: [InsertionAnchor] = []

        func instantiate(_ subtree: PastedSubtree, parentID: String?) -> String {
            let freshID = UUID().uuidString
            var node = subtree.snapshot
            node.id = freshID
            node.parent = parentID
            node.created = now
            node.modified = now
            if var study = node.study {
                study.fsrs = nil
                node.study = study
            }
            if !keepStyle {
                node.style = nil
            }
            // A side pin is only meaningful for the children of a root; it
            // is placement, not style, so it survives a root paste.
            if parentID != nil {
                node.side = nil
            }
            if let tags = node.tags {
                let known = tags.filter(declaredTags.contains)
                node.tags = known.isEmpty ? nil : known
            }
            if let source = subtree.sourceDocID, source != target.docID {
                node.image = nil
                node.attachments = nil
            }
            node.children = subtree.children.map { instantiate($0, parentID: freshID) }
            mapping[freshID] = node
            return freshID
        }

        for (position, subtree) in subtrees.enumerated() {
            let freshID = instantiate(subtree, parentID: parent)
            anchors.append(InsertionAnchor(id: freshID, parent: parent, index: index + position))
        }
        return .insertSubtrees(mapping: mapping, anchors: anchors)
    }

    /// Pastes the internal payload under `parent` at `index`.
    public static func pasteCommand(
        fromPayload data: Data,
        parent: String?,
        index: Int,
        keepStyle: Bool = false,
        in target: MapModel
    ) throws -> MapCommand? {
        guard let subtrees = try parsePayload(data) else { return nil }
        return try insertCommand(subtrees, parent: parent, index: index, keepStyle: keepStyle, in: target)
    }

    /// Pastes external text under `parent` at `index`. Plain-text and
    /// Markdown pastes carry no per-node style overrides, so `keepStyle`
    /// makes no difference for them.
    public static func pasteCommand(
        fromText text: String,
        parent: String?,
        index: Int,
        keepStyle: Bool = false,
        in target: MapModel
    ) throws -> MapCommand? {
        guard let subtrees = parseText(text) else { return nil }
        return try insertCommand(subtrees, parent: parent, index: index, keepStyle: keepStyle, in: target)
    }

    // MARK: Detection helpers

    private static func trimmedNonEmpty(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasMarkdownMarkers(_ text: String) -> Bool {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (_, content) = OutlineIndent.split(String(rawLine)) else { continue }
            if isHeading(content) { return true }
            if isListItem(content) { return true }
        }
        return false
    }

    private static func isHeading(_ content: String) -> Bool {
        var level = 0
        for character in content {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }
        guard (1...6).contains(level) else { return false }
        let rest = content.dropFirst(level)
        return rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t")
    }

    private static func isListItem(_ content: String) -> Bool {
        guard let first = content.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            let rest = content.dropFirst()
            return rest.first == " " || rest.first == "\t"
        }
        let digits = content.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let afterDigits = content.dropFirst(digits.count)
        guard let marker = afterDigits.first, marker == "." || marker == ")" else { return false }
        let rest = afterDigits.dropFirst()
        return rest.first == " " || rest.first == "\t"
    }
}
