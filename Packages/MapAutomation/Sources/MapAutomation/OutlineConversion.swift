import Foundation
import MapCore
import MapIO

/// Text ↔ model conversion for every automation surface (F-INT-1
/// "Create Map from text/outline", F-INT-5 `new`, F-INT-6 Services, MCP
/// `create_map`/`add_nodes`). All parsing is the sanctioned MapIO import
/// path — the same assemblers the File ▸ Import flows use — so results
/// pass `MapValidator`.
public enum OutlineConversion {
    public enum ConversionError: Error, Equatable, Sendable {
        case emptyText
    }

    /// Detects the text's format: OPML when it parses as one, Markdown
    /// when it has heading/list markers, otherwise indented plain text.
    /// Reuses MapIO's pasteboard detection (F-EDT-9).
    public static func detectFormat(_ text: String) -> DocumentFormat? {
        switch PasteboardParser.detectFormat(text) {
        case .opml: DocumentFormats.opml
        case .markdown: DocumentFormats.markdown
        case .plainText: DocumentFormats.plainText
        case nil: nil
        }
    }

    /// Imports outline text as a whole `MapModel` (F-INT-1 CreateMap):
    /// auto-detected format, validated by the importer. Throws
    /// `emptyText` for input with no readable content.
    public static func importModel(from text: String) throws -> MapModel {
        guard let format = detectFormat(text) else {
            throw ConversionError.emptyText
        }
        if let model = try? DocumentIO.importDocument(Data(text.utf8), format: format) {
            return model
        }
        // A malformed OPML is still just text: read it as an indented
        // outline before giving up.
        if format != DocumentFormats.plainText,
            let plain = try? DocumentIO.importDocument(Data(text.utf8), format: DocumentFormats.plainText)
        {
            return plain
        }
        throw ConversionError.emptyText
    }

    /// The one `MapCommand` that appends outline text (auto-detected
    /// format) under `parent` at `index` — or as new roots when `parent`
    /// is nil. Fresh ids and timestamps, no inherited FSRS state, target
    /// style adopted: exactly the F-EDT-9 paste contract. One undo step by
    /// construction (a single `insertSubtrees`).
    public static func insertCommand(
        fromText text: String, parent: String?, index: Int, in target: MapModel
    ) throws -> MapCommand? {
        try PasteboardParser.pasteCommand(
            fromText: text, parent: parent, index: index, keepStyle: false, in: target)
    }

    /// Renders a model as the MCP `read_map` outline JSON: a top-level
    /// ARRAY of root nodes, then depth-first,
    /// `title`/`note`/`tags`/`task`/`children` per node. Deterministic,
    /// sorted keys.
    public static func outlineJSON(from model: MapModel) throws -> String {
        let outline = model.roots.map { subtree($0, in: model) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(outline)
        return String(decoding: data, as: UTF8.self)
    }

    /// Renders a model as Markdown through MapIO (F-IO: headings + nested
    /// lists, tasks as `- [ ]`).
    public static func markdown(from model: MapModel) -> String {
        MarkdownDocumentIO.exportDocument(model)
    }

    private static func subtree(_ nodeID: String, in model: MapModel) -> OutlineNode {
        guard let node = model.nodes[nodeID] else { return OutlineNode(title: "") }
        let tags = (node.tags ?? []).compactMap { tagID in
            (model.tags ?? []).first { $0.id == tagID }?.name
        }
        return
            OutlineNode(
                title: node.title.text,
                note: node.note,
                tags: tags.isEmpty ? nil : tags,
                taskDone: node.task.map(\.done),
                children: node.children.map { subtree($0, in: model) }
            )
    }
}

/// The JSON shape `read_map` returns (and what the outline JSON tests
/// pin). `null` fields are omitted from the encoding.
public struct OutlineNode: Codable, Sendable, Equatable {
    public var title: String
    public var note: String?
    public var tags: [String]?
    public var taskDone: Bool?
    public var children: [OutlineNode]

    public init(
        title: String, note: String? = nil, tags: [String]? = nil, taskDone: Bool? = nil,
        children: [OutlineNode] = []
    ) {
        self.title = title
        self.note = note
        self.tags = tags
        self.taskDone = taskDone
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case title, note, tags, taskDone, children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        taskDone = try container.decodeIfPresent(Bool.self, forKey: .taskDone)
        children = try container.decodeIfPresent([OutlineNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(taskDone, forKey: .taskDone)
        if !children.isEmpty {
            try container.encode(children, forKey: .children)
        }
    }
}
