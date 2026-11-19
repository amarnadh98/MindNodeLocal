import AppIntents
import AppKit
import Foundation
import MapAutomation
import MapCore

/// F-INT-1: the Shortcuts-facing entities. `MapEntity`'s id is the docID
/// (paths and exact titles also resolve through the directory seam);
/// `NodeEntity`'s id is "<docID>/<nodeID>" so a node travels with its
/// document across intent chains.
struct MapEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Arbor Map"
    static let defaultQuery = MapEntityQuery()

    /// The docID.
    let id: String
    let displayTitle: String
    /// The file path when the map is on disk (nil for untitled documents).
    let path: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayTitle)")
    }

    init(id: String, displayTitle: String, path: String?) {
        self.id = id
        self.displayTitle = displayTitle
        self.path = path
    }

    init(record: MapRecord) {
        id = record.docID
        displayTitle = record.title
        path = record.path.isEmpty ? nil : record.path
    }
}

/// Find Maps (F-INT-1): open documents plus the directory seam
/// (recents + a container scan until the Library index lands, F-LIB).
@MainActor
struct MapEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MapEntity] {
        let directory = AppMapDirectory()
        var entities: [MapEntity] = []
        for identifier in identifiers {
            if let record = try? await directory.findMap(matching: identifier) {
                entities.append(MapEntity(record: record))
            }
        }
        return entities
    }

    func entities(matching string: String) async throws -> [MapEntity] {
        try await AppMapDirectory()
            .allMaps()
            .filter { NodeSearch.fuzzyContains($0.title, string) }
            .prefix(20)
            .map { MapEntity(record: $0) }
    }

    func suggestedEntities() async throws -> [MapEntity] {
        try await AppMapDirectory().allMaps().prefix(20).map { MapEntity(record: $0) }
    }
}

struct NodeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Arbor Node"
    static let defaultQuery = NodeEntityQuery()

    /// "<docID>/<nodeID>" — the document travels with the node.
    let id: String
    let docID: String
    let nodeID: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(docID: String, nodeID: String, title: String) {
        id = "\(docID)/\(nodeID)"
        self.docID = docID
        self.nodeID = nodeID
        self.title = title
    }
}

@MainActor
struct NodeEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [NodeEntity] {
        var entities: [NodeEntity] = []
        for identifier in identifiers {
            guard let slash = identifier.firstIndex(of: "/") else { continue }
            let docID = String(identifier[identifier.startIndex..<slash])
            let nodeID = String(identifier[identifier.index(after: slash)...])
            guard
                let record = try? await AppMapDirectory().findMap(matching: docID),
                let contents = try? HeadlessMapEditor.read(at: URL(fileURLWithPath: record.path)),
                let node = contents.model.nodes[nodeID]
            else { continue }
            entities.append(NodeEntity(docID: docID, nodeID: nodeID, title: node.title.text))
        }
        return entities
    }

    func suggestedEntities() async throws -> [NodeEntity] { [] }
}
