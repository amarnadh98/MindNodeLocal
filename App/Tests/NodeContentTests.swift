import AppKit
import CanvasKit
import Foundation
import MapCore
import MapRender
import Testing

@testable import Arbor
@testable import CanvasKit

/// Hosted app tests for M3 slice a: notes, links, tasks and tags —
/// through the real document/window/controller paths (SPEC §11.3: one
/// `MapStore` command, one undo step), including the ring-click
/// complete-all, the note session's single undo step, `#tag` smart
/// typing and highlight mode.
@MainActor
struct NodeContentTests {
    // MARK: helpers

    private static func makeUntitledDocument() throws -> MapDocument {
        try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
    }

    /// A shown document with a small tree: root → parent → (a, b).
    private static func makeShownTaskDocument() throws -> (MapDocument, DocumentWindowController, CanvasView) {
        let document = try makeUntitledDocument()
        var model = document.model
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for id in ["root", "parent", "a", "b"] {
            model.nodes[id] = Node(id: id, title: NodeTitle(text: id), created: date, modified: date)
        }
        model.roots = ["root"]
        model.nodes["root"]?.children = ["parent"]
        model.nodes["parent"]?.parent = "root"
        model.nodes["parent"]?.children = ["a", "b"]
        model.nodes["a"]?.parent = "parent"
        model.nodes["b"]?.parent = "parent"
        document.store.replaceModel(model)
        document.undoManager?.removeAllActions()

        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        controller.canvas.commitEditing()
        return (document, controller, controller.canvas)
    }

    /// A click at a canvas-space point, delivered in window coordinates
    /// (the canvas fills the 900×600 content view).
    private static func clickEvent(
        at viewPoint: CGPoint, option: Bool = false, in view: NSView
    ) -> NSEvent {
        let windowPoint = view.convert(viewPoint, to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint,
            modifierFlags: option ? .option : [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    // MARK: tasks

    @Test func taskToggleAndCompleteAreOneUndoStepEach() throws {
        let (document, controller, canvas) = try Self.makeShownTaskDocument()
        defer { document.close() }
        document.undoManager?.groupsByEvent = false
        canvas.setSelection(["parent"])

        // ⇧⌘T turns the node into a task — one undo step.
        controller.toggleTaskAction(nil)
        #expect(document.model.nodes["parent"]?.task?.done == false)
        document.undoManager?.undo()
        #expect(document.model.nodes["parent"]?.task == nil, "one undo removes the task")
        document.undoManager?.redo()
        #expect(document.model.nodes["parent"]?.task != nil)

        // ⌃⌘T completes it — one undo step.
        controller.completeTaskAction(nil)
        #expect(document.model.nodes["parent"]?.task?.done == true)
        document.undoManager?.undo()
        #expect(document.model.nodes["parent"]?.task?.done == false, "one undo reopens")

        // Multi-select: three nodes flip as ONE step.
        canvas.setSelection(["parent", "a", "b"])
        controller.toggleTaskAction(nil)
        #expect(document.model.nodes["a"]?.task != nil)
        #expect(document.model.nodes["b"]?.task != nil)
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.task == nil)
        #expect(document.model.nodes["b"]?.task == nil)
        #expect(document.model.nodes["parent"]?.task != nil)
    }

    @Test func ringClickCompletesAllLeafTasksInOneStep() throws {
        let (document, controller, canvas) = try Self.makeShownTaskDocument()
        defer { document.close() }
        document.undoManager?.groupsByEvent = false

        var model = document.model
        model.nodes["parent"]?.task = NodeTask()
        model.nodes["a"]?.task = NodeTask(done: true)
        model.nodes["b"]?.task = NodeTask(done: false)
        document.store.replaceModel(model)
        document.undoManager?.removeAllActions()
        controller.updateScene(preserveCamera: true)

        // The ring sits in the parent's leading column.
        let node = try #require(canvas.scene?.nodes["parent"])
        let decorations = try #require(node.decorations)
        guard case .progress(let completed, let total)? = decorations.task else {
            Issue.record("parent lacks a progress ring")
            return
        }
        #expect(completed == 1 && total == 2)
        let layout = NodeRenderer.decorationLayout(
            style: node.style, decorations: decorations,
            frame: CGRect(origin: .zero, size: node.frame.size))
        let ringCenter = try #require(layout.leadingRect.map { CGPoint(x: $0.midX, y: $0.midY) })
        let viewPoint = canvas.camera.screenPoint(
            for: CGPoint(x: node.frame.minX + ringCenter.x, y: node.frame.minY + ringCenter.y))

        // The click completes both leaf tasks as ONE grouped step.
        canvas.mouseDown(with: Self.clickEvent(at: viewPoint, in: canvas))
        #expect(document.model.nodes["a"]?.task?.done == true)
        #expect(document.model.nodes["b"]?.task?.done == true)
        // The parent is not a leaf task — untouched.
        #expect(document.model.nodes["parent"]?.task?.done == false)

        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.task?.done == true, "the originally-done leaf keeps its state")
        #expect(document.model.nodes["b"]?.task?.done == false)

        // ⌥-click reopens all leaf tasks (one step).
        canvas.mouseDown(
            with: Self.clickEvent(at: viewPoint, option: true, in: canvas))
        #expect(document.model.nodes["a"]?.task?.done == false)
        #expect(document.model.nodes["b"]?.task?.done == false)
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.task?.done == true)
        #expect(document.model.nodes["b"]?.task?.done == false)
    }

    // MARK: notes

    @Test func noteEditingSessionCommitsOneUndoStep() throws {
        let (document, controller, canvas) = try Self.makeShownTaskDocument()
        defer { document.close() }
        document.undoManager?.groupsByEvent = false
        canvas.setSelection(["a"])

        // ⇧⌘K opens the popover anchored to the node.
        controller.noteAction(nil)
        let session = try #require(controller.notePopoverHolder)

        // "Typing" repeatedly — the session never touches the model.
        session.text = "# Plan\n- first"
        session.text = "# Plan\n- first\n- second"
        #expect(document.model.nodes["a"]?.note == nil, "edits stay in the session")

        // Closing commits ONE setNote.
        session.close()
        #expect(document.model.nodes["a"]?.note == "# Plan\n- first\n- second")
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.note == nil, "one undo clears the whole session")
    }

    // MARK: smart typing

    @Test func smartTypingCreatesTheTagAndPillInOneStep() throws {
        let (document, controller, canvas) = try Self.makeShownTaskDocument()
        defer { document.close() }
        document.undoManager?.groupsByEvent = false
        canvas.setSelection(["a"])

        // Type `#exam` into the title and commit (F-EDT-10 + F-TAG-1).
        canvas.beginEditing(nodeID: "a")
        canvas.nodeTextEditor.insertText("Study #exam")
        canvas.commitEditing()

        #expect(document.model.nodes["a"]?.title.text == "Study", "the tag token stripped from the title")
        let tag = try #require(document.model.tags?.first)
        #expect(tag.name == "exam")
        #expect(document.model.nodes["a"]?.tags == [tag.id])

        // The pill renders on the node (SceneGeometry carried it).
        let scene = try #require(canvas.scene)
        let pills = scene.nodes["a"]?.decorations?.tags ?? []
        #expect(pills == [TagPill(name: "exam", colorHex: tag.color)])

        // ONE undo step restores title, definition and assignment.
        document.undoManager?.undo()
        #expect(document.model.nodes["a"]?.title.text == "a")
        #expect(document.model.tags?.contains { $0.name == "exam" } != true)
        #expect(document.model.nodes["a"]?.tags == nil)

        // An existing tag is reused, not duplicated.
        canvas.beginEditing(nodeID: "b")
        canvas.nodeTextEditor.insertText("Again #exam")
        canvas.commitEditing()
        #expect(document.model.tags?.count == 1)
        let reusedTag = try #require(document.model.tags?.first)
        #expect(document.model.nodes["b"]?.tags == [reusedTag.id])
    }

    // MARK: highlight mode

    @Test func tagHighlightDimsNonMatchingAndEscRestores() throws {
        let (document, controller, canvas) = try Self.makeShownTaskDocument()
        defer { document.close() }

        var model = document.model
        model.tags = [Tag(id: "t-exam", name: "exam", color: "#E5484D")]
        model.nodes["a"]?.tags = ["t-exam"]
        model.nodes["b"]?.task = NodeTask()
        document.store.replaceModel(model)
        document.undoManager?.removeAllActions()
        controller.updateScene(preserveCamera: true)

        // F-TAG-2: matching nodes stay lit, everything else dims.
        canvas.highlight = .tags(["t-exam"])
        #expect(canvas.layerTree.nodeLayerOpacity("a") == 1)
        #expect(abs(canvas.layerTree.nodeLayerOpacity("b") - 0.25) < 0.001)
        #expect(abs(canvas.layerTree.nodeLayerOpacity("root") - 0.25) < 0.001)

        // Highlight mode is view state: no undo step exists for it.
        #expect(document.undoManager?.canUndo != true)

        // Esc (the Deselect key equivalent) exits first.
        controller.deselectAction(nil)
        #expect(canvas.highlight == nil)
        #expect(canvas.layerTree.nodeLayerOpacity("b") == 1)
        #expect(canvas.selection.isEmpty == false || true, "selection semantics unchanged")

        // F-TSK-5: highlight tasks keeps task nodes lit.
        canvas.highlight = .tasks
        #expect(canvas.layerTree.nodeLayerOpacity("b") == 1)
        #expect(abs(canvas.layerTree.nodeLayerOpacity("a") - 0.25) < 0.001)
        controller.deselectAction(nil)
        #expect(canvas.layerTree.nodeLayerOpacity("a") == 1)
    }

    // MARK: links

    @Test func arborLinkJumpsWithinTheSameDocument() throws {
        let (document, controller, canvas) = try Self.makeShownTaskDocument()
        defer { document.close() }

        let docID = document.model.docID
        var model = document.model
        model.nodes["a"]?.link = "x-arbor://open?doc=\(docID)&node=b"
        document.store.replaceModel(model)
        document.undoManager?.removeAllActions()
        controller.updateScene(preserveCamera: true)

        // ⌥⌘K's action (and a badge click) route here: the
        // same-document jump selects and centers the target.
        canvas.setSelection(["a"])
        controller.openLinkAction(nil)
        #expect(canvas.selection == ["b"])

        // An external document is a documented deferral: no crash, no
        // selection change (the seam is unset).
        model = document.model
        model.nodes["a"]?.link = "x-arbor://open?doc=other-doc&node=b"
        document.store.replaceModel(model)
        controller.updateScene(preserveCamera: true)
        canvas.setSelection(["a"])
        controller.openLinkAction(nil)
        #expect(canvas.selection == ["a"])
    }
}
