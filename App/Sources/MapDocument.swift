import AppKit
import MapCore

@MainActor
final class MapDocument: NSDocument {
    nonisolated(unsafe) private(set) var model = MapModel.emptyDocument()
    nonisolated(unsafe) private(set) var meta: PackageMeta?

    override init() {
        super.init()
        meta = PackageMeta(appVersion: AppIdentity.appVersion, docID: model.docID)
    }

    init(contentsOf url: URL, ofType typeName: String) throws {
        let contents = try ArborPackage.readValidating(at: url)
        model = contents.model
        meta = contents.meta
        super.init()
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let contents = try ArborPackage.readValidating(at: url)
        model = contents.model
        meta = contents.meta
    }

    override func write(to url: URL, ofType typeName: String) throws {
        let current = meta ?? PackageMeta(appVersion: AppIdentity.appVersion, docID: model.docID)
        let updated = PackageMeta(
            formatVersion: current.formatVersion,
            appVersion: AppIdentity.appVersion,
            created: current.created,
            modified: Date(),
            docID: model.docID
        )
        try ArborPackage.write(model, meta: updated, to: url)
        meta = updated
    }

    override static var autosavesInPlace: Bool { true }

    override static var readableTypes: [String] { [AppIdentity.documentUTI] }

    override static var writableTypes: [String] { [AppIdentity.documentUTI] }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }
}
