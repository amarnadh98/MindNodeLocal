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
        // Mouse events carry window coordinates.
        let windowPoint = canvas.convert(center, to: nil)
        let click = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
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
        // The drop is an ordinary delete step: ⌘Z restores the blank box
        // (and only it — every other node's text is untouched).
        #expect(document.undoManager?.canUndo == true)
        document.undoManager?.undo()
        #expect(document.model.nodes[created] != nil)
        #expect(document.model.nodes[before[0]]?.title.text == "Alpha")
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

    @Test func draggingTheRootMovesTheWholeMapInOneUndoStep() throws {
        let (document, controller, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        // `replaceModel` doesn't rebuild the scene, so the canvas still
        // renders the pre-replace layout — rebuild it (camera kept) so
        // frame comparisons below compare like with like.
        controller.updateScene(preserveCamera: true)
        let before = try #require(canvas.scene?.nodes[rootID]?.frame)
        func mouse(_ type: NSEvent.EventType, at viewPoint: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: viewPoint, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        // Grab the root's center and drag it straight down, past the
        // child column, to empty canvas — no modifier (ADR-0032). The
        // events carry WINDOW coordinates (unflipped); the canvas is a
        // flipped view, so the view-space points convert through
        // `convert(_:to: nil)` first.
        let start = CGPoint(x: before.midX, y: before.midY)
        let dragDistance: CGFloat = 160
        let end = CGPoint(x: start.x, y: start.y + dragDistance)
        func windowPoint(for modelPoint: CGPoint) -> CGPoint {
            canvas.convert(canvas.camera.screenPoint(for: modelPoint), to: nil)
        }
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: windowPoint(for: start)))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: windowPoint(for: end)))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: windowPoint(for: end)))

        // The whole map moved and stays moved: the root carries a manual
        // offset, and the rebuilt scene (and the minimap's mirror of it)
        // placed the root where it was dropped.
        let movedOffset = try #require(document.model.nodes[rootID]?.offset)
        #expect(abs(movedOffset.y - dragDistance) < 0.5)
        #expect(abs(movedOffset.x) < 0.5)
        let after = try #require(canvas.scene?.nodes[rootID]?.frame)
        #expect(abs(after.midY - before.midY - dragDistance) < 0.5)
        #expect(abs(after.midX - before.midX) < 0.5)
        #expect(canvas.selection == [rootID])
        let minimapRoot = try #require(controller.minimap?.scene?.nodes[rootID]?.frame)
        #expect(abs(minimapRoot.midY - after.midY) < 0.001, "the minimap mirrors the moved map")

        // One undo step restores the pre-drag position exactly.
        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.offset == nil)
        let restored = try #require(canvas.scene?.nodes[rootID]?.frame)
        #expect(abs(restored.midY - before.midY) < 0.001)
        #expect(document.undoManager?.canUndo == false)
    }

    @Test func spaceDragPansTheCanvasAndATapStillReplaceEdits() throws {
        let (document, _, canvas) = try makeShownTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let childID = try #require(document.model.nodes[rootID]?.children.first)

        // Hold Space and drag: the camera pans, and neither the
        // selection nor the map changes (ADR-0033, F-CAN-1). The mouse
        // events carry WINDOW coordinates; the points are built through
        // `convert(_:to: nil)` like the root-drag test above.
        func spaceKey(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: " ",
                    charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        }
        func mouse(_ type: NSEvent.EventType, at viewPoint: CGPoint) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: 1))
        }
        let selectionBefore = canvas.selection
        let originBefore = canvas.camera.origin
        let modelBefore = document.model
        let start = CGPoint(x: 300, y: 200)
        let end = CGPoint(x: 300 + 140, y: 200 + 80)

        canvas.keyDown(with: try spaceKey(.keyDown))
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: start))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: end))
        canvas.keyUp(with: try spaceKey(.keyUp))

        // The camera moved with the drag (content follows the cursor);
        // the selection and the model are untouched.
        #expect(canvas.camera.origin != originBefore)
        #expect(canvas.camera.origin.x < originBefore.x)
        #expect(canvas.selection == selectionBefore)
        #expect(document.model.nodes[rootID]?.children.first == childID)
        #expect(document.model == modelBefore, "a pan is view state, never a model change")

        // A plain Space tap on a selected node still replace-edits its
        // title (ADR-0033's tap-vs-hold rule).
        canvas.setSelection([childID])
        canvas.keyDown(with: try spaceKey(.keyDown))
        #expect(!canvas.isEditing)
        canvas.keyUp(with: try spaceKey(.keyUp))
        #expect(canvas.editingNodeID == childID)
        #expect(canvas.editingDraftTitle?.text == " ")
    }
}
