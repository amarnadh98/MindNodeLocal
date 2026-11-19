import AppKit
import Foundation
import MapAutomation
import MapCore

/// Doc resolution for every automation surface (F-INT-5/F-INT-1, SPEC
/// §5.16): open documents by docID first, then the recents list, then a
/// filesystem scan — the "Find Maps" seam. `MapDirectory` is the seam the
/// Library window's SQLite index (MapLibrary, F-LIB) plugs into later;
/// until that lands, `AppMapDirectory` is open docs + recents + a scan
/// of the sandbox container's Documents.
@MainActor
struct AppMapDirectory: MapDirectory {
    /// The always-available fallback scan roots (container Documents).
    private var fallback: FileSystemMapDirectory {
        let containerDocuments =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileSystemMapDirectory(roots: [containerDocuments])
    }

    func allMaps() async throws -> [MapRecord] {
        var records = Self.openDocuments.map(\.record)
        let openPaths = Set(records.map(\.path))
        for record in try await fallback.allMaps() where !openPaths.contains(record.path) {
            records.append(record)
        }
        return records
    }

    func findMap(matching reference: String) async throws -> MapRecord? {
        if let open = Self.openDocument(matching: reference) {
            return open.record
        }
        if let record = try await fallback.findMap(matching: reference) {
            return record
        }
        // Recents: the open-document and scan paths may not cover a map
        // the user keeps elsewhere; its path is worth one meta.json read.
        for url in NSDocumentController.shared.recentDocumentURLs {
            guard let contents = try? HeadlessMapEditor.read(at: url) else { continue }
            let record =
                MapRecord(
                    docID: contents.model.docID,
                    title: FileSystemMapDirectory.title(
                        of: contents.model, fallback: url.deletingPathExtension().lastPathComponent),
                    path: url.path,
                    modified: contents.meta.modified
                )
            if record.docID.caseInsensitiveCompare(reference) == .orderedSame
                || record.path == reference || record.path.hasSuffix("/\(reference)")
                || record.title.caseInsensitiveCompare(reference) == .orderedSame
            {
                return record
            }
        }
        return nil
    }

    // MARK: open documents

    /// All open map documents.
    static var openDocuments: [MapDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? MapDocument }
    }

    /// The open document matching a reference: docID (case-insensitive),
    /// file path, or exact title.
    static func openDocument(matching reference: String) -> MapDocument? {
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        for document in openDocuments {
            if document.model.docID.caseInsensitiveCompare(needle) == .orderedSame {
                return document
            }
            if document.fileURL?.path == needle { return document }
            if let name = document.displayName, name.caseInsensitiveCompare(needle) == .orderedSame {
                return document
            }
        }
        // A short path ("Reno.arbor") resolves against open file URLs.
        return openDocuments.first {
            $0.fileURL?.lastPathComponent.caseInsensitiveCompare(needle) == .orderedSame
        }
    }
}

extension MapDocument {
    /// The automation-facing record for an open document (untitled
    /// documents have no path).
    var record: MapRecord {
        MapRecord(
            docID: model.docID,
            title: displayName ?? "Untitled",
            path: fileURL?.path ?? "",
            modified: Date()
        )
    }
}
