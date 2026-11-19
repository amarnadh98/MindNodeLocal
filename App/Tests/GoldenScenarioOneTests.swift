import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Golden-path scenario 1, end to end (SPEC §3 item 1 — the M1 exit
/// criterion): launch → new map → type the root → ⇥ child → ⏎ siblings →
/// drag a branch to reparent → save → close (as quit would) → reopen, and
/// everything is restored: the tree (titles, structure, order and the
/// reparented branch under its new parent), the camera (F-CAN-8), the
/// selection, a clean change count, and exactly one undo step per user
/// action.
///
/// Every step drives the REAL app paths, never the store directly: the
/// document comes out of `NSDocumentController` with its real window,
/// typing goes into the editing overlay's `NSTextView` (F-CAN-3 opened it
/// on the placeholder root), and ⇥/⏎/⎋/⌘= are key events delivered the
/// way the window delivers them — the overlay's `performKeyEquivalent`
/// while a session is open (the routing that beats the menu's key
/// equivalents), the canvas's own keyDown otherwise. The drag is
/// synthesized mouseDown/mouseDragged/mouseUp over real view points. The
/// view-state sidecar runs against a temp directory (ADR-0005) and the
/// save against a temp `.arbor` URL (iCloud Drive in SPEC §3, stood in
/// for by a test).
@MainActor
struct GoldenScenarioOneTests {
    /// The ids the editing loop creates, captured as each new node opens.
    private struct IDs {
        var root: String
        var alpha = ""
        var alpha1 = ""
        var alpha2 = ""
        var beta = ""
        var gamma = ""

        init(root: String) {
            self.root = root
        }
    }

    @Test func launchNewMapEditDragSaveQuitReopenRestoresEverything() async throws {
        let viewStateBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-viewstate-\(UUID().uuidString)", isDirectory: true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString).arbor")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: viewStateBase)
        }

        // Launch → New map: the untitled document through the document
        // controller, window shown (F-CAN-3 seeds the placeholder root and
        // opens it for editing).
        let (document, controller) = try Self.makeShownUntitledDocument(viewStateBase: viewStateBase)
        let canvas = controller.canvas
        let rootID = try #require(document.model.roots.first)

        // Type the root, grow the "Alpha" branch (⇥ children, a ⏎ sibling),
        // then climb back with a click and add "Beta" and "Gamma" as
        // siblings of "Alpha" — the root ends with three children.
        let ids = try buildTree(controller: controller, rootID: rootID)
        #expect(controller.window?.title == "Golden")
        // Plain typing on the semibold-styled root must not record a
        // phantom bold run (the theme style is not a style override).
        #expect(document.model.nodes[ids.root]?.title.runs.isEmpty == true)
        #expect(children(of: ids.root, in: document.model) == [ids.alpha, ids.beta, ids.gamma])
        #expect(children(of: ids.alpha, in: document.model) == [ids.alpha1, ids.alpha2])

        // Drag the whole "Alpha" branch onto "Beta" (F-EDT-5): one
        // command, one undo step, the selection stays on the moved branch.
        try drag(ids.alpha, onto: ids.beta, canvas: canvas)
        #expect(document.model.nodes[ids.alpha]?.parent == ids.beta)
        #expect(children(of: ids.beta, in: document.model) == [ids.alpha])
        #expect(children(of: ids.root, in: document.model) == [ids.beta, ids.gamma])
        #expect(canvas.selection == [ids.alpha])

        // One undo step per user action: 6 text commits + 5 creates + the
        // drag = 12 (in the app each keystroke closes one per-event undo
        // group; a synchronous test disables event grouping — see
        // InlineEditingTests — so each store step counts separately).
        var undoSteps = 0
        while document.undoManager?.canUndo == true {
            document.undoManager?.undo()
            undoSteps += 1
        }
        #expect(undoSteps == 12)
        // Fully undone, the map is the pristine seeded placeholder again…
        #expect(document.model.roots == [ids.root])
        #expect(document.model.nodes.count == 1)
        #expect(document.model.nodes[ids.root]?.title.text.isEmpty == true)
        #expect(document.model.nodes[ids.root]?.children.isEmpty == true)
        // …and redo walks it back to the post-drag tree, step for step.
        var redoSteps = 0
        while document.undoManager?.canRedo == true {
            document.undoManager?.redo()
            redoSteps += 1
        }
        #expect(redoSteps == 12)
        #expect(children(of: ids.beta, in: document.model) == [ids.alpha])

        settle()

        // Select a node and move the camera: one ⌘+ zoom stop, then a pan
        // (F-CAN-2), so the reopen has a non-default camera to restore.
        try click(ids.alpha1, canvas: canvas)
        #expect(canvas.selection == [ids.alpha1])
        sendKey(to: canvas, "=", modifiers: [.command])
        #expect(abs(canvas.camera.scale - 1.25) < 0.001)
        canvas.panByScreen(dx: 120, dy: -64)
        let savedCamera = canvas.camera
        let savedDocID = document.model.docID

        // ⌘S (the first save of an untitled document is a Save As; the
        // real save machinery minus the panel)…
        try await document.save(to: url, ofType: AppIdentity.documentUTI, for: .saveAsOperation)
        #expect(document.fileURL == url)
        #expect(!document.isDocumentEdited)
        // …then quit: closing the window flushes the view-state sidecar
        // (F-CAN-8).
        document.close()
        #expect(ViewStateStore(baseURL: viewStateBase).load(docID: savedDocID) != nil)

        // Reopen through the document controller and show the window.
        let reopened = try Self.openShownDocument(at: url, viewStateBase: viewStateBase)
        let reopenedController = try #require(
            reopened.windowControllers.first as? DocumentWindowController)
        let reopenedCanvas = reopenedController.canvas
        // The tree round-trips exactly — titles, structure, order and the
        // reparented branch under its new parent (journal timestamps
        // aside; see TreeSignature).
        #expect(TreeSignature(model: reopened.model) == TreeSignature(model: document.model))
        #expect(title(of: ids.root, in: reopened.model) == "Golden")
        #expect(title(of: ids.alpha, in: reopened.model) == "Alpha")
        #expect(title(of: ids.alpha1, in: reopened.model) == "Alpha 1")
        #expect(title(of: ids.alpha2, in: reopened.model) == "Alpha 2")
        #expect(title(of: ids.beta, in: reopened.model) == "Beta")
        #expect(title(of: ids.gamma, in: reopened.model) == "Gamma")
        #expect(children(of: ids.root, in: reopened.model) == [ids.beta, ids.gamma])
        #expect(children(of: ids.beta, in: reopened.model) == [ids.alpha])
        #expect(children(of: ids.alpha, in: reopened.model) == [ids.alpha1, ids.alpha2])
        #expect(children(of: ids.gamma, in: reopened.model).isEmpty == true)

        // Camera and selection restored (F-CAN-8): scale and origin within
        // 0.5 pt — not a fresh zoom-to-fit.
        #expect(!reopenedCanvas.needsInitialFit)
        #expect(abs(reopenedCanvas.camera.scale - savedCamera.scale) < 0.001)
        #expect(abs(reopenedCanvas.camera.origin.x - savedCamera.origin.x) < 0.5)
        #expect(abs(reopenedCanvas.camera.origin.y - savedCamera.origin.y) < 0.5)
        #expect(reopenedCanvas.selection == [ids.alpha1])
        // Reopening is not a mutation: still a clean document.
        #expect(!reopened.isDocumentEdited)

        reopened.close()
    }

    // MARK: the editing flow

    /// Types the root title, then grows the map with the editing keys:
    /// ⇥ → "Alpha", ⇥ again → its child "Alpha 1" (a real branch to
    /// drag), ⏎ → the sibling "Alpha 2". A click climbs back to "Alpha";
    /// ⏎ edits it (F-EDT-2) and ⏎ again commits the unchanged title (no
    /// phantom undo step) and creates the sibling "Beta"; one more ⏎
    /// commits and creates "Gamma". ⎋ commits without creating.
    private func buildTree(controller: DocumentWindowController, rootID: String) throws -> IDs {
        let canvas = controller.canvas
        var ids = IDs(root: rootID)
        // F-CAN-3: the window opened already editing the placeholder root
        // ("Central Idea" is the hint, not text).
        #expect(canvas.isEditing)
        #expect(canvas.editingNodeID == rootID)

        canvas.nodeTextEditor.insertText("Golden")
        sendKey(to: canvas, "\t")
        ids.alpha = try #require(canvas.editingNodeID)
        #expect(canvas.isEditing)

        canvas.nodeTextEditor.insertText("Alpha")
        sendKey(to: canvas, "\t")
        ids.alpha1 = try #require(canvas.editingNodeID)

        canvas.nodeTextEditor.insertText("Alpha 1")
        sendKey(to: canvas, "\r")
        ids.alpha2 = try #require(canvas.editingNodeID)

        canvas.nodeTextEditor.insertText("Alpha 2")
        sendKey(to: canvas, "\u{1b}")
        #expect(!canvas.isEditing)

        // The mouse-friendly way back up after descending: click "Alpha",
        // then the ⏎-on-selection edit rule and the commit-and-create.
        try click(ids.alpha, canvas: canvas)
        #expect(canvas.selection == [ids.alpha])
        sendKey(to: canvas, "\r")
        #expect(canvas.isEditing)
        #expect(canvas.editingNodeID == ids.alpha)
        sendKey(to: canvas, "\r")
        ids.beta = try #require(canvas.editingNodeID)

        canvas.nodeTextEditor.insertText("Beta")
        sendKey(to: canvas, "\r")
        ids.gamma = try #require(canvas.editingNodeID)

        canvas.nodeTextEditor.insertText("Gamma")
        sendKey(to: canvas, "\u{1b}")
        #expect(!canvas.isEditing)
        return ids
    }

    // MARK: event synthesis

    /// Delivers a key event the way the window does: to the first
    /// responder — the editing overlay's `NSTextView` while a session is
    /// open, whose `performKeyEquivalent` claims the editing keys (⇥/⏎
    /// commit-and-create, ⎋ commits, F-EDT-1) before the menu's key
    /// equivalents — else to the canvas's own keyDown (⏎ edits the single
    /// selection per F-EDT-2, ⌘+/⌘= zooms per F-CAN-2).
    private func sendKey(to canvas: CanvasView, _ key: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = Self.keyEvent(key, modifiers: modifiers)
        let responder = canvas.window?.firstResponder
        if responder !== canvas, responder?.performKeyEquivalent(with: event) == true {
            return
        }
        canvas.keyDown(with: event)
    }

    /// Synthesizes the reparent gesture on the canvas: mouseDown on `id`,
    /// mouseDragged past the 4 pt click threshold (SPEC §6.2) with the
    /// drop point last (the target resolves at the final drag event),
    /// then mouseUp — landing `id`'s whole branch on `targetID` as ONE
    /// command (F-EDT-5).
    private func drag(_ id: String, onto targetID: String, canvas: CanvasView) throws {
        let start = try nodeCenter(id, canvas)
        let end = try nodeCenter(targetID, canvas)
        let midway = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        canvas.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: start))
        canvas.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: midway))
        canvas.mouseDragged(with: Self.mouseEvent(.leftMouseDragged, at: end))
        canvas.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: end))
    }

    /// A plain click (no drag): mouseDown selects, mouseUp completes.
    private func click(_ id: String, canvas: CanvasView) throws {
        let point = try nodeCenter(id, canvas)
        canvas.mouseDown(with: Self.mouseEvent(.leftMouseDown, at: point))
        canvas.mouseUp(with: Self.mouseEvent(.leftMouseUp, at: point))
    }

    /// The node's center in canvas (view) coordinates.
    private func nodeCenter(_ id: String, _ canvas: CanvasView) throws -> CGPoint {
        let frame = try #require(canvas.scene?.nodes[id]?.frame, "no scene frame for \(id)")
        return canvas.camera.screenPoint(for: CGPoint(x: frame.midX, y: frame.midY))
    }

    private static func keyEvent(_ key: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }

    /// A mouse event at a canvas-space point, delivered in window
    /// coordinates (the window's content view is 900×600, the canvas is
    /// flipped).
    private static func mouseEvent(_ type: NSEvent.EventType, at canvasPoint: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: CGPoint(x: canvasPoint.x, y: 600 - canvasPoint.y),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    // MARK: documents

    /// The untitled document with its window shown and the view-state
    /// sidecar pointed at a temp directory.
    private static func makeShownUntitledDocument(
        viewStateBase: URL
    ) throws -> (MapDocument, DocumentWindowController) {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(
                ofType: AppIdentity.documentUTI) as? MapDocument)
        // One long run-loop pass in a test would merge the store's undo
        // groups by event; the app closes one event group per key event.
        document.undoManager?.groupsByEvent = false
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.viewStateStore = ViewStateStore(baseURL: viewStateBase)
        controller.viewStateSaveDelay = .milliseconds(50)
        controller.showWindow(nil)
        return (document, controller)
    }

    /// A saved document reopened through the document controller, with the
    /// same sidecar base so the stored view state restores.
    private static func openShownDocument(at url: URL, viewStateBase: URL) throws -> MapDocument {
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.viewStateStore = ViewStateStore(baseURL: viewStateBase)
        controller.showWindow(nil)
        return document
    }

    // MARK: small helpers

    private func children(of id: String, in model: MapModel) -> [String] {
        model.nodes[id]?.children ?? []
    }

    private func title(of id: String, in model: MapModel) -> String {
        model.nodes[id]?.title.text ?? ""
    }

    /// NSDocument posts its undo-group change counts on a later run-loop
    /// turn; spin briefly so `isDocumentEdited` reflects them before the
    /// save clears the count.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

/// A model's user-visible shape: roots order, parents, children order,
/// titles and the other content fields — everything except the journal
/// timestamps (`created`/`modified`/`modifiedBy`), whose sub-millisecond
/// tail the ISO-8601 coder (`Date.ISO8601FormatStyle`) rounds away on
/// save, like a file's mtime.
private struct TreeSignature: Equatable {
    struct Node: Equatable {
        var parent: String?
        var children: [String]
        var title: NodeTitle
        var folded: Bool
        var offset: ModelOffset?
        var note: String?
        var link: String?
    }

    var roots: [String]
    var nodes: [String: Node]

    init(model: MapModel) {
        roots = model.roots
        nodes = model.nodes.mapValues { node in
            Node(
                parent: node.parent, children: node.children, title: node.title,
                folded: node.folded, offset: node.offset, note: node.note, link: node.link)
        }
    }
}
