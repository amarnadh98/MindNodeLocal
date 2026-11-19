import AppKit
import CanvasKit
import MapCore
import MapRender
import os

@MainActor
final class MapDocument: NSDocument {
    /// The single editing gateway (SPEC §11.3): the store owns the model
    /// and every mutation goes through it as a `MapCommand` with an
    /// inverse registered on the undo manager.
    private(set) var store: MapStore

    /// The current model, owned by the store.
    var model: MapModel { store.model }

    nonisolated(unsafe) private(set) var meta: PackageMeta?
    nonisolated(unsafe) private var packageWrapper: FileWrapper?

    override init() {
        let manager = UndoManager()
        store = MapStore(model: MapModel.emptyDocument(), undoManager: manager)
        super.init()
        // The store's manager must be the document's, so Edit ▸ Undo and
        // NSDocument's own change-count integration see the same stacks.
        undoManager = manager
        meta = PackageMeta(appVersion: AppIdentity.appVersion, docID: store.model.docID)
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let contents = try ArborPackage.read(from: fileWrapper)
        var loaded = contents.model
        var repairedSomething = false
        if !contents.validationErrors.isEmpty {
            let repaired = MapRepairer.repair(contents.model)
            loaded = repaired.model
            for action in repaired.applied {
                packageLog.warning("Repaired package: \(String(describing: action))")
            }
            for error in repaired.remaining {
                packageLog.warning("Unrepaired violation: \(String(describing: error))")
            }
            repairedSomething = !repaired.applied.isEmpty
        }
        meta = contents.meta
        packageWrapper = fileWrapper
        // AppKit reads documents on the main thread (concurrent document
        // reading is off), so the hand-off to the main-actor store is safe.
        MainActor.assumeIsolated {
            store.replaceModel(loaded)
            if repairedSomething {
                updateChangeCount(.changeDone)
            }
        }
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let model = store.model
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
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
        store.onChange = { [weak self] origin in
            self?.storeDidChange(origin)
        }
    }

    /// A store change: a forward perform marks the document dirty; undo
    /// and redo are covered by NSDocument's own undo-manager integration,
    /// so they are skipped here to avoid double counting. Every change
    /// rebuilds the visible scene.
    private func storeDidChange(_ origin: MapStore.ChangeOrigin) {
        if case .perform = origin {
            updateChangeCount(.changeDone)
        }
        for case let controller as DocumentWindowController in windowControllers {
            controller.modelDidChange()
        }
    }
}

private let packageLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "document")
