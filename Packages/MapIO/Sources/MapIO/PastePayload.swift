import Foundation
import MapCore

/// The internal pasteboard payload (F-EDT-9): node snapshots plus the ids of
/// the top-level pasted nodes, keyed by their **source** ids. The app puts
/// this on the pasteboard under `uniformTypeIdentifier`; it is the only
/// lossless format — a paste from it re-inserts the exact subtrees (modulo
/// the fresh-id/fresh-timestamp rules of `PasteboardParser`).
public struct PastePayload: Codable, Sendable, Hashable {
    /// The private UTI the app registers for internal node copies.
    public static let uniformTypeIdentifier = "com.arbor.paste.nodes"

    public static let currentVersion = 1

    public var version: Int
    /// The source document, so a paste into another document can drop
    /// asset references that will not resolve in the target.
    public var docID: String
    /// The top-level pasted ids (ancestor-deduplicated, document order).
    public var topIDs: [String]
    /// Snapshots of every pasted node, keyed by source id.
    public var nodes: [String: Node]

    public init(version: Int = PastePayload.currentVersion, docID: String, topIDs: [String], nodes: [String: Node]) {
        self.version = version
        self.docID = docID
        self.topIDs = topIDs
        self.nodes = nodes
    }

    /// Deterministic JSON (sorted keys), ISO-8601 dates — debuggable in a
    /// pasteboard inspector and stable across app versions.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PastePayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let payload = try decoder.decode(PastePayload.self, from: data)
            guard payload.version <= currentVersion else {
                throw ArborError.commandFailure("paste payload version \(payload.version) is from a newer Arbor")
            }
            return payload
        } catch let error as ArborError {
            throw error
        } catch {
            throw ArborError.commandFailure("unreadable paste payload: \(String(describing: error))")
        }
    }
}
