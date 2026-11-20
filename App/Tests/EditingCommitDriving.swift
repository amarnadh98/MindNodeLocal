import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// The shown-document fixture and the real-event driving helpers the
/// blank-node and side-inheritance suites share: a shown document whose
/// undo manager keeps the app's real `groupsByEvent` grouping, real
/// NSEvent key/mouse events delivered to the live views, and one
/// explicit undo group drawn around each driven event — the group
/// boundary the app's event loop provides and the hosted test host
/// (which bypasses NSApp dispatch) does not.
@MainActor
enum EditingCommitDriving {
    /// The shown-document fixture with the app's REAL undo grouping:
    /// `groupsByEvent` stays on and every driven event is followed by
    /// a run-loop pump, so each event's undo group closes like in the
    /// app. The root keeps the default balanced structure.
    static func makeShownBalancedTree() throws -> (
        MapDocument, DocumentWindowController, CanvasView
    ) {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        #expect(document.undoManager?.groupsByEvent == true, "the app's real grouping stays on")
        let canvas = controller.canvas
        canvas.commitEditing()
        let rootID = try #require(document.model.roots.first)
        for title in ["Alpha", "Beta", "Gamma"] {
            let node = Node(id: UUID().uuidString, title: NodeTitle(text: title))
            try document.store.perform(.addChild(parent: rootID, index: nil, node: node))
        }
        // Close the setup's own event group, so the driven events below
        // register against a clean stack — the test host's run loop
        // never closes a `groupsByEvent` group on its own (see
        // `driveEvent`).
        if let manager = document.undoManager, manager.groupingLevel > 0 {
            manager.endUndoGrouping()
        }
        settle()
        return (document, controller, canvas)
    }

    /// Lets the run loop turn between two driven events, so windows
    /// redraw and pending observers fire — the same pause the app's
    /// event loop takes between two user events.
    static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }

    /// Drives one user event exactly like the app's event loop: every
    /// command the event performs lands in ONE undo group — with the
    /// real `groupsByEvent` grouping (kept on, asserted in
    /// `makeShownBalancedTree`) a whole ⏎ keyDown's `editText` +
    /// post-commit create share one undo step, which is the shape that
    /// produced the reported data loss. The hosted test host drives
    /// views directly, bypassing NSApp's dispatch, so the event
    /// boundary's group is drawn explicitly here.
    static func driveEvent(
        of document: MapDocument, _ event: () throws -> Void
    ) rethrows {
        let manager = document.undoManager
        manager?.beginUndoGrouping()
        try event()
        // The event's body may itself have balanced the group away
        // (an undo() inside it auto-closes the open group); never end
        // twice.
        if manager?.groupingLevel ?? 0 > 0 {
            manager?.endUndoGrouping()
        }
        settle()
    }

    /// A real key-down event for `character` at `keyCode`.
    static func keyDown(
        _ character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode))
    }

    /// A real left-mouse-down at a VIEW point (converted to the window
    /// coordinates `mouseDown(with:)` consumes).
    static func click(at viewPoint: CGPoint, in canvas: CanvasView) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvas.convert(viewPoint, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// A view point guaranteed to sit on empty canvas: well below every
    /// node frame and every Node Well "+".
    static func emptyCanvasPoint(in canvas: CanvasView) -> CGPoint {
        let lowest = canvas.scene?.nodes.values.map { $0.frame.minY }.min() ?? 0
        return canvas.camera.screenPoint(for: CGPoint(x: 0, y: lowest - 200))
    }

    /// The live editor overlay (the window's real first responder
    /// while a session is open).
    static func liveEditor(
        in canvas: CanvasView, editing: String
    ) throws -> NSTextView {
        #expect(canvas.editingNodeID == editing)
        return try #require(canvas.window?.firstResponder as? NSTextView)
    }

    /// Types `text` into the live editor through real key-down events.
    static func type(_ text: String, into editor: NSTextView) throws {
        for character in text {
            editor.keyDown(with: try keyDown(String(character), keyCode: 0))
        }
    }

    /// Ends the open session the way a user does: a click on empty
    /// canvas. Driven bare — no explicit group around it — so the
    /// blank-drop's own commands (and any undo the OLD implementation
    /// performed) run against the undo stack exactly as they would
    /// between two real events.
    static func clickAwayFromEditing(in canvas: CanvasView) throws {
        canvas.mouseDown(with: try click(at: emptyCanvasPoint(in: canvas), in: canvas))
        settle()
    }

    /// No blank leaf survives anywhere under a parent (the map's own
    /// empty root is the root placeholder, not a stray box).
    static func assertNoBlankChildren(in document: MapDocument) {
        let blanks = document.model.nodes.values.filter {
            DocumentWindowController.isBlankLeaf($0) && $0.parent != nil
        }
        #expect(blanks.isEmpty, "no empty node is left behind: \(blanks.map(\.id))")
    }
}
