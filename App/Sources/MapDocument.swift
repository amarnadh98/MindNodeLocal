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
        store = MapStore(model: Self.initialModel(), undoManager: manager)
        super.init()
        // The store's manager must be the document's, so Edit ▸ Undo and
        // NSDocument's own change-count integration see the same stacks.
        undoManager = manager
        meta = PackageMeta(appVersion: AppIdentity.appVersion, docID: store.model.docID)
    }

    /// A brand-new document opens with the user's default theme
    /// (F-STY-6, a `UserDefaults` preference; "paper" until they pick).
    /// Untitled-empty seeding happens in the window controller, so the
    /// document stays pristine until the first edit.
    static func initialModel() -> MapModel {
        var model = MapModel.emptyDocument()
        let themeID = DocumentPreferences.defaultThemeID
        if themeID != BuiltInThemes.defaultID {
            model.theme = ThemeSelection(id: themeID)
        }
        return model
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
        // Every save (autosave included) ends the open typing session, so
        // further typing on the same node closes a fresh undo group and
        // re-dirties the document.
        store.closeEditSession()
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

    // MARK: auto-naming (F-EDT-14)

    /// Untitled documents take their display name from the root's text:
    /// first line, path-illegal characters replaced, falling back to
    /// "Untitled" (NSDocument's own default). An explicit document title
    /// (SPEC §8.2) wins. Once renamed or saved, the stored name stands.
    private var storedDisplayName: String?

    override var displayName: String? {
        get {
            if let storedDisplayName { return storedDisplayName }
            guard fileURL == nil else { return super.displayName }
            return Self.derivedName(for: store.model) ?? super.displayName
        }
        set {
            // A rename (title bar) or the first save assigns the name
            // AppKit chose; remember it so the derived name yields.
            storedDisplayName = newValue
            for case let controller as DocumentWindowController in windowControllers {
                controller.window?.title = newValue ?? ""
            }
        }
    }

    /// The save panel's default file name on the first save of an
    /// untitled document is the auto-derived name (F-EDT-14).
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        let accepted = super.prepareSavePanel(savePanel)
        if fileURL == nil, let name = Self.derivedName(for: store.model) {
            savePanel.nameFieldStringValue = name
        }
        return accepted
    }

    /// The name an untitled document shows and saves under, or nil when
    /// the root has no usable text (then NSDocument's "Untitled" stands).
    static func derivedName(for model: MapModel) -> String? {
        if let explicit = model.title?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return sanitizedDocumentName(from: explicit)
        }
        guard let rootID = model.roots.first, let root = model.nodes[rootID] else { return nil }
        return sanitizedDocumentName(from: root.title.text)
    }

    /// Filename-safe form of the root text: first line only, path
    /// separators and colons become "-", control characters dropped,
    /// ends stripped of dots and whitespace, capped at 80 characters.
    static func sanitizedDocumentName(from raw: String) -> String? {
        let firstLine =
            raw.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first.map(
                String.init) ?? ""
        var name = ""
        for scalar in firstLine.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            if "/:\\".unicodeScalars.contains(scalar) {
                name.unicodeScalars.append("-")
                continue
            }
            name.unicodeScalars.append(scalar)
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty else { return nil }
        return String(name.prefix(80))
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
        store.onChange = { [weak self] origin in
            self?.storeDidChange(origin)
        }
    }

    /// A store change rebuilds the visible scene. The change count is
    /// left to NSDocument's undo-manager integration (each closed undo
    /// group is a change, each undo/redo moves it back/forward); counting
    /// performs here as well would leave a document undone back to its
    /// saved state still marked edited.
    private func storeDidChange(_ origin: MapStore.ChangeOrigin) {
        for case let controller as DocumentWindowController in windowControllers {
            controller.modelDidChange()
        }
    }
}

private let packageLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "document")
