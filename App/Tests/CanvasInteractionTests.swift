import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// The canvas gestures a user reaches for first, driven through the real
/// window controller: the Node Well "+", the ⌫ key and sibling reordering.
@MainActor
struct CanvasInteractionTests {
    private func makeShownTree() throws -> (MapDocument, DocumentWindowController, CanvasView) {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        document.undoManager?.groupsByEvent = false
        let canvas = controller.canvas
        canvas.commitEditing()
        let rootID = try #require(document.model.roots.first)
        for title in ["Alpha", "Beta", "Gamma"] {
            let node = Node(id: UUID().uuidString, title: NodeTitle(text: title))
            try document.store.perform(.addChild(parent: rootID, index: nil, node: node))
        }
        var model = document.model
        model.nodes[rootID]?.structure = "mindmap.right"
        document.store.replaceModel(model)
        return (document, controller, canvas)
    }

    private func key(_ character: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 51))
    }

    @Test func clickingThePlusAddsAChildAndStartsEditingIt() throws {
        let (document, _, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let childID = try #require(document.model.nodes[rootID]?.children.first)
        let before = document.model.nodes.count

        canvas.setSelection([childID])
        let handle = try #require(canvas.addHandles.first)
        let center = handle.center(camera: canvas.camera)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: click)

        #expect(document.model.nodes.count == before + 1)
        let newID = try #require(document.model.nodes[childID]?.children.first)
        #expect(canvas.editingNodeID == newID)
        document.undoManager?.undo()
        #expect(document.model.nodes.count == before)
    }

    @Test func backspaceDeletesTheSelectedNodeAndUndoBringsItBack() throws {
        let (document, _, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let ids = try #require(document.model.nodes[rootID]?.children)
        canvas.setSelection([ids[1]])

        canvas.keyDown(with: try key("\u{7f}"))
        #expect(document.model.nodes[ids[1]] == nil)
        #expect(document.model.nodes[rootID]?.children == [ids[0], ids[2]])

        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.children == ids)
    }

    @Test func optionBackspaceDeletesOnlyTheNodeAndPromotesItsChildren() throws {
        let (document, _, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let ids = try #require(document.model.nodes[rootID]?.children)
        let grandchild = Node(id: "grandchild", title: NodeTitle(text: "g"))
        try document.store.perform(.addChild(parent: ids[1], index: nil, node: grandchild))
        canvas.setSelection([ids[1]])

        canvas.keyDown(with: try key("\u{7f}", flags: .option))
        #expect(document.model.nodes[ids[1]] == nil)
        #expect(document.model.nodes["grandchild"]?.parent == rootID)
    }

    @Test func backspaceWhileTypingEditsTheTextInsteadOfDeletingTheNode() throws {
        let (document, _, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let ids = try #require(document.model.nodes[rootID]?.children)
        canvas.setSelection([ids[0]])
        canvas.beginEditing(nodeID: ids[0])
        canvas.keyDown(with: try key("\u{7f}"))
        #expect(document.model.nodes[ids[0]] != nil)
    }

    @Test func aNodeLeftEmptyDisappearsWhenEditingEnds() throws {
        let (document, controller, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let before = document.model.nodes[rootID]?.children ?? []

        // Tab creates an empty child and starts editing it; finishing
        // without typing removes it again.
        canvas.setSelection([before[0]])
        controller.addChildAction(nil)
        let created = try #require(document.model.nodes[before[0]]?.children.first)
        #expect(canvas.editingNodeID == created)
        canvas.commitEditing()

        #expect(document.model.nodes[created] == nil)
        #expect(canvas.selection == [before[0]], "selection returns to the parent")
        #expect(document.model.nodes[rootID]?.children == before)
        // The creation was undone, not followed by a delete: nothing is
        // left to undo, and ⌘Z can't bring the blank box back.
        #expect(document.undoManager?.canUndo == false)
    }

    @Test func tabOnAnEmptyNodeStopsInsteadOfChainingBlankChildren() throws {
        let (document, controller, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let count = document.model.nodes.count
        canvas.setSelection([rootID])
        controller.addChildAction(nil)
        #expect(document.model.nodes.count == count + 1)
        // ⇥ again on the still-empty new node commits it: it is dropped
        // and no further blank child appears.
        controller.addChildAction(nil)
        #expect(document.model.nodes.count == count)
    }

    @Test func clearingAnExistingNodesTextKeepsTheNode() throws {
        let (document, _, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let child = try #require(document.model.nodes[rootID]?.children.first)
        canvas.beginEditing(nodeID: child)
        canvas.nodeTextEditor.selectAllText()
        canvas.nodeTextEditor.deleteInEditor(forward: false)
        canvas.commitEditing()
        #expect(document.model.nodes[child] != nil)
        #expect(document.model.nodes[child]?.title.text.isEmpty == true)
    }

    @Test func theOnlyRootIsNeverDropped() throws {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        defer { document.close() }
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        let canvas = controller.canvas
        canvas.commitEditing()
        #expect(document.model.roots.count == 1)
        #expect(document.model.nodes.count == 1)
    }
}
