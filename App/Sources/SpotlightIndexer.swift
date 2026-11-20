import CoreSpotlight
import Foundation
import MapCore
import SystemIntegration
import UniformTypeIdentifiers

/// F-INT-2, the app-side half: when a map is saved, Arbor itself tells
/// Core Spotlight about it — title, every node's text and notes, tags —
/// so Spotlight finds the map by content even where macOS does not load
/// the importer extension (it declines ad-hoc-signed ones). The item
/// stands for the file (`contentURL`), so choosing it opens the map. The
/// extension stays as the Finder-level indexer for signed builds; both
/// feed the same `SpotlightMetadata` record.
@MainActor
enum SpotlightIndexer {
    static let domain = "com.arbor.maps"

    private static var task: Task<Void, Never>?

    /// Indexes every map as it is saved (the app's "document saved"
    /// notification). Safe to call twice.
    static func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            for await note in NotificationCenter.default.notifications(
                named: MapDocument.didSaveNotification)
            {
                handle(note)
            }
        }
    }

    private static func handle(_ note: Notification) {
        guard let document = note.object as? MapDocument,
            let url = note.userInfo?[MapDocument.savedFileURLKey] as? URL
        else { return }
        index(model: document.model, meta: document.meta, fileURL: url)
    }

    /// Replaces the document's entry (unique id = its docID).
    static func index(model: MapModel, meta: PackageMeta?, fileURL: URL) {
        guard !MapDocument.isTestHost else { return }
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate]
            as? Date
        let record = SpotlightMetadata.record(
            model: model, meta: meta, fileModificationDate: modified)
        let attributes = CSSearchableItemAttributeSet(contentType: UTType(AppIdentity.documentUTI) ?? .data)
        attributes.title = record.title
        attributes.displayName = record.title
        attributes.textContent = record.textContent
        attributes.keywords = record.keywords.isEmpty ? nil : record.keywords
        attributes.contentCreationDate = record.contentCreationDate
        attributes.contentModificationDate = record.contentModificationDate
        attributes.contentURL = fileURL
        let item = CSSearchableItem(
            uniqueIdentifier: model.docID, domainIdentifier: domain, attributeSet: attributes)
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error { NSLog("Spotlight indexing failed: \(error.localizedDescription)") }
        }
    }
}
