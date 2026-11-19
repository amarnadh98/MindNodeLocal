import Foundation
import MapCore

/// One map the automation surfaces know about (F-INT-1 "Find Maps", MCP
/// `list_maps`, doc resolution). `title` is the display title: the
/// document's explicit title, else its first root's text, else the file
/// name.
public struct MapRecord: Sendable, Equatable, Codable {
    public let docID: String
    public let title: String
    public let path: String
    public let modified: Date?

    public init(docID: String, title: String, path: String, modified: Date? = nil) {
        self.docID = docID
        self.title = title
        self.path = path
        self.modified = modified
    }
}

/// Where maps come from when they are not already open (SPEC §5.16: doc
/// resolution goes open documents → recents/library → a filesystem scan).
/// The library index (MapLibrary, another slice) is the eventual backing
/// implementation; a `FileSystemMapDirectory` is the always-available
/// fallback. Implementations must be safe to call from any executor.
public protocol MapDirectory: Sendable {
    func allMaps() async throws -> [MapRecord]

    /// Finds one map by docID (case-insensitive), absolute/suffix path, or
    /// exact title — the resolution order for URL and intent `doc`
    /// parameters.
    func findMap(matching reference: String) async throws -> MapRecord?
}

/// Scans directories for `.arbor` packages (SPEC §5.17). Pure Foundation:
/// recursive `FileManager` enumeration, depth- and count-capped so a scan
/// over a huge home directory can never run away. A package that fails to
/// read is skipped, never fatal.
public struct FileSystemMapDirectory: MapDirectory {
    private let roots: [URL]

    /// `roots` that do not exist are skipped.
    public init(roots: [URL]) {
        self.roots = roots
    }

    public func allMaps() async throws -> [MapRecord] {
        let roots = self.roots
        return await Task.detached(priority: .utility) {
            Self.scan(roots: roots)
        }.value
    }

    public func findMap(matching reference: String) async throws -> MapRecord? {
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        // An absolute path resolves directly, without paying for a scan.
        if needle.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: needle, isDirectory: &isDirectory), isDirectory.boolValue {
                if let record = Self.record(at: URL(fileURLWithPath: needle)) {
                    return record
                }
            }
        }
        let candidates = try await allMaps()
        return
            candidates.first {
                $0.docID.caseInsensitiveCompare(needle) == .orderedSame
            } ?? candidates.first { Self.matchesPath($0, reference: needle) }
            ?? candidates.first {
                $0.title.caseInsensitiveCompare(needle) == .orderedSame
            }
    }

    static func matchesPath(_ record: MapRecord, reference: String) -> Bool {
        if record.path == reference { return true }
        return record.path.hasSuffix("/\(reference)")
    }

    private static func scan(roots: [URL]) -> [MapRecord] {
        var records: [MapRecord] = []
        var seen = Set<String>()
        let manager = FileManager.default
        for root in roots {
            guard
                let iterator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }
            while let url = iterator.nextObject() as? URL {
                guard records.count < Self.scanLimit else { return records }
                guard url.pathExtension.lowercased() == "arbor" else { continue }
                guard seen.insert(url.path).inserted else { continue }
                if let record = record(at: url) {
                    records.append(record)
                }
            }
        }
        return records.sorted { $0.path < $1.path }
    }

    private static let scanLimit = 500

    private static func record(at url: URL) -> MapRecord? {
        guard let contents = try? ArborPackage.read(at: url) else { return nil }
        return
            MapRecord(
                docID: contents.model.docID,
                title: Self.title(of: contents.model, fallback: url.deletingPathExtension().lastPathComponent),
                path: url.path,
                modified: contents.meta.modified
            )
    }

    /// The document's display title (SPEC §8.2): explicit `title`, else
    /// the first root's text, else a fallback.
    public static func title(of model: MapModel, fallback: String) -> String {
        if let explicit = model.title?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let rootID = model.roots.first, let root = model.nodes[rootID] {
            let text = root.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let firstLine =
                    text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first
                    ?? ""
                let line = firstLine.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { return line }
            }
        }
        return fallback
    }
}
