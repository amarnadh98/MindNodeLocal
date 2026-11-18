import AppKit
import MapCore
import MapRender
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
        if !contents.validationErrors.isEmpty {
            let repaired = MapRepairer.repair(contents.model)
            model = repaired.model
            for action in repaired.applied {
                packageLog.warning("Repaired package: \(String(describing: action))")
            }
            for error in repaired.remaining {
                packageLog.warning("Unrepaired violation: \(String(describing: error))")
            }
            if !repaired.applied.isEmpty {
                updateChangeCount(.changeDone)
            }
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

    /// The appearance this document renders with: its explicit override,
    /// or `.auto` meaning "follow the system".
    public var effectiveAppearance: ThemeVariant {
        switch model.appearance {
        case .dark:
            return .dark
        default:
            return .light
        }
    }
}

private let packageLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "document")
