import AppKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Document safety (SPEC §5.18, F-DOC-1/3/4): a newer-format package
/// opens read-only with a banner and a locked store; an external
/// modification reloads when the document is clean and keeps local
/// edits when it isn't; the Lock menu item rides NSDocument's own
/// action; the File menu carries the safety items and validates them
/// honestly.
/// The suite serializes: every test shares `NSDocumentController`'s
/// document list and the app's menu.
@Suite(.serialized)
@MainActor
struct DocumentSafetyTests {
    private func makeEditableDocument() throws -> MapDocument {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        document.undoManager?.groupsByEvent = false
        return document
    }

    /// Spins briefly so NSDocument's posted change counts settle.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Locking and unlocking complete asynchronously — `lock:` autosaves
    /// first and then coordinates with the file system, and a cold
    /// runner's first file-coordination round trip can outlast any fixed
    /// spin. Poll with a deadline instead; the caller still asserts the
    /// end state, so a lock that genuinely fails fails the test.
    private func waitFor(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 10
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        return item
    }

    private func shownController(of document: MapDocument) throws -> DocumentWindowController {
        if let controller = document.windowControllers.first as? DocumentWindowController {
            controller.showWindow(nil)
            return controller
        }
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        return controller
    }

    // MARK: F-DOC-4 newer formatVersion

    @Test func newerFormatPackageOpensReadOnlyWithABannerAndLockedStore() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var model = MapModel.emptyDocument()
        model.formatVersion = ArborFormat.formatVersion + 1
        let rootID = UUID().uuidString
        model.roots = [rootID]
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "From the Future"),
            created: timestamp, modified: timestamp)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("future-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }

        // Read-only state: the flag, the banner text, the locked store.
        #expect(document.isReadOnlyFormat)
        #expect(document.readOnlyBannerText != nil)
        #expect(document.store.isReadOnly)
        // The future content itself came through (unknown keys ignored).
        #expect(document.model.nodes[rootID]?.title.text == "From the Future")

        // The enforcement: every mutation through the store is refused.
        #expect(throws: ArborError.self) {
            try document.store.perform(.addChild(parent: rootID, index: nil, node: Node(id: "x")))
        }
        #expect(document.model.nodes["x"] == nil)
        #expect(document.undoManager?.canUndo == false)

        // The truth-telling: the window carries the banner, the mutating
        // and saving menu items disable, the browsing items stay live.
        let controller = try shownController(of: document)
        #expect(controller.readOnlyBanner != nil)
        #expect(
            !controller.validateMenuItem(
                item("Add Child", action: #selector(DocumentWindowController.addChildAction(_:)))))
        #expect(
            !controller.validateMenuItem(
                item("Delete", action: #selector(DocumentWindowController.deleteSubtreeAction(_:)))))
        #expect(!controller.validateMenuItem(item("Save", action: #selector(NSDocument.save(_:)))))
        #expect(!controller.validateMenuItem(item("Save As", action: #selector(NSDocument.saveAs(_:)))))
        #expect(!controller.validateMenuItem(item("Duplicate", action: #selector(NSDocument.duplicate(_:)))))
        #expect(
            controller.validateMenuItem(
                item("Browse All Versions", action: #selector(NSDocument.browseVersions(_:)))))
        // Reading stays: copy and the navigation items.
        #expect(controller.validateMenuItem(item("Copy", action: #selector(NSText.copy(_:)))))
    }

    @Test func sameFormatPackageStaysEditable() throws {
        let url = try savedSimpleDocument(title: "Present")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }
        #expect(!document.isReadOnlyFormat)
        #expect(!document.store.isReadOnly)
        #expect(document.readOnlyBannerText == nil)
    }

    // MARK: F-DOC-3 external modification

    @Test func cleanDocumentAutoReloadsAfterAnExternalChange() throws {
        let url = try savedSimpleDocument(title: "Before")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }
        let controller = try shownController(of: document)
        let oldRootID = try #require(document.model.roots.first)
        #expect(document.model.nodes[oldRootID]?.title.text == "Before")
        #expect(!document.isDocumentEdited)

        // The external edit: another app writes the package.
        var replacement = MapModel.emptyDocument()
        let newRoot = UUID().uuidString
        replacement.roots = [newRoot]
        replacement.nodes[newRoot] = Node(id: newRoot, title: NodeTitle(text: "After"))
        try ArborPackage.write(replacement, meta: PackageMeta(docID: replacement.docID), to: url)

        // The presenter callback: NSFilePresenter's contract, delivered
        // here synchronously.
        document.presentedItemDidChange()

        // Auto-reloaded: the model, the change count and the scene.
        #expect(document.model.roots == [newRoot])
        #expect(document.model.nodes[newRoot]?.title.text == "After")
        #expect(!document.isDocumentEdited)
        #expect(controller.canvas.scene?.nodes[newRoot] != nil)
        #expect(controller.canvas.scene?.nodes[oldRootID] == nil)
    }

    @Test func editedDocumentKeepsLocalEditsWhenTheFileChangesHeadlessly() throws {
        let url = try savedSimpleDocument(title: "Before")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }
        document.undoManager?.groupsByEvent = false
        let rootID = try #require(document.model.roots.first)

        // Local edits.
        try document.store.perform(.editText(id: rootID, title: NodeTitle(text: "My Local Work")))
        settle()
        #expect(document.isDocumentEdited)

        // The external edit arrives with no window on screen: nothing
        // reloads and nothing is lost (the sheet offer needs a window).
        var replacement = MapModel.emptyDocument()
        let newRoot = UUID().uuidString
        replacement.roots = [newRoot]
        replacement.nodes[newRoot] = Node(id: newRoot, title: NodeTitle(text: "After"))
        try ArborPackage.write(replacement, meta: PackageMeta(docID: replacement.docID), to: url)
        document.presentedItemDidChange()
        #expect(document.model.nodes[rootID]?.title.text == "My Local Work")
    }

    @Test func ownSavesDoNotTriggerAReload() throws {
        let url = try savedSimpleDocument(title: "Stable")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }

        // Our own write bumps fileModificationDate in lock step; the
        // presenter sees an equal date and does nothing.
        try document.writeSafely(to: url, ofType: AppIdentity.documentUTI, for: .saveOperation)
        document.presentedItemDidChange()
        let rootID = try #require(document.model.roots.first)
        #expect(document.model.nodes[rootID]?.title.text == "Stable")
    }

    // MARK: F-DOC-1 lock

    @Test func lockMenuActionLocksAndUnlocksTheFile() throws {
        let url = try savedSimpleDocument(title: "Lockable")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }
        let controller = try shownController(of: document)

        // Menu truth-telling: Lock is offered (unlocked, saved); Unlock
        // is not.
        #expect(controller.validateMenuItem(item("Lock", action: #selector(NSDocument.lock(_:)))))
        #expect(
            !controller.validateMenuItem(item("Unlock", action: #selector(NSDocument.unlock(_:)))))

        document.lock(nil)
        waitFor(document.isLocked)
        #expect(document.isLocked)
        #expect(!controller.validateMenuItem(item("Lock", action: #selector(NSDocument.lock(_:)))))
        #expect(controller.validateMenuItem(item("Unlock", action: #selector(NSDocument.unlock(_:)))))

        document.unlock(nil)
        waitFor(!document.isLocked)
        #expect(!document.isLocked)
    }

    @Test func versionsAndRevertItemsNeedAFile() throws {
        let document = try makeEditableDocument()
        defer { document.close() }
        let controller = try shownController(of: document)
        // Untitled: nothing to browse or revert to.
        #expect(
            !controller.validateMenuItem(
                item("Browse All Versions", action: #selector(NSDocument.browseVersions(_:)))))
        #expect(
            !controller.validateMenuItem(
                item("Last Saved", action: #selector(NSDocument.revertToSaved(_:)))))
        #expect(!controller.validateMenuItem(item("Lock", action: #selector(NSDocument.lock(_:)))))
    }

    // MARK: helpers

    /// A saved one-root document on disk.
    private func savedSimpleDocument(title: String) throws -> URL {
        var model = MapModel.emptyDocument()
        let rootID = UUID().uuidString
        model.roots = [rootID]
        model.nodes[rootID] = Node(id: rootID, title: NodeTitle(text: title))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("safety-\(UUID().uuidString).arbor")
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)
        return url
    }
}
