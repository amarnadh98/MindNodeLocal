import Foundation
import MapCore

/// A loaded map: the model plus where it lives. `path` is nil for an
/// open-but-never-saved (untitled) document.
public struct LoadedMap: Sendable, Equatable {
    public let model: MapModel
    public let path: String?

    public init(model: MapModel, path: String?) {
        self.model = model
        self.path = path
    }
}

/// Where the automation engine gets documents and applies mutations —
/// the one seam every runtime provides. The app implements it over open
/// documents' `MapStore`s (with headless file editing as the fallback);
/// the helper implements it over files directly. Implementations are
/// called from arbitrary executors and must hop to their own isolation.
public protocol DocumentSpace: Sendable {
    /// Whether MCP edits are permitted right now (Settings ▸ Integrations;
    /// SPEC §12: read-only by default).
    func editsAllowed() async -> Bool

    /// Every map the space can see (open documents plus the directory's).
    func listMaps() async throws -> [MapRecord]

    /// Loads one map by docID, path or exact title. `nil` when no map
    /// matches.
    func loadMap(reference: String) async throws -> LoadedMap?

    /// Applies `commands` to the map `reference` resolves to, as one edit
    /// (one undo step on an open document; one atomic write headless),
    /// stamping `author` on the touched nodes.
    func applyCommands(
        _ commands: [MapCommand], reference: String, author: AuthorKind
    ) async throws

    /// Creates a new map from a title and/or outline text, returning the
    /// record of the package written.
    func createMap(title: String?, outline: String?, folder: String?) async throws -> MapRecord
}

/// Where the engine executes (the seam behind both MCP runtimes):
/// `editsAllowed` gates mutating tools; `perform` runs one tool.
public protocol ToolBackend: Sendable {
    /// Whether MCP edits are permitted right now (Settings ▸ Integrations;
    /// SPEC §12: read-only by default).
    func editsAllowed() async -> Bool

    /// Runs one tool call, returning its result object.
    func perform(_ call: ToolCall) async throws -> JSONValue
}

/// A tool failure as it crosses the socket (the `Kind` keeps the error
/// class — bad input, missing doc, disabled — so the rethrowing side
/// maps to the same JSON-RPC behavior as a local failure).
public struct ToolFailure: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case badInput
        case notFound
        case disabled
        case failure
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public init(_ error: ToolError) {
        switch error {
        case .badInput(let message):
            self.init(kind: .badInput, message: message)
        case .notFound(let message):
            self.init(kind: .notFound, message: message)
        case .disabled(let message):
            self.init(kind: .disabled, message: message)
        }
    }

    public var error: ToolError {
        switch kind {
        case .badInput: .badInput(message)
        case .notFound: .notFound(message)
        case .disabled: .disabled(message)
        case .failure: .notFound(message)
        }
    }
}

/// The engine behind `tools/call` (F-INT-4): every tool's logic, written
/// once against `DocumentSpace` and shared by the app endpoint and the
/// helper's local mode. All results are `JSONValue` objects; failures
/// throw `ToolError`.
public struct MapAutomationEngine: ToolBackend {
    public let space: DocumentSpace
    /// The author stamp edits carry (MCP tool calls are `.mcp`).
    public let author: AuthorKind

    public init(space: DocumentSpace, author: AuthorKind = .mcp) {
        self.space = space
        self.author = author
    }

    public func perform(_ call: ToolCall) async throws -> JSONValue {
        switch call.name {
        case "list_maps": return try await listMaps(call.arguments)
        case "read_map": return try await readMap(call.arguments)
        case "search_nodes": return try await searchNodes(call.arguments)
        case "add_nodes": return try await addNodes(call.arguments)
        case "update_node": return try await updateNode(call.arguments)
        case "move_node": return try await moveNode(call.arguments)
        case "create_map": return try await createMap(call.arguments)
        case "get_due_cards": return try await dueCards(call.arguments)
        default:
            throw ToolError.badInput("unknown tool \"\(call.name)\"")
        }
    }

    /// The space's policy decides (Settings ▸ Integrations; read-only by
    /// default, SPEC §12).
    public func editsAllowed() async -> Bool {
        await space.editsAllowed()
    }

    // MARK: tools

    private func listMaps(_ arguments: JSONValue) async throws -> JSONValue {
        let query = arguments["query"]?.string
        var maps = try await space.listMaps()
        if let query, !query.isEmpty {
            maps = maps.filter { NodeSearch.fuzzyContains($0.title, query) }
        }
        return .object([("maps", .array(maps.map(\.json)))])
    }

    private func readMap(_ arguments: JSONValue) async throws -> JSONValue {
        let (loaded, _) = try await load(arguments)
        let format = arguments["format"]?.string ?? "outline"
        let content: String
        switch format {
        case "outline":
            content = try OutlineConversion.outlineJSON(from: loaded.model)
        case "markdown":
            content = OutlineConversion.markdown(from: loaded.model)
        default:
            throw ToolError.badInput("format must be \"outline\" or \"markdown\" (found \"\(format)\")")
        }
        return .object([
            ("docID", .string(loaded.model.docID)),
            ("title", .string(FileSystemMapDirectory.title(of: loaded.model, fallback: "Untitled"))),
            ("format", .string(format)),
            ("content", .string(content)),
        ])
    }

    private func searchNodes(_ arguments: JSONValue) async throws -> JSONValue {
        let query = NodeSearch.Query(
            text: arguments["query"]?.string,
            tag: arguments["tag"]?.string,
            task: arguments["task"]?.string.flatMap(NodeSearch.TaskFilter.init(rawValue:))
        )
        if query.text == nil, query.tag == nil, query.task == nil {
            throw ToolError.badInput("search_nodes needs at least one of query, tag or task")
        }
        func hits(in loaded: LoadedMap) -> [JSONValue] {
            NodeSearch.hits(in: loaded.model, query: query).map { hit in
                hit.json(doc: loaded.model.docID)
            }
        }
        var nodes: [JSONValue] = []
        if arguments["doc"]?.string != nil {
            let (loaded, _) = try await load(arguments)
            nodes = hits(in: loaded)
        } else {
            for map in try await space.listMaps() {
                if let loaded = try await space.loadMap(reference: map.docID) {
                    nodes.append(contentsOf: hits(in: loaded))
                }
            }
        }
        return .object([("nodes", .array(nodes))])
    }

    private func addNodes(_ arguments: JSONValue) async throws -> JSONValue {
        let (loaded, doc) = try await load(arguments)
        guard let text = arguments["text"]?.string, !text.isEmpty else {
            throw ToolError.badInput("add_nodes needs non-empty text")
        }
        let parent: String?
        if let reference = arguments["parent"]?.string, !reference.isEmpty {
            guard let resolved = NodeSearch.resolve(reference: reference, in: loaded.model) else {
                throw ToolError.notFound("no node \"\(reference)\" in that map")
            }
            parent = resolved
        } else {
            parent = nil
        }
        let index =
            parent.map { loaded.model.nodes[$0]?.children.count ?? 0 } ?? loaded.model.roots.count
        guard
            let command = try OutlineConversion.insertCommand(
                fromText: text, parent: parent, index: index, in: loaded.model)
        else {
            throw ToolError.badInput("the text has no outline content to add")
        }
        try await space.applyCommands([command], reference: doc, author: author)
        let added = addedNodeIDs(command)
        return .object([
            ("docID", .string(loaded.model.docID)),
            ("parent", parent.map(JSONValue.string) ?? .null),
            ("added", .number(added.count)),
            ("nodeIDs", .array(added.map(JSONValue.string))),
        ])
    }

    private func updateNode(_ arguments: JSONValue) async throws -> JSONValue {
        let (loaded, doc) = try await load(arguments)
        guard let reference = arguments["node"]?.string else {
            throw ToolError.badInput("update_node needs a node")
        }
        guard let nodeID = NodeSearch.resolve(reference: reference, in: loaded.model) else {
            throw ToolError.notFound("no node \"\(reference)\" in that map")
        }
        var commands: [MapCommand] = []
        var updated: [JSONValue] = []
        if let title = arguments["title"]?.string {
            commands.append(.editText(id: nodeID, title: NodeTitle(text: title)))
            updated.append(.string("title"))
        }
        // JSON null leaves the note alone; an empty string clears it.
        if case .string(let note)? = arguments["note"] {
            commands.append(.setNote(id: nodeID, note: note.isEmpty ? nil : note))
            updated.append(.string("note"))
        }
        if let taskDone = arguments["taskDone"]?.bool {
            var task = loaded.model.nodes[nodeID]?.task ?? NodeTask()
            task.done = taskDone
            commands.append(.setTaskValue(id: nodeID, task: task))
            updated.append(.string("taskDone"))
        }
        guard !commands.isEmpty else {
            throw ToolError.badInput("update_node needs at least one of title, note or taskDone")
        }
        let command = commands.count == 1 ? commands[0] : MapCommand.group(name: "Update Node", commands: commands)
        try await space.applyCommands([command], reference: doc, author: author)
        return .object([
            ("docID", .string(loaded.model.docID)),
            ("nodeID", .string(nodeID)),
            ("updated", .array(updated)),
        ])
    }

    private func moveNode(_ arguments: JSONValue) async throws -> JSONValue {
        let (loaded, doc) = try await load(arguments)
        guard let reference = arguments["node"]?.string else {
            throw ToolError.badInput("move_node needs a node")
        }
        guard let nodeID = NodeSearch.resolve(reference: reference, in: loaded.model) else {
            throw ToolError.notFound("no node \"\(reference)\" in that map")
        }
        let parent: String?
        if let parentRef = arguments["parent"]?.string, !parentRef.isEmpty {
            guard let resolved = NodeSearch.resolve(reference: parentRef, in: loaded.model) else {
                throw ToolError.notFound("no node \"\(parentRef)\" in that map")
            }
            guard resolved != nodeID else {
                throw ToolError.badInput("cannot move a node under itself")
            }
            parent = resolved
        } else {
            parent = nil
        }
        let index = parent.map { loaded.model.nodes[$0]?.children.count ?? 0 } ?? loaded.model.roots.count
        let command = MapCommand.moveNode(id: nodeID, parent: parent, index: index)
        try await space.applyCommands([command], reference: doc, author: author)
        return .object([
            ("docID", .string(loaded.model.docID)),
            ("nodeID", .string(nodeID)),
            ("parent", parent.map(JSONValue.string) ?? .null),
        ])
    }

    private func createMap(_ arguments: JSONValue) async throws -> JSONValue {
        let record = try await space.createMap(
            title: arguments["title"]?.string,
            outline: arguments["outline"]?.string,
            folder: arguments["folder"]?.string
        )
        return record.json
    }

    private func dueCards(_ arguments: JSONValue) async throws -> JSONValue {
        var summaries: [DueSummary] = []
        if arguments["doc"]?.string != nil {
            let (loaded, _) = try await load(arguments)
            let path = loaded.path.map { URL(fileURLWithPath: $0) }
            let reviews = (path.flatMap { try? HeadlessMapEditor.readReviews(at: $0) }) ?? []
            summaries = [DueCards.summary(model: loaded.model, reviews: reviews)]
        } else {
            for map in try await space.listMaps() {
                let url = URL(fileURLWithPath: map.path)
                guard
                    let loaded = try await space.loadMap(reference: map.docID),
                    loaded.path == map.path
                else { continue }
                let reviews = (try? HeadlessMapEditor.readReviews(at: url)) ?? []
                summaries.append(DueCards.summary(model: loaded.model, reviews: reviews))
            }
        }
        return .object([
            ("maps", .array(summaries.map(\.json))),
            ("total", .number(summaries.reduce(0) { $0 + $1.total })),
        ])
    }

    // MARK: helpers

    private func load(_ arguments: JSONValue) async throws -> (LoadedMap, String) {
        guard let reference = arguments["doc"]?.string, !reference.isEmpty else {
            throw ToolError.badInput("the doc parameter is required")
        }
        guard let loaded = try await space.loadMap(reference: reference) else {
            throw ToolError.notFound("no map matches \"\(reference)\"")
        }
        return (loaded, reference)
    }

    private func addedNodeIDs(_ command: MapCommand) -> [String] {
        if case .insertSubtrees(let mapping, _) = command {
            return mapping.keys.sorted()
        }
        if case .group(_, let commands) = command {
            return commands.flatMap(addedNodeIDs)
        }
        return []
    }
}

// MARK: JSON shapes

extension MapRecord {
    var json: JSONValue {
        .object([
            ("docID", .string(docID)),
            ("title", .string(title)),
            ("path", .string(path)),
            ("modified", modified.map { .string($0.formatted(.iso8601)) } ?? .null),
        ])
    }
}

extension NodeSearch.Hit {
    func json(doc: String) -> JSONValue {
        .object([
            ("doc", .string(doc)),
            ("nodeID", .string(nodeID)),
            ("title", .string(title)),
            ("breadcrumb", .array(breadcrumb.map(JSONValue.string))),
            ("note", note.map(JSONValue.string) ?? .null),
            ("taskDone", taskDone.map(JSONValue.bool) ?? .null),
            ("tags", .array(tags.map(JSONValue.string))),
        ])
    }
}

extension DueSummary {
    var json: JSONValue {
        .object([
            ("docID", .string(docID)),
            ("title", .string(title)),
            ("due", .number(total)),
            ("learning", .number(learning)),
            ("review", .number(review)),
            ("new", .number(new)),
        ])
    }
}
