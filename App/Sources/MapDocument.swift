import AppKit
import MapCore
import os

@MainActor
final class MapDocument: NSDocument {
    nonisolated(unsafe) private(set) var model = MapModel.emptyDocument()
    nonisolated(unsafe) private(set) var meta: PackageMeta?
    nonisolated(unsafe) private var packageWrapper: FileWrapper?

    override init() {
        super.init()
        meta = PackageMeta(appVersion: AppIdentity.appVersion, docID: model.docID)
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let contents = try ArborPackage.read(from: fileWrapper)
        model = contents.model
        meta = contents.meta
        packageWrapper = fileWrapper
        for error in contents.validationErrors {
            packageLog.warning("Loaded package with violation: \(String(describing: error))")
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let current = meta ?? PackageMeta(appVersion: AppIdentity.appVersion, docID: model.docID)
        let updated = PackageMeta(
            formatVersion: current.formatVersion,
            appVersion: AppIdentity.appVersion,
            created: current.created,
            modified: Date(),
            docID: model.docID
        )
        let root: FileWrapper
        if let packageWrapper {
            root = packageWrapper
        } else {
            root = try ArborPackage.makeFileWrapper(model: model, meta: updated)
        }
        try ArborPackage.updateFileWrapper(root, model: model, meta: updated)
        packageWrapper = root
        meta = updated
        return root
    }

    override static var autosavesInPlace: Bool { true }

    override static var readableTypes: [String] { [AppIdentity.documentUTI] }

    override static var writableTypes: [String] { [AppIdentity.documentUTI] }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }
}

private let packageLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "document")
