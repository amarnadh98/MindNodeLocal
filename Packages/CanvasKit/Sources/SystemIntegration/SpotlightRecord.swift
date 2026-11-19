import Foundation
import MapCore
import SceneExport

/// The Spotlight metadata extracted from one `.arbor` package (F-INT-2):
/// pure data, so the extraction is testable without Core Spotlight. The
/// `CSImportExtension` maps this onto a `CSSearchableItemAttributeSet`.
public struct SpotlightRecord: Sendable, Equatable {
    /// The document's display title (explicit title, else the root's
    /// first line) — what Finder and Spotlight list the file as.
    public let title: String
    /// All node titles and notes in document order, newline-joined —
    /// the body Spotlight's content search matches against.
    public let textContent: String
    /// The tag names used anywhere in the map, in first-use order.
    public let keywords: [String]
    /// The format stores no author names today (`PackageMeta` has no
    /// author field); `nil` leaves Spotlight's author untouched rather
    /// than fabricating one. A future schema bump can fill it.
    public let authors: [String]?
    public let contentCreationDate: Date?
    public let contentModificationDate: Date?

    public init(
        title: String,
        textContent: String,
        keywords: [String],
        authors: [String]?,
        contentCreationDate: Date?,
        contentModificationDate: Date?
    ) {
        self.title = title
        self.textContent = textContent
        self.keywords = keywords
        self.authors = authors
        self.contentCreationDate = contentCreationDate
        self.contentModificationDate = contentModificationDate
    }
}

/// Extracts F-INT-2's record from a decoded package. One implementation
/// shared by the Spotlight importer extension and the tests; the
/// importer only adds the URL→package read (headless, via
/// `ArborPackage.read`) and the attribute mapping.
public enum SpotlightMetadata {
    /// A generous cap so a runaway giant map cannot flood the index;
    /// far above any real map's text, small enough to stay cheap.
    public static let textContentLimit = 64_000

    /// The record for `model`/`meta`. `fileModificationDate` (the
    /// package's filesystem date) backs the dates when the meta is
    /// missing or empty.
    public static func record(
        model: MapModel, meta: PackageMeta?, fileModificationDate: Date?
    ) -> SpotlightRecord {
        let title = ArborPreviewRenderer.displayTitle(for: model)
        return SpotlightRecord(
            title: title,
            textContent: textContent(for: model, title: title),
            keywords: keywords(for: model),
            authors: nil,
            contentCreationDate: meta?.created ?? fileModificationDate,
            contentModificationDate: meta?.modified ?? fileModificationDate)
    }

    /// Title first, then every node's title and note in document order
    /// (roots, then depth-first) — the order a reader would walk the
    /// outline in, so consecutive lines read like the document.
    static func textContent(for model: MapModel, title: String) -> String {
        var lines: [String] = [title]
        for id in ExportGeometry.orderedNodeIDs(model: model, content: .wholeMap) {
            guard let node = model.nodes[id] else { continue }
            if !node.title.text.isEmpty {
                lines.append(node.title.text)
            }
            if let note = node.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                lines.append(note)
            }
        }
        var text = lines.joined(separator: "\n")
        if text.count > textContentLimit {
            text = String(text.prefix(textContentLimit))
        }
        return text
    }

    /// Tag names in first-use order: a tag the map declares but no node
    /// uses is not a keyword; ids that resolve to nothing are skipped
    /// (an undeclared id is already a validator offense, not something
    /// to index).
    static func keywords(for model: MapModel) -> [String] {
        var order: [String] = []
        var seen = Set<String>()
        for id in ExportGeometry.orderedNodeIDs(model: model, content: .wholeMap) {
            guard let node = model.nodes[id] else { continue }
            for tagID in node.tags ?? [] {
                guard
                    let name = model.tags?.first(where: { $0.id == tagID })?.name,
                    seen.insert(name).inserted
                else { continue }
                order.append(name)
            }
        }
        return order
    }
}
