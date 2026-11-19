import Foundation
import MapCore

/// One document known to the index (kept compatible with the original
/// M0 stub shape: F-LIB-3's disposable store powers richer queries on
/// top of this entry type).
public struct LibraryEntry: Sendable, Equatable, Codable {
    public let docID: String
    public let path: String
    public let title: String
    public let modified: Date

    public init(docID: String, path: String, title: String, modified: Date) {
        self.docID = docID
        self.path = path
        self.title = title
        self.modified = modified
    }
}

/// A searchable index of the user's maps (SPEC §5.16 / F-LIB-3).
public protocol LibraryIndex: Sendable {
    func search(_ query: String) async throws -> [LibraryEntry]
}

/// A full-text search hit inside one node.
public struct NodeSearchHit: Sendable, Equatable {
    public let docID: String
    public let path: String
    public let documentTitle: String
    public let nodeID: String
    public let title: String
    public let note: String
}

/// One external link pointing at a node — a backlink when the target is
/// this document's node (F-LIB-3).
public struct Backlink: Sendable, Equatable {
    public let sourceDocID: String
    public let sourcePath: String
    public let sourceDocumentTitle: String
    public let sourceNodeID: String
    public let sourceNodeTitle: String
    public let targetDocID: String
    public let targetNodeID: String
}

/// One occurrence of a concept in a map.
public struct ConceptOccurrence: Sendable, Equatable {
    public let docID: String
    public let path: String
    public let documentTitle: String
    public let nodeID: String
    public let title: String
}

/// A concept (F-LIB-4): every node title across maps grouped by its
/// normalized text, with the occurrences in document order.
public struct ConceptGroup: Sendable, Equatable {
    public let normalizedTitle: String
    public let occurrences: [ConceptOccurrence]

    /// How many distinct documents contain this concept.
    public var documentCount: Int {
        Set(occurrences.map(\.docID)).count
    }
}

/// Study-due aggregation for one map (F-STD-7's query API): cards whose
/// FSRS due date falls before the end of `now`'s day, and cards that
/// have never been scheduled.
public struct DueSummary: Sendable, Equatable {
    public let docID: String
    public let path: String
    public let title: String
    public let dueToday: Int
    public let newCards: Int
}
