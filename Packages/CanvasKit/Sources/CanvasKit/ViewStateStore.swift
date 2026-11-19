import Foundation

/// Stores one `CanvasViewState` JSON sidecar per document under a base
/// directory, keyed by the document's `docID` (ADR-0005) — the
/// production base is Application Support. The base directory is
/// injectable so tests run against a temp folder.
///
/// Writes are atomic and sorted-key pretty-printed (SPEC §8.1's
/// conventions); reads treat a missing or corrupt file as "no state"
/// rather than an error, so a broken sidecar can never block opening a
/// document.
public struct ViewStateStore: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// The production base directory:
    /// `~/Library/Application Support/Arbor/CanvasViewState`.
    public static func defaultBaseURL() -> URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Arbor/CanvasViewState", directoryHint: .isDirectory)
    }

    /// `<base>/<docID>.json`, with the id defensively flattened so a
    /// malformed docID can never escape the directory.
    public func fileURL(forDocID docID: String) -> URL {
        let safe = String(
            docID.map { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
                    ? character : "_"
            })
        let name = safe.isEmpty ? "unknown" : safe
        return baseURL.appending(path: "\(name).json")
    }

    /// The stored state for a document, or nil when absent or corrupt.
    public func load(docID: String) -> CanvasViewState? {
        guard let data = try? Data(contentsOf: fileURL(forDocID: docID)) else { return nil }
        return try? JSONDecoder().decode(CanvasViewState.self, from: data)
    }

    /// Persists the state atomically, creating the base directory on
    /// first use.
    public func save(_ state: CanvasViewState, docID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: baseURL, withIntermediateDirectories: true)
        try data.write(to: fileURL(forDocID: docID), options: .atomic)
    }
}
