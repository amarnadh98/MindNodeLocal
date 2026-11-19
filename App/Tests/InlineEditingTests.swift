import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Hosted app tests for the inline editing slice (M1 6a): the full
/// document flow — new node → edit → commit → undo restores (F-EDT-1/2),
/// the "Central Idea" placeholder on a brand-new document (F-CAN-3),
/// the double-click floating root (F-CAN-5) and untitled-document
/// auto-naming (F-EDT-14).
@MainActor
struct InlineEditingTests {
    @Test func newNodeEditCommitUndoRestores() throws {
        let document = try Self.makeShownDocument()
        // One long run-loop pass in a test would merge the store's undo
        // groups by event; the app closes one event group per key event.
        document.undoManager?.groupsByEvent = false
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas
        let rootID = try #require(document.model.roots.first)

        // The brand-new document opened already editing its placeholder
        // root; leave that session first (⎋).
        canvas.commitEditing()
        #expect(document.model.nodes[rootID]?.title.text == "")

        // F-EDT-2: type over the root's empty session.
        controller.editTitleAction(nil)
        #expect(canvas.isEditing)
        canvas.nodeTextEditor.insertText("My Map")
        canvas.commitEditing()
        #expect(document.model.nodes[rootID]?.title.text == "My Map")
        // F-EDT-14: the window title follows the auto-derived name.
        #expect(controller.window?.title == "My Map")

        // ⇥ creates a child that is immediately in edit mode (F-EDT-1).
        canvas.setSelection([rootID])
        controller.addChildAction(nil)
        let childID = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[childID]?.parent == rootID)

        // Typing is a draft; commit is ONE editText command.
        canvas.nodeTextEditor.insertText("hello")
        #expect(document.model.nodes[childID]?.title.text.isEmpty == true)
        canvas.commitEditing()
        #expect(document.model.nodes[childID]?.title.text == "hello")

        // Undo the commit: the child survives with its old (empty) title.
        document.undoManager?.undo()
        #expect(document.model.nodes[childID]?.title.text == "")

        // Undo the add: the child subtree is gone.
        document.undoManager?.undo()
        #expect(document.model.nodes[childID] == nil)

        // Undo the root's edit.
        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.title.text == "")

        document.close()
    }

    @Test func newDocumentOpensEditingItsPlaceholderRoot() throws {
        let document = try Self.makeShownDocument()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas
        let rootID = try #require(document.model.roots.first)

        // F-CAN-3: centred root, already editing, "Central Idea" as a
        // hint — not text.
        #expect(canvas.isEditing)
        #expect(canvas.editingNodeID == rootID)
        #expect(canvas.nodeTextEditor.placeholder == "Central Idea")
        #expect(document.model.nodes[rootID]?.title.text == "")

        // The hint never commits as text.
        canvas.commitEditing()
        #expect(document.model.nodes[rootID]?.title.text == "")
        #expect(document.model.nodes[rootID] != nil)

        document.close()
    }

    @Test func doubleClickOnEmptyCanvasCreatesAFloatingRootEditing() throws {
        let document = try Self.makeShownDocument()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas
        canvas.commitEditing()

        let emptyPoint = CGPoint(x: 700, y: 500)
        canvas.mouseDown(with: Self.mouseEvent(at: emptyPoint, clickCount: 2))

        let newRootID = try #require(canvas.editingNodeID)
        #expect(canvas.isEditing)
        #expect(newRootID != document.model.roots.first)
        #expect(document.model.nodes[newRootID]?.parent == nil)
        #expect(document.model.nodes[newRootID]?.title.text == "")
        // The floating root sits at the click point (F-CAN-5): its
        // manual offset (SPEC §8.2) moves the auto slot there — compare
        // in model space, where the scene frames live.
        #expect(document.model.nodes[newRootID]?.offset != nil)
        let modelPoint = canvas.camera.modelPoint(for: emptyPoint)
        let frame = try #require(canvas.scene?.nodes[newRootID]?.frame)
        #expect(abs(frame.midX - modelPoint.x) < 1)
        #expect(abs(frame.midY - modelPoint.y) < 1)

        // The whole gesture (root + offset) is one undo step.
        document.undoManager?.undo()
        #expect(document.model.nodes[newRootID] == nil)

        document.close()
    }

    // MARK: auto-naming (F-EDT-14)

    @Test func untitledDocumentNamesItselfFromTheRootText() throws {
        let document = try Self.makeUntitledDocument()
        let rootID = UUID().uuidString
        try document.store.perform(
            .addRoot(index: nil, node: Node(id: rootID, title: NodeTitle(text: "Quarterly Plan"))))
        #expect(document.displayName == "Quarterly Plan")

        // First line only; path-illegal characters become dashes.
        try document.store.perform(
            .editText(id: rootID, title: NodeTitle(text: "Line one\nLine two")))
        #expect(document.displayName == "Line one")
        try document.store.perform(
            .editText(id: rootID, title: NodeTitle(text: "bad/name:here")))
        #expect(document.displayName == "bad-name-here")

        // Whitespace-only has no usable name: NSDocument's own
        // "Untitled" (numbered per session by the document controller)
        // stands.
        try document.store.perform(.editText(id: rootID, title: NodeTitle(text: "  ")))
        #expect(MapDocument.derivedName(for: document.model) == nil)
        #expect(document.displayName?.hasPrefix("Untitled") == true)

        // An explicit document title (SPEC §8.2) wins.
        var titled = document.model
        titled.title = "Explicit"
        document.store.replaceModel(titled)
        #expect(document.displayName == "Explicit")
    }

    @Test func savedDocumentKeepsItsFileNameAsDisplayName() throws {
        let document = try Self.makeUntitledDocument()
        let rootID = UUID().uuidString
        try document.store.perform(
            .addRoot(index: nil, node: Node(id: rootID, title: NodeTitle(text: "Saved Map"))))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1-edit-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.write(to: url, ofType: AppIdentity.documentUTI)

        let reopened = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        #expect(reopened.fileURL == url)
        #expect(reopened.displayName?.hasPrefix(url.deletingPathExtension().lastPathComponent) == true)
        reopened.close()
    }

    // MARK: helpers

    private static func makeUntitledDocument() throws -> MapDocument {
        try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
    }

    /// An untitled document with its window shown (which also seeds and
    /// begins editing the F-CAN-3 placeholder root).
    private static func makeShownDocument() throws -> MapDocument {
        let document = try makeUntitledDocument()
        document.makeWindowControllers()
        for case let controller as DocumentWindowController in document.windowControllers {
            controller.showWindow(nil)
        }
        return document
    }

    /// A click at a canvas-space point, delivered in window coordinates.
    private static func mouseEvent(at canvasPoint: CGPoint, clickCount: Int) -> NSEvent {
        let windowPoint = CGPoint(x: canvasPoint.x, y: 600 - canvasPoint.y)
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 0)!
    }
}
