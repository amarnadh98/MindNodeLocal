import AppKit
import CanvasKit
import Foundation
import MapAutomation
import MapCore
import Testing

@testable import Arbor

/// M8 slice 2 (F-INT-5/6, the hosted halves): `x-arbor://open?node=`
/// selects the node in the live canvas, `add` is ONE undo step on the
/// open document, the Service creates a document, the inbox command is
/// one grouped step, malformed links fail gracefully, and MCP-authored
/// store edits carry their `modifiedBy` stamp.
@MainActor
struct AutomationTests {
    private static func makeModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "auto-doc")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for (id, parent) in [("root", nil as String?), ("a", "root"), ("b", "root")] {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: "node \(id)"),
                created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        return model
    }

    /// An open, shown document with the fixture model, registered with
    /// the document controller so the automation's resolution finds it.
    private func openShownDocument() throws -> (MapDocument, DocumentWindowController) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("auto-\(UUID().uuidString).arbor", isDirectory: false)
        let meta = PackageMeta(
            formatVersion: ArborFormat.formatVersion, appVersion: "0.1.0", docID: "auto-doc")
        try ArborPackage.write(Self.makeModel(), meta: meta, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.viewStateStore = ViewStateStore(
            baseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("auto-vs-\(UUID().uuidString)", isDirectory: true))
        controller.showWindow(nil)
        return (document, controller)
    }

    @Test func openRouteSelectsTheNode() throws {
        let (document, controller) = try openShownDocument()
        defer { document.close() }
        #expect(controller.canvas.selection != ["a"])

        try AutomationRouter.shared.apply(.open(doc: "auto-doc", node: "a"))

        #expect(controller.canvas.selection == ["a"])
    }

    @Test func addRouteIsOneUndoStep() throws {
        let (document, _) = try openShownDocument()
        defer { document.close() }
        #expect(document.store.undoManager.canUndo == false)

        try AutomationRouter.shared.apply(.add(doc: "auto-doc", parent: nil, text: "Fresh idea"))

        #expect(document.model.nodes.count == 4)
        #expect(document.store.undoManager.canUndo == true)

        // ONE undo step: a single undo restores the pre-state (journal
        // fields aside — `modified`/`modifiedBy` never rewind, like a
        // file's mtime).
        document.store.undoManager.undo()
        #expect(document.model.roots == ["root"])
        #expect(document.model.nodes.count == 3)
        #expect(document.model.nodes["root"]?.children == ["a", "b"])
        #expect(document.store.undoManager.canUndo == false)
        #expect(document.store.undoManager.canRedo == true)
    }

    @Test func malformedLinksFailGracefully() throws {
        var shown: [String] = []
        let original = AutomationRouter.shared.alertPresenter
        AutomationRouter.shared.alertPresenter = { shown.append($0) }
        defer { AutomationRouter.shared.alertPresenter = original }

        let bogus = try #require(URL(string: "x-arbor://frobnicate?doc=a"))
        AutomationRouter.shared.open(bogus)
        #expect(shown.count == 1)
        #expect(shown[0].contains("unknown route"))

        let docless = try #require(URL(string: "x-arbor://open?node=x"))
        AutomationRouter.shared.open(docless)
        #expect(shown.count == 2)
        #expect(shown[1].contains("\"doc\""))
    }

    @Test func studyRouteClaimsTheStudySeam() throws {
        let (document, _) = try openShownDocument()
        defer { document.close() }
        var claimed: [String] = []
        StudyAutomationSeam.sessionHandler = { docID in
            claimed.append(docID)
            return true
        }
        defer { StudyAutomationSeam.sessionHandler = nil }

        try AutomationRouter.shared.apply(.study(doc: "auto-doc"))

        #expect(claimed == ["auto-doc"])
    }

    @Test func newMapFromSelectionCreatesADocument() throws {
        let before = NSDocumentController.shared.documents.count
        let pboard = NSPasteboard.withUniqueName()
        pboard.setString("# Trip\n\n- [ ] book hotel", forType: .string)
        defer { pboard.releaseGlobally() }

        var failure: NSString = ""
        ServicesResponder.shared.newMapFromSelection(pboard, userData: "", error: &failure)
        #expect(failure.length == 0)

        let newDocuments = NSDocumentController.shared.documents
            .compactMap { $0 as? MapDocument }
            .filter { $0.fileURL == nil && $0.model.roots.count == 1 }
        #expect(NSDocumentController.shared.documents.count == before + 1)
        let created = try #require(newDocuments.last)
        let root = created.model.roots[0]
        #expect(created.model.nodes[root]?.title.text == "Trip")
        #expect(created.model.nodes[root]?.children.count == 1)
        #expect(created.model.nodes[created.model.nodes[root]!.children[0]]?.task?.done == false)
        created.close()
    }

    @Test func inboxCommandCreatesTheInboxNodeWhenMissing() throws {
        var model = Self.makeModel()
        // No Inbox node yet: one grouped command makes one and appends.
        let command = try ServicesResponder.inboxCommand(text: "Read this", in: model)
        try command.apply(to: &model)
        #expect(MapValidator.validate(model).isEmpty)

        let inboxID = try #require(model.roots.last)
        #expect(model.nodes[inboxID]?.title.text == "Inbox")
        #expect(model.nodes[inboxID]?.children.count == 1)
        #expect(
            model.nodes[model.nodes[inboxID]!.children[0]]?.title.text == "Read this")

        // A second append lands under the SAME Inbox node.
        let second = try ServicesResponder.inboxCommand(text: "And this", in: model)
        try second.apply(to: &model)
        #expect(model.nodes[inboxID]?.children.count == 2)
        #expect(model.roots.count == 2)
    }

    @Test func inboxAppendOnAnOpenDocumentIsOneUndoStep() throws {
        let (document, _) = try openShownDocument()
        defer { document.close() }
        // Give the map an Inbox root first.
        try document.store.perform(
            .addRoot(index: nil, node: Node(id: "inbox", title: NodeTitle(text: "Inbox"))))
        document.store.undoManager.removeAllActions()

        let command = try ServicesResponder.inboxCommand(text: "Idea", in: document.model)
        try document.store.perform(command)

        #expect(document.model.nodes["inbox"]?.children.count == 1)
        document.store.undoManager.undo()
        #expect(document.model.nodes["inbox"]?.children.isEmpty == true)
        #expect(document.model.nodes.count == 4)
        #expect(document.store.undoManager.canUndo == false)
    }

    @Test func storeEditsCarryTheirAuthor() throws {
        let store = MapStore(model: Self.makeModel(), undoManager: UndoManager())
        try store.perform(.editText(id: "a", title: NodeTitle(text: "renamed")), author: .mcp)
        #expect(store.model.nodes["a"]?.modifiedBy == .mcp)
        // An untouched node keeps its stamp.
        #expect(store.model.nodes["b"]?.modifiedBy == .user)
    }

    @Test func appDocumentSpaceEditsOpenDocumentsThroughTheStore() async throws {
        let (document, _) = try openShownDocument()
        defer { document.close() }
        let space = AppDocumentSpace()
        #expect(await space.editsAllowed() == false)

        // The store is the mutation path even when edits are disabled at
        // the policy level: the toggle only gates MCP requests, not the
        // space's plumbing.
        try await space.applyCommands(
            [.editText(id: "a", title: NodeTitle(text: "via space"))],
            reference: "auto-doc", author: .mcp)
        #expect(document.model.nodes["a"]?.title.text == "via space")
        #expect(document.model.nodes["a"]?.modifiedBy == .mcp)
        #expect(document.store.undoManager.canUndo == true)
    }
}
