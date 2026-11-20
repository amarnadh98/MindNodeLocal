import AppKit
import Foundation
import MapAutomation
import MapCore

/// The seam the study UI (another slice, F-STD-4) claims session starts
/// through. `x-arbor://study?doc=` and the StartStudySession intent both
/// open the document and then call `requestSession`; the study UI either
/// registers `sessionHandler` (returns true when it took the session) or
/// observes `startSessionNotification` — posted with the docID as the
/// object either way.
enum StudyAutomationSeam {
    static let startSessionNotification = Notification.Name("ArborAutomationStartStudySession")

    /// The study UI's hook: returning true means the session was claimed.
    /// `nonisolated(unsafe)` because the registration is a one-time
    /// main-thread setup by the study UI's owner.
    nonisolated(unsafe) static var sessionHandler: (@MainActor (String) -> Bool)?

    /// Asks the study UI to start a session for `docID`. False when nobody
    /// claimed it (the study UI is another agent's; until it lands, the
    /// notification is the contract).
    @MainActor
    static func requestSession(docID: String) -> Bool {
        if let sessionHandler, sessionHandler(docID) {
            return true
        }
        NotificationCenter.default.post(name: startSessionNotification, object: docID)
        return false
    }
}

/// Applies `x-arbor://` routes (F-INT-5). Malformed links never crash or
/// touch documents: they surface a readable alert. Route logic is
/// factored into per-route methods so hosted tests drive them directly.
@MainActor
final class AutomationRouter {
    static let shared = AutomationRouter()

    /// How failures reach the user. Injectable so tests capture messages
    /// instead of raising panels.
    var alertPresenter: @MainActor (String) -> Void = { message in
        let alert = NSAlert()
        alert.messageText = "Arbor link problem"
        alert.informativeText = message
        alert.runModal()
    }

    func presentError(_ message: String) {
        alertPresenter(message)
    }

    /// The `application(_:open:)` entry point.
    func open(_ url: URL) {
        do {
            try apply(try ArborURL.parse(url))
        } catch let error as ArborURL.ParseError {
            alertPresenter("The link is not valid: \(error). Supported links: open, new, add, study.")
        } catch {
            alertPresenter("The link could not be applied: \(error)")
        }
    }

    /// Applies one parsed route.
    func apply(_ route: ArborURL.Route) throws {
        switch route {
        case .open(let doc, let node):
            try openMap(doc: doc, node: node)
        case .newDocument(let title, let outline):
            let document = try createDocument(title: title, outline: outline)
            document.showWindows()
        case .add(let doc, let parent, let text):
            try addNode(doc: doc, parent: parent, text: text)
        case .study(let doc):
            try openMap(doc: doc, node: nil)
            _ = StudyAutomationSeam.requestSession(docID: doc)
        }
    }

    // MARK: routes

    /// `open`: bring the map forward (opening it if needed) and select
    /// the node.
    func openMap(doc reference: String, node: String?) throws {
        if let open = AppMapDirectory.openDocument(matching: reference) {
            front(open)
            if let node {
                select(node: node, in: open)
            }
            return
        }
        // Not open: resolve a file asynchronously (recents + scan; the
        /// main actor stays free), then open it.
        let directory = AppMapDirectory()
        Task<Void, Never> {
            guard let record = try? await directory.findMap(matching: reference) else {
                self.presentError("no map matches \"\(reference)\"")
                return
            }
            NSDocumentController.shared.openDocument(
                withContentsOf: URL(fileURLWithPath: record.path), display: true
            ) { document, _, error in
                MainActor.assumeIsolated {
                    if let document {
                        self.opened(document: document, node: node)
                    } else if let error {
                        self.presentError("The map could not be opened: \(error)")
                    }
                }
            }
        }
    }

    private func opened(document: NSDocument, node: String?) {
        guard let node else { return }
        select(node: node, in: document)
    }

    /// `new`: an untitled document whose initial content is the imported
    /// outline — the sanctioned import path (SPEC §5.17), so the fresh
    /// document is not a command-apply on a pristine placeholder.
    @discardableResult
    func createDocument(title: String?, outline: String?) throws -> MapDocument {
        guard
            let document = try NSDocumentController.shared.makeUntitledDocument(
                ofType: AppIdentity.documentUTI
            ) as? MapDocument
        else {
            throw RouteError.noSuchMapOpen("untitled document creation failed")
        }
        var model: MapModel
        if let outline, !outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model = try OutlineConversion.importModel(from: outline)
        } else {
            model = MapModel.emptyDocument()
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.title = title
        }
        // Keep the identity the untitled document was created with —
        // and its default theme (F-STY-6): an `x-arbor://new` map is a
        // new document, and an imported outline carries no theme of
        // its own (ADR-0034).
        model.docID = document.model.docID
        if model.theme == nil {
            model.theme = document.model.theme
        }
        document.store.replaceModel(model)
        document.updateChangeCount(.changeDone)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        return document
    }

    /// `add`: one undo step — a single `insertSubtrees` of the parsed
    /// outline under `parent` (a node id or exact title; nil or "root"
    /// appends under the first root), or as new roots when the map has
    /// no roots yet.
    func addNode(doc reference: String, parent: String?, text: String) throws {
        guard let open = AppMapDirectory.openDocument(matching: reference) else {
            throw RouteError.noSuchMapOpen(reference)
        }
        let model = open.model
        let parentID: String?
        if let parent, !parent.isEmpty, parent.caseInsensitiveCompare("root") != .orderedSame {
            guard let resolved = NodeSearch.resolve(reference: parent, in: model) else {
                throw RouteError.noSuchNode(parent)
            }
            parentID = resolved
        } else {
            parentID = model.roots.first
        }
        guard
            let command = try OutlineConversion.insertCommand(
                fromText: text, parent: parentID,
                index: parentID.map { model.nodes[$0]?.children.count ?? 0 } ?? model.roots.count,
                in: model)
        else {
            throw RouteError.emptyOutline
        }
        try open.store.perform(command)
        open.updateChangeCount(.changeDone)
        selectNewNodes(from: command, in: open)
    }

    enum RouteError: Error, CustomStringConvertible {
        case noSuchMap(String)
        case noSuchMapOpen(String)
        case noSuchNode(String)
        case emptyOutline

        var description: String {
            switch self {
            case .noSuchMap(let reference): "no map matches \"\(reference)\""
            case .noSuchMapOpen(let reference):
                "no open map matches \"\(reference)\" — open the map first, then use the link"
            case .noSuchNode(let reference): "no node \"\(reference)\" in that map"
            case .emptyOutline: "the link's text has no outline content"
            }
        }
    }

    // MARK: window helpers

    private func front(_ document: NSDocument) {
        for controller in document.windowControllers {
            controller.showWindow(nil)
        }
        document.windowControllers.first?.window?.makeKey()
    }

    /// Selects (and centers) a node in every window controller's canvas.
    /// Selection ids under a folded parent sanitize away on the canvas
    /// (ADR-0005's contract); unfolding for deep links is left to the
    /// user — folds are model state, and the route must not mutate them.
    private func select(node: String, in document: NSDocument) {
        for case let controller as DocumentWindowController in document.windowControllers {
            controller.canvas.setSelection([node])
            controller.canvas.jumpToSelectionAction(nil)
        }
    }

    /// Selects the nodes the insert command just created (its top ids).
    private func selectNewNodes(from command: MapCommand, in document: NSDocument) {
        var ids: [String] = []
        if case .insertSubtrees(_, let anchors) = command {
            ids = anchors.map(\.id)
        }
        guard !ids.isEmpty else { return }
        for case let controller as DocumentWindowController in document.windowControllers {
            controller.canvas.setSelection(Set(ids))
            controller.canvas.jumpToSelectionAction(nil)
        }
    }
}
