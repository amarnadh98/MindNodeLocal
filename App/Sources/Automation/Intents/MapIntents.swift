import AppIntents
import AppKit
import Foundation
import MapAutomation
import MapCore
import MapIO

/// F-INT-1: the App Intents. Every mutating intent routes through
/// `IntentSupport` — one `MapCommand` step on an open document, one
/// coordinated atomic write on a closed one — so Shortcuts edits behave
/// exactly like in-app edits (undo, validation, authorship stamps).

// MARK: documents

/// Create Map (F-INT-1): from text/outline via MapIO's importers.
struct CreateMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Map"
    static let description = IntentDescription(
        "Creates a new Arbor map from outline text (Markdown, an indented outline, or OPML).")
    static let openAppWhenRun = true

    @Parameter(title: "Title") var mapTitle: String?
    @Parameter(title: "Outline Text") var outline: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MapEntity> {
        let hasTitle = mapTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasOutline = outline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasTitle || hasOutline else {
            throw $outline.needsValueError("Give the map outline text, a title, or both.")
        }
        let document = try AutomationRouter.shared.createDocument(
            title: mapTitle, outline: outline)
        document.showWindows()
        return .result(
            value: MapEntity(
                id: document.model.docID,
                displayTitle: document.displayName ?? "Untitled",
                path: nil))
    }
}

/// Open Map (F-INT-1).
struct OpenMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Map"
    static let description = IntentDescription("Opens an Arbor map.")
    static let openAppWhenRun = true

    @Parameter(title: "Map") var map: MapEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try AutomationRouter.shared.openMap(doc: map.id, node: nil)
        return .result()
    }
}

/// Find Maps (F-INT-1): title search over open documents and the
/// directory seam.
struct FindMapsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Maps"
    static let description = IntentDescription("Finds Arbor maps by title.")

    @Parameter(title: "Search") var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MapEntity]> {
        .result(value: try await IntentSupport.findMaps(matching: query).map(MapEntity.init(record:)))
    }
}

// MARK: nodes

/// Add Node (F-INT-1): outline text under a parent.
struct AddNodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Node"
    static let description = IntentDescription(
        "Adds nodes from outline text to a map, under a parent node.")
    static let openAppWhenRun = true

    @Parameter(title: "Map") var map: MapEntity
    @Parameter(title: "Parent Node", description: "A node title or id; empty adds under the first root")
    var parent: String?
    @Parameter(title: "Text") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let added = try await IntentSupport.addNodes(map: map, parent: parent, text: text)
        return .result(
            dialog: "Added \(added.count) node\(added.count == 1 ? "" : "s") to \(map.displayTitle).")
    }
}

/// Find Nodes (F-INT-1): by title text, tag or task state.
enum TaskStateAppEnum: String, AppEnum {
    case open
    case done

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task State"
    static let caseDisplayRepresentations: [TaskStateAppEnum: DisplayRepresentation] = [
        .open: "Open",
        .done: "Done",
    ]
}

struct FindNodesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Nodes"
    static let description = IntentDescription(
        "Finds nodes in a map by title text, tag, or task state.")

    @Parameter(title: "Map") var map: MapEntity
    @Parameter(title: "Title Contains") var text: String?
    @Parameter(title: "Tag") var tag: String?
    @Parameter(title: "Task", default: nil) var task: TaskStateAppEnum?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[NodeEntity]> {
        .result(
            value: try await IntentSupport.findNodes(
                map: map, text: text, tag: tag,
                task: task.flatMap { NodeSearch.TaskFilter(rawValue: $0.rawValue) }))
    }
}

/// Get Node (F-INT-1).
struct GetNodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Node"
    static let description = IntentDescription("Reads a node's title, note, task and child count.")

    @Parameter(title: "Node") var node: NodeEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await IntentSupport.nodeSummary(node))
    }
}

/// Set Node Title (F-INT-1).
struct SetNodeTitleIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Node Title"
    static let description = IntentDescription("Renames a node. Undoable in Arbor.")
    static let openAppWhenRun = true

    @Parameter(title: "Node") var node: NodeEntity
    @Parameter(title: "New Title") var newTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentSupport.updateNode(node, title: newTitle)
        return .result(dialog: "Renamed the node in \(node.title).")
    }
}

/// Set Node Note (F-INT-1).
struct SetNodeNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Node Note"
    static let description = IntentDescription("Sets a node's note. An empty note clears it.")
    static let openAppWhenRun = true

    @Parameter(title: "Node") var node: NodeEntity
    @Parameter(title: "Note") var note: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentSupport.updateNode(node, note: note)
        return .result(dialog: "Updated the note on \(node.title).")
    }
}

/// Toggle Task (F-INT-1).
struct ToggleTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Task"
    static let description = IntentDescription("Flips a node's task between open and done.")
    static let openAppWhenRun = true

    @Parameter(title: "Node") var node: NodeEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentSupport.updateNode(node, toggleTask: true)
        return .result(dialog: "Toggled the task on \(node.title).")
    }
}

// MARK: export & study

/// Export Map (F-INT-1): the formats MapIO's `DocumentIO` writes today.
enum ExportFormatAppEnum: String, AppEnum {
    case markdown
    case opml
    case plainText
    case freemind

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"
    static let caseDisplayRepresentations: [ExportFormatAppEnum: DisplayRepresentation] = [
        .markdown: "Markdown",
        .opml: "OPML",
        .plainText: "Plain Text",
        .freemind: "FreeMind",
    ]

    var documentFormat: DocumentFormat {
        switch self {
        case .markdown: DocumentFormats.markdown
        case .opml: DocumentFormats.opml
        case .plainText: DocumentFormats.plainText
        case .freemind: DocumentFormats.freemind
        }
    }
}

struct ExportMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Map"
    static let description = IntentDescription(
        "Exports a map as Markdown, OPML, plain text or FreeMind.")

    @Parameter(title: "Map") var map: MapEntity
    @Parameter(title: "Format", default: .markdown) var format: ExportFormatAppEnum
    @Parameter(title: "To", description: "The destination file") var destination: URL

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> {
        try await IntentSupport.export(map: map, format: format.documentFormat, to: destination)
        return .result(value: destination)
    }
}

/// Get Due Cards Count (F-INT-1, MapStudy's queue).
struct GetDueCardsCountIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Due Cards Count"
    static let description = IntentDescription(
        "Counts today's due study cards in a map, or across all maps.")

    @Parameter(title: "Map", default: nil) var map: MapEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let count = try await IntentSupport.dueCards(map: map)
        if let map {
            return .result(value: count, dialog: "\(count) cards are due in \(map.displayTitle).")
        }
        return .result(value: count, dialog: "\(count) cards are due across your maps.")
    }
}

/// Start Study Session (F-INT-1): opens the map and claims the study
/// seam (the study UI's slice owns the session itself).
struct StartStudySessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Study Session"
    static let description = IntentDescription("Opens a map and starts studying its due cards.")
    static let openAppWhenRun = true

    @Parameter(title: "Map") var map: MapEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try AutomationRouter.shared.openMap(doc: map.id, node: nil)
        let claimed = StudyAutomationSeam.requestSession(docID: map.id)
        return .result(
            dialog:
                claimed
                ? "Started a study session for \(map.displayTitle)."
                : "Opened \(map.displayTitle) — the study session starts from its Study button."
        )
    }
}
