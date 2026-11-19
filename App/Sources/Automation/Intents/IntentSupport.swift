import AppKit
import Foundation
import MapAutomation
import MapCore
import MapIO

/// The pure/testable core behind the intents (F-INT-1) — every mutation
/// is a `MapCommand` (one undo step on an open document through its
/// `MapStore`; one atomic write on a closed one via `HeadlessMapEditor`).
@MainActor
enum IntentSupport {
    // MARK: documents

    /// Finds maps by title substring (FindMaps).
    static func findMaps(matching query: String) async throws -> [MapRecord] {
        try await AppMapDirectory()
            .allMaps()
            .filter { NodeSearch.fuzzyContains($0.title, query) }
    }

    /// The model + location a `MapEntity` resolves to (open documents
    /// first — unsaved edits included).
    static func loadMap(_ entity: MapEntity) async throws -> LoadedMap? {
        if let open = AppMapDirectory.openDocument(matching: entity.id) {
            return LoadedMap(model: open.model, path: open.fileURL?.path)
        }
        guard let record = try await AppMapDirectory().findMap(matching: entity.id) else {
            return nil
        }
        guard let contents = try? HeadlessMapEditor.read(at: URL(fileURLWithPath: record.path)) else {
            return nil
        }
        return LoadedMap(model: contents.model, path: record.path)
    }

    // MARK: nodes

    /// FindNodes: title substring, tag name, task state (F-INT-1).
    static func findNodes(
        map: MapEntity, text: String?, tag: String?, task: NodeSearch.TaskFilter?
    ) async throws -> [NodeEntity] {
        guard let loaded = try await loadMap(map) else { return [] }
        let hits = NodeSearch.hits(
            in: loaded.model,
            query: NodeSearch.Query(text: text, tag: tag, task: task))
        return
            hits.map { NodeEntity(docID: loaded.model.docID, nodeID: $0.nodeID, title: $0.title) }
    }

    /// GetNode: a readable snapshot of one node.
    static func nodeSummary(_ entity: NodeEntity) async throws -> String {
        guard let loaded = try await loadMap(MapEntity(id: entity.docID, displayTitle: "", path: nil))
        else { return "The node's map is no longer available." }
        guard let node = loaded.model.nodes[entity.nodeID] else {
            return "The node no longer exists."
        }
        var lines = [node.title.text]
        if let note = node.note, !note.isEmpty {
            lines.append("Note: \(note)")
        }
        if let task = node.task {
            lines.append("Task: \(task.done ? "done" : "open")")
        }
        let children = node.children.count
        if children > 0 {
            lines.append("\(children) children")
        }
        return lines.joined(separator: "\n")
    }

    /// Adds outline text under a parent (node id or exact title; nil
    /// appends under the first root, or as roots when the map is empty).
    /// One undo step / one atomic write. Returns the new top-level ids.
    static func addNodes(
        map: MapEntity, parent: String?, text: String
    ) async throws -> [String] {
        guard let loaded = try await loadMap(map) else {
            throw ToolError.notFound("no map matches \"\(map.displayTitle)\"")
        }
        let model = loaded.model
        let parentID: String?
        if let parent, !parent.isEmpty, parent.caseInsensitiveCompare("root") != .orderedSame {
            guard let resolved = NodeSearch.resolve(reference: parent, in: model) else {
                throw ToolError.notFound("no node \"\(parent)\" in that map")
            }
            parentID = resolved
        } else {
            parentID = model.roots.first
        }
        guard
            let command = try OutlineConversion.insertCommand(
                fromText: text, parent: parentID,
                index: parentID.map { model.nodes[$0]?.children.count ?? 0 } ?? model.roots.count,
                in: model)
        else {
            throw ToolError.badInput("the text has no outline content")
        }
        var added: [String] = []
        if case .insertSubtrees(_, let anchors) = command {
            added = anchors.map(\.id)
        }
        try await apply([command], to: map)
        return added
    }

    /// SetNodeTitle / SetNodeNote / ToggleTask build one grouped command.
    static func updateNode(
        _ entity: NodeEntity, title: String? = nil, note: String? = nil, toggleTask: Bool = false
    ) async throws {
        let map = MapEntity(id: entity.docID, displayTitle: "", path: nil)
        guard let loaded = try await loadMap(map) else {
            throw ToolError.notFound("the node's map is no longer available")
        }
        guard let node = loaded.model.nodes[entity.nodeID] else {
            throw ToolError.notFound("the node no longer exists")
        }
        var commands: [MapCommand] = []
        if let title {
            commands.append(.editText(id: entity.nodeID, title: NodeTitle(text: title)))
        }
        if let note {
            commands.append(.setNote(id: entity.nodeID, note: note.isEmpty ? nil : note))
        }
        if toggleTask {
            var task = node.task ?? NodeTask()
            task.done.toggle()
            commands.append(.setTask(id: entity.nodeID, task: task))
        }
        guard !commands.isEmpty else { return }
        let single = commands.count == 1 ? commands[0] : MapCommand.group(name: "Update Node", commands: commands)
        try await apply([single], to: map)
    }

    // MARK: study & export

    /// GetDueCardsCount: one map, or the whole directory when nil.
    static func dueCards(map: MapEntity?) async throws -> Int {
        if let map {
            guard let loaded = try await loadMap(map) else { return 0 }
            let url = loaded.path.map { URL(fileURLWithPath: $0) }
            let reviews = (url.flatMap { try? HeadlessMapEditor.readReviews(at: $0) }) ?? []
            return DueCards.dueCount(model: loaded.model, reviews: reviews)
        }
        var total = 0
        for record in try await AppMapDirectory().allMaps() {
            guard let contents = try? HeadlessMapEditor.read(at: URL(fileURLWithPath: record.path))
            else { continue }
            let reviews = (try? HeadlessMapEditor.readReviews(at: URL(fileURLWithPath: record.path))) ?? []
            total += DueCards.dueCount(model: contents.model, reviews: reviews)
        }
        return total
    }

    /// ExportMap: the formats MapIO's DocumentIO can write today (text
    /// formats; PDF/PNG export arrives with the export-sheet slice).
    static func export(map: MapEntity, format: DocumentFormat, to destination: URL) async throws {
        guard let loaded = try await loadMap(map) else {
            throw ToolError.notFound("no map matches \"\(map.displayTitle)\"")
        }
        let data = try DocumentIO.exportDocument(loaded.model, format: format)
        try data.write(to: destination, options: [.atomic])
    }

    // MARK: mutations

    /// The single mutation path: an OPEN document's `MapStore` (one undo
    /// step) when the map is open, else one coordinated atomic write.
    static func apply(_ commands: [MapCommand], to map: MapEntity) async throws {
        if let open = AppMapDirectory.openDocument(matching: map.id) {
            let single = commands.count == 1 ? commands[0] : MapCommand.group(name: "Shortcut", commands: commands)
            try open.store.perform(single)
            return
        }
        guard let record = try await AppMapDirectory().findMap(matching: map.id) else {
            throw ToolError.notFound("no map matches \"\(map.displayTitle)\"")
        }
        try HeadlessMapEditor.apply(
            commands, at: URL(fileURLWithPath: record.path), author: .user)
    }
}
