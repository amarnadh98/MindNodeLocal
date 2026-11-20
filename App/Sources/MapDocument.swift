import AppKit
import CanvasKit
import MapCore
import MapIO
import MapRender
import MapStudy
import os

@MainActor
final class MapDocument: NSDocument {
    /// Posted after every successful save (F-LIB-3: the Library index
    /// observes it and reindexes the saved package incrementally).
    /// Nonisolated (plain `Sendable` values) so any context can observe.
    nonisolated static let didSaveNotification = Notification.Name("MapDocumentDidSave")
    nonisolated static let savedFileURLKey = "fileURL"

    /// The single editing gateway (SPEC §11.3): the store owns the model
    /// and every mutation goes through it as a `MapCommand` with an
    /// inverse registered on the undo manager.
    private(set) var store: MapStore

    /// The current model, owned by the store.
    var model: MapModel { store.model }

    /// The document's append-only review history (SPEC §8.1, F-STD-3):
    /// loaded from `study/reviews.jsonl` on open (tolerant of a
    /// truncated tail), appended on every grade, written on every save.
    /// Reviews are history, not edits — grading is deliberately not on
    /// the user's undo stack (ADR-0015).
    private(set) var reviewLog: [ReviewLog] = []

    /// The FSRS scheduler at the document's desired retention
    /// (`studySettings`, default 0.9 per F-STD-3).
    var studyScheduler: FSRSScheduler {
        FSRSScheduler(options: .init(studySettings: store.model.studySettings))
    }

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

    /// Foreign formats (`.opml`, `.md`, `.txt`, `.mm`, `.xmind`,
    /// `.mindnode`) dispatched here by the declared document types
    /// (double-click, Dock drop, open/Import panel) import as a NEW
    /// untitled Arbor document: the model is imported, the source file's
    /// URL is dropped, and saving asks for a fresh `.arbor` location —
    /// the source file is never overwritten. The native package keeps
    /// the wrapper-based read below.
    override func read(from url: URL, ofType typeName: String) throws {
        if typeName != AppIdentity.documentUTI,
            let format = DocumentFormats.format(forExtension: url.pathExtension)
                ?? DocumentFormats.format(forUTType: typeName),
            format.canImport, format.id != DocumentFormats.arbor.id
        {
            let model = try DocumentImporter.importModel(at: url)
            MainActor.assumeIsolated {
                adoptImportedModel(model)
                // A foreign import is an untitled document in editing
                // state, not a "read" of the source file: drop the URL,
                // restore the native type, and mark edited. The name set
                // by AppKit from the source file is ignored until the
                // first real save gives the document one of its own.
                fileURL = nil
                fileType = AppIdentity.documentUTI
                importedUntitled = true
                updateChangeCount(.changeDone)
            }
            return
        }
        try super.read(from: url, ofType: typeName)
    }

    /// Set for documents that came in through a foreign-format import
    /// (read override or Import panel): F-EDT-14's root-derived name
    /// shows until the first save.
    var importedUntitled = false

    /// Adopts an imported (foreign-format) model: replaces the store,
    /// refreshes the package meta to the imported document's id, and
    /// leaves the document untitled and edited (SPEC §5.17: imports
    /// become a new Arbor document).
    func adoptImportedModel(_ imported: MapModel) {
        store.replaceModel(imported)
        meta = PackageMeta(appVersion: AppIdentity.appVersion, docID: imported.docID)
        packageWrapper = nil
    }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        // F-DOC-4: a package written by a NEWER app version has no
        // forward migration, but it still opens — read-only, with a
        // banner — instead of failing. JSON decoding ignores future
        // schema keys, so the current view of the model degrades
        // gracefully; the store's read-only gate (ADR-0023) makes the
        // enforcement real.
        let contents: PackageContents
        let newerFormat: Bool
        do {
            contents = try ArborPackage.read(from: fileWrapper)
            newerFormat = false
        } catch ArborError.unsupportedFormatVersion(let found, let expected) {
            contents = try ArborPackage.readWithoutMigration(from: fileWrapper)
            newerFormat = true
            packageLog.warning(
                "Package format \(found) is newer than this app's \(expected); opening read-only.")
        }
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
            // The review log rides in the package (SPEC §8.1); a truncated
            // tail is the log's normal interrupted-append failure and is
            // tolerated by the codec.
            reviewLog = Self.decodeReviewLog(contents.studyLogData)
            isReadOnlyFormat = newerFormat
            store.replaceModel(loaded)
            store.isReadOnly = newerFormat
            if repairedSomething {
                updateChangeCount(.changeDone)
            }
        }
    }

    /// True when the document came from a newer app version's package
    /// (F-DOC-4): the store is read-only and the window shows a banner.
    /// Set by the read override above; never mutated afterwards.
    private(set) var isReadOnlyFormat = false

    /// The banner text a read-only document's windows carry.
    var readOnlyBannerText: String? {
        isReadOnlyFormat
            ? "Read-Only — this document was saved by a newer version of Arbor." : nil
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
            docID: model.docID,
            // F-AI-5: who made the most recent change — .ai for AI
            // mutations (the store stamps it), surfaced in the package
            // metadata as lastModifiedBy.
            lastModifiedBy: store.lastAuthor
        )
        let root: FileWrapper
        if let packageWrapper {
            root = packageWrapper
        } else {
            root = try ArborPackage.makeFileWrapper(model: model, meta: updated)
        }
        try ArborPackage.updateFileWrapper(root, model: model, meta: updated)
        // F-INT-3: real saves refresh the Quick Look previews. Autosaves
        // skip them on purpose — the SPEC §11.8 autosave budget is 2 ms
        // on the main thread and a render cannot fit there; the previews
        // refresh on the next explicit save.
        if !isAutosavingSave {
            DocumentQuickLook.attachPreviews(to: root, model: model, variant: quickLookVariant)
        }
        if !reviewLog.isEmpty, let encoded = try? ReviewLogCodec.encode(reviewLog) {
            ArborPackage.setStudyLog(Data(encoded.utf8), in: root)
        }
        packageWrapper = root
        meta = updated
        return root
    }

    /// The save operation AppKit is currently performing, recorded by
    /// the `writeSafely` override (NSDocument exposes no direct "is this
    /// an autosave" query).
    nonisolated(unsafe) private var currentSaveOperation: NSDocument.SaveOperationType?

    override func writeSafely(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) throws {
        currentSaveOperation = saveOperation
        defer { currentSaveOperation = nil }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        // F-LIB-3: the library coordinator reindexes this package.
        NotificationCenter.default.post(
            name: MapDocument.didSaveNotification,
            object: self,
            userInfo: [MapDocument.savedFileURLKey: url])
    }

    /// True while an autosave operation drives the current write.
    private var isAutosavingSave: Bool {
        guard let operation = currentSaveOperation else { return false }
        return operation == .autosaveInPlaceOperation || operation == .autosaveElsewhereOperation
            || operation == .autosaveAsOperation
    }

    /// The appearance Quick Look previews render in: the document's
    /// explicit override, else the frontmost window's effective
    /// appearance, else light.
    private var quickLookVariant: ThemeVariant {
        switch model.appearance {
        case .dark: return .dark
        case .light: return .light
        case .auto, .none:
            for case let controller as DocumentWindowController in windowControllers {
                return controller.canvas.effectiveVariant
            }
            return .light
        }
    }

    override static var autosavesInPlace: Bool { true }

    override func willPresentError(_ error: Error) -> Error {
        let ns = error as NSError
        NSLog("ARBOR-DIAG presentError: %@ underlying: %@ fileURL: %@ autosaved: %@",
            ns.debugDescription, String(describing: ns.userInfo[NSUnderlyingErrorKey]),
            String(describing: fileURL), String(describing: autosavedContentsFileURL))
        return super.willPresentError(error)
    }

    /// The native package plus every importable foreign format (F-IO):
    /// the open panel offers them, and the `read(from:ofType:)` override
    /// imports them as new untitled documents.
    override static var readableTypes: [String] {
        [AppIdentity.documentUTI]
            + DocumentImporter.importableFormats.map(\.utTypeIdentifier)
    }

    override static var writableTypes: [String] { [AppIdentity.documentUTI] }

    // MARK: auto-naming (F-EDT-14)

    /// Untitled documents take their display name from the root's text:
    /// first line, path-illegal characters replaced, falling back to
    /// "Untitled" (NSDocument's own default). An explicit document title
    /// (SPEC §8.2) wins. Once renamed or saved, the stored name stands.
    private var storedDisplayName: String?

    override var displayName: String? {
        get {
            // A foreign import is untitled: its name derives from the
            // root until the first save (which gives fileURL a value and
            // falls through to the normal rules).
            if importedUntitled, fileURL == nil {
                return Self.derivedName(for: store.model) ?? "Untitled"
            }
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

    /// A store change rebuilds the visible scene — incrementally when the
    /// change set is small (SPEC §11.3), a full rebuild otherwise. The
    /// change count is left to NSDocument's undo-manager integration (each
    /// closed undo group is a change, each undo/redo moves it
    /// back/forward); counting performs here as well would leave a
    /// document undone back to its saved state still marked edited.
    private func storeDidChange(_ origin: MapStore.ChangeOrigin) {
        if case .nonUndoable = origin {
            // A grading write registered no undo group, so the undo
            // integration can't see it — mark the document dirty here so
            // the next autosave persists the FSRS state and the log
            // (ADR-0015).
            updateChangeCount(.changeDone)
        }
        for case let controller as DocumentWindowController in windowControllers {
            controller.modelDidChange(origin: origin)
        }
    }

    // MARK: study grading (F-STD-3, ADR-0015)

    /// Grades one card now: the node's stored FSRS state advances
    /// through the store's NON-undoable write path (the review log
    /// entry this produces can never be undone, so the state must not
    /// carry an undo step either), and the review is appended to the
    /// document's log. Returns the scheduled next card, or nil when the
    /// card's node vanished or the write failed.
    @discardableResult
    func grade(card: MapStudy.Card, grade: Grade, now: Date = Date()) -> FSRSCard? {
        guard let node = store.model.nodes[card.nodeID] else { return nil }
        let current = StudyStates.cardState(for: card, in: node.study, now: now)
        let review = studyScheduler.review(current, at: now, grade: grade)
        let study = StudyStates.writing(review.card.persisted(), for: card, in: node.study)
        do {
            try store.performWithoutUndo(.setStudy(name: "Grade Card", id: card.nodeID, study: study))
        } catch {
            return nil
        }
        reviewLog.append(review.record(cardID: card.id))
        return review.card
    }

    /// Decodes the package's raw review log bytes; anything undecodable
    /// reads as an empty history (the log is disposable comfort data —
    /// F-STD-3's state lives on the nodes).
    private static func decodeReviewLog(_ data: Data?) -> [ReviewLog] {
        guard let data, let text = String(data: data, encoding: .utf8) else { return [] }
        return (try? ReviewLogCodec.decode(text)) ?? []
    }

    // MARK: external modification (F-DOC-3)

    /// NSFilePresenter (NSDocument already conforms): the document's
    /// file changed under us — iCloud, Dropbox, another copy of Arbor.
    /// Our own coordinated saves bump `fileModificationDate` in lock
    /// step, so an equal date is our own write and ignored. A real
    /// external change reloads automatically when there are no local
    /// edits; with unsaved edits it offers Reload through a sheet (the
    /// document is only ever reverted with the user's consent, and
    /// headless — no window — keeps the edits untouched).
    ///
    /// The presenter contract is nonisolated, but AppKit delivers
    /// NSDocument's presenter callbacks on the main thread (concurrent
    /// document reading is off and the presenter is registered there),
    /// so the main-actor hop below is an assumption the app already
    /// makes in `read(from:ofType:)`.
    override nonisolated func presentedItemDidChange() {
        guard let url = fileURL, let known = fileModificationDate else { return }
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date, modified != known
        else { return }
        MainActor.assumeIsolated {
            if isDocumentEdited {
                offerReloadSheet(url: url)
            } else {
                reloadFromDisk(url)
            }
        }
    }

    /// The F-DOC-3 offer: Reload (default) or Keep Mine. Never shown
    /// headless, and never twice (one sheet per window).
    private func offerReloadSheet(url: URL) {
        guard let window = windowForSheet, window.attachedSheet == nil else { return }
        let documentName = displayName ?? "this document"
        let alert = NSAlert()
        alert.messageText = "The document was changed on disk."
        alert.informativeText =
            "Another application modified \"\(documentName)\". Reload it and discard your local edits?"
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Keep Mine")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.reloadFromDisk(url)
            }
        }
    }

    /// Re-reads the package at `url` through the normal read path and
    /// refreshes every window's scene. A read-only document (F-DOC-4)
    /// stays read-only; a revert of one is the one sanctioned reload.
    private func reloadFromDisk(_ url: URL) {
        do {
            try revert(toContentsOf: url, ofType: fileType ?? AppIdentity.documentUTI)
            for case let controller as DocumentWindowController in windowControllers {
                controller.refreshAfterRevert()
            }
        } catch {
            packageLog.warning("Reload after external change failed: \(String(describing: error))")
        }
    }
}

private let packageLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "document")
