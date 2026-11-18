import Foundation

/// One document known to the library index.
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

/// A searchable index of the user's maps (SPEC §5.16).
public protocol LibraryIndex: Sendable {
    func search(_ query: String) async throws -> [LibraryEntry]
}
