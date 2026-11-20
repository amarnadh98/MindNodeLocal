import AppKit
import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import CanvasKit

// MARK: - Space-drag pan (F-CAN-1, ADR-0033)

/// Space held = pan mode: a mouse drag pans the camera by the drag
/// delta (even over a node, without selecting or moving it), releasing
/// Space restores the normal canvas, a plain Space tap keeps the
/// F-EDT-2 replace-edit, Space inside the editor still types, and Space
/// during an active node drag still means connect (F-REL-1).
@MainActor
struct SpacePanTests {
    // MARK: event helpers (real NSEvents, like the app delivers)

    private static func spaceKey(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    }

    private static func key(_ character: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 49))
    }

    /// A mouse event at a CANVAS-space point, delivered in window base
    /// coordinates (bottom-left) the way real events are — the flipped
    /// canvas converts them back.
    private static func mouse(
        _ type: NSEvent.EventType, at point: CGPoint, in view: CanvasView
    ) throws -> NSEvent {
        let height = view.bounds.height
        return try #require(
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: point.x, y: height - point.y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Hold Space, drag from `start` by `delta`, release the button
    /// (Space stays held).
    private func spaceDrag(
        _ harness: DragHarness, from start: CGPoint, by delta: CGPoint
    ) throws {
        let view = harness.view
        let end = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
        view.keyDown(with: try Self.spaceKey(.keyDown))
        #expect(view.isSpacePanArmed)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: start, in: view))
        view.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: try Self.mouse(.leftMouseUp, at: end, in: view))
    }

    // MARK: the pan itself

    @Test func spaceHoldAndDragPansTheCameraByTheDragDelta() throws {
        let harness = DragHarness(model: sceneModel())
        let before = harness.view.camera.origin

        try spaceDrag(harness, from: CGPoint(x: 600, y: 450), by: CGPoint(x: 120, y: -60))

        // The content follows the cursor (`panByScreen` semantics): the
        // camera origin moves the opposite way, divided by the scale.
        #expect(abs(harness.view.camera.origin.x - (before.x - 120)) < 0.001)
        #expect(abs(harness.view.camera.origin.y - (before.y + 60)) < 0.001)
        #expect(harness.view.camera.scale == 1)
        // The button is up and no node was grabbed — but Space is
        // still held, so pan mode stays armed.
        #expect(harness.view.isSpacePanArmed)
        #expect(harness.view.drag == nil)
    }

    @Test func spacePanWorksAtAnyZoom() throws {
        let harness = DragHarness(model: sceneModel())
        harness.view.camera = Camera(origin: harness.view.camera.origin, scale: 2)
        let before = harness.view.camera.origin

        // A screen delta of (100, 50) at 200% zoom is half that in
        // model space.
        try spaceDrag(harness, from: CGPoint(x: 600, y: 450), by: CGPoint(x: 100, y: 50))

        #expect(abs(harness.view.camera.origin.x - (before.x - 50)) < 0.001)
        #expect(abs(harness.view.camera.origin.y - (before.y - 25)) < 0.001)
    }

    @Test func spacePanOverANodeNeitherSelectsMovesNorEditsIt() throws {
        let harness = DragHarness(model: sceneModel())
        let modelBefore = try #require(harness.view.dragModel)
        let originBefore = harness.view.camera.origin
        harness.view.setSelection(["root"])
        var selectionChanges = 0
        harness.view.onSelectionChange = { _ in selectionChanges += 1 }
        var drops = 0
        harness.view.onDrop = { command, _ in
            if command != nil { drops += 1 }
        }

        // The whole drag happens over branch-1's frame.
        let center = try harness.screen(harness.center(of: "branch-1"))
        try spaceDrag(harness, from: center, by: CGPoint(x: 220, y: 150))

        // The camera moved by the drag delta…
        #expect(harness.view.camera.origin != originBefore)
        // …and nothing else happened: no selection change, no node
        // drag, no drop command, no editing session, the model intact.
        #expect(selectionChanges == 0)
        #expect(drops == 0)
        #expect(harness.view.drag == nil)
        #expect(!harness.view.isEditing)
        #expect(harness.view.selection == ["root"])
        #expect(harness.view.dragModel == modelBefore)
    }

    @Test func spaceClickOnEmptyCanvasKeepsTheSelectionAndNeverRubberBands() throws {
        let harness = DragHarness(model: sceneModel())
        harness.view.setSelection(["branch-0"])

        harness.view.keyDown(with: try Self.spaceKey(.keyDown))
        harness.view.mouseDown(
            with: try Self.mouse(.leftMouseDown, at: CGPoint(x: 1100, y: 850), in: harness.view))
        harness.view.mouseUp(
            with: try Self.mouse(.leftMouseUp, at: CGPoint(x: 1100, y: 850), in: harness.view))

        #expect(harness.view.selection == ["branch-0"])
    }

    // MARK: releasing Space

    @Test func releasingSpaceRestoresSelectionRubberBandAndNodeDrags() throws {
        let harness = DragHarness(model: sceneModel())
        let view = harness.view

        // A full Space hold + release cycle leaves the canvas normal.
        view.keyDown(with: try Self.spaceKey(.keyDown))
        view.keyUp(with: try Self.spaceKey(.keyUp))
        #expect(!view.isSpacePanArmed)

        // A click on a node selects it again…
        let nodePoint = try harness.screen(harness.center(of: "branch-0"))
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: nodePoint, in: view))
        view.mouseUp(with: try Self.mouse(.leftMouseUp, at: nodePoint, in: view))
        #expect(view.selection == ["branch-0"])

        // …and a drag on empty canvas rubber-bands again (F-CAN-4).
        let topLeft = CGPoint(x: 100, y: 100)
        let bottomRight = CGPoint(x: 1000, y: 800)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: topLeft, in: view))
        view.mouseDragged(with: try Self.mouse(.leftMouseDragged, at: bottomRight, in: view))
        view.mouseUp(with: try Self.mouse(.leftMouseUp, at: bottomRight, in: view))
        #expect(view.selection.contains("root"))
    }

    @Test func releasingSpaceMidDragFinishesThePan() throws {
        let harness = DragHarness(model: sceneModel())
        let view = harness.view
        let before = view.camera.origin

        // Space released while the button is still down: the gesture
        // isn't handed back — the drag keeps panning until mouse-up.
        view.keyDown(with: try Self.spaceKey(.keyDown))
        let start = CGPoint(x: 600, y: 450)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(
            with: try Self.mouse(.leftMouseDragged, at: CGPoint(x: start.x + 40, y: start.y), in: view))
        view.keyUp(with: try Self.spaceKey(.keyUp))
        #expect(!view.isSpacePanArmed)
        view.mouseDragged(
            with: try Self.mouse(.leftMouseDragged, at: CGPoint(x: start.x + 100, y: start.y), in: view))
        view.mouseUp(
            with: try Self.mouse(.leftMouseUp, at: CGPoint(x: start.x + 100, y: start.y), in: view))

        #expect(abs(view.camera.origin.x - (before.x - 100)) < 0.001)
        #expect(!view.isSpacePanArmed)
    }

    // MARK: the tap keeps its meaning (ADR-0033's tap-vs-hold rule)

    @Test func aSpaceTapStillReplaceEditsTheSelectedNode() throws {
        let harness = DragHarness(model: sceneModel())
        harness.view.setSelection(["branch-1"])

        // The down no longer edits (it arms pan mode)…
        harness.view.keyDown(with: try Self.spaceKey(.keyDown))
        #expect(harness.view.isSpacePanArmed)
        #expect(!harness.view.isEditing)
        // …the up performs the deferred replace-edit, prefilled " "
        // exactly as the old keyDown path did (F-EDT-2).
        harness.view.keyUp(with: try Self.spaceKey(.keyUp))
        #expect(harness.view.editingNodeID == "branch-1")
        #expect(harness.view.editingDraftTitle?.text == " ")
    }

    @Test func aSpaceTapWithNoSelectionEditsNothing() throws {
        let harness = DragHarness(model: sceneModel())
        harness.view.setSelection([])

        harness.view.keyDown(with: try Self.spaceKey(.keyDown))
        harness.view.keyUp(with: try Self.spaceKey(.keyUp))
        #expect(!harness.view.isEditing)
    }

    @Test func aSpaceHoldWithMouseDownInBetweenNeverReplaceEdits() throws {
        let harness = DragHarness(model: sceneModel())
        harness.view.setSelection(["branch-1"])

        // Space down, a click, Space up: the hold won — a pan (here a
        // zero-delta one), never a replace-edit.
        harness.view.keyDown(with: try Self.spaceKey(.keyDown))
        harness.view.mouseDown(
            with: try Self.mouse(.leftMouseDown, at: CGPoint(x: 600, y: 450), in: harness.view))
        harness.view.mouseUp(
            with: try Self.mouse(.leftMouseUp, at: CGPoint(x: 600, y: 450), in: harness.view))
        harness.view.keyUp(with: try Self.spaceKey(.keyUp))

        #expect(!harness.view.isEditing)
        #expect(harness.view.selection == ["branch-1"])
    }

    // MARK: Space while editing types (never intercepted)

    @Test func spaceWhileEditingTypesAndNeverArmsPan() throws {
        let harness = DragHarness(model: sceneModel())
        harness.view.setSelection(["branch-1"])
        harness.view.beginEditing(nodeID: "branch-1")

        // The canvas never sees the key in the real app (the overlay's
        // text view is first responder); even delivered directly it
        // must neither arm pan nor disturb the session.
        harness.view.keyDown(with: try Self.spaceKey(.keyDown))
        harness.view.keyUp(with: try Self.spaceKey(.keyUp))
        #expect(!harness.view.isSpacePanArmed)
        #expect(harness.view.editingNodeID == "branch-1")

        // And Space typed into the editor lands in the draft (here it
        // replaces the selected title, F-EDT-2 style, then appends).
        harness.view.nodeTextEditor.insertText("x")
        harness.view.nodeTextEditor.insertText(" ")
        #expect(harness.view.editingDraftTitle?.text == "x ")
    }

    // MARK: Space during a node drag still means connect (F-REL-1)

    @Test func spaceDuringAnActiveNodeDragStillDropsAConnection() throws {
        let harness = DragHarness(model: sceneModel())
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in
            if let command { dropped = command }
        }

        // A node drag already active when Space goes down: connect,
        // never pan mode.
        try harness.grab("branch-1")
        let start = try harness.center(of: "branch-1")
        harness.drag(to: CGPoint(x: start.x + 5, y: start.y + 5))
        guard case .active = harness.view.drag else {
            Issue.record("expected an active drag")
            return
        }
        harness.view.keyDown(with: try Self.spaceKey(.keyDown))
        #expect(!harness.view.isSpacePanArmed)

        let end = try harness.center(of: "branch-0")
        harness.drag(to: end)
        harness.view.keyUp(with: try Self.spaceKey(.keyUp))
        harness.drop(at: end)

        guard case .addConnection(let connection)? = dropped else {
            Issue.record("expected an addConnection drop, got \(String(describing: dropped))")
            return
        }
        #expect(Set([connection.from, connection.to]) == Set(["branch-1", "branch-0"]))
    }

    // MARK: modifiers keep their events

    @Test func modifiedSpaceNeverArmsPanAndKeepsTheOldKeyPath() throws {
        let harness = DragHarness(model: sceneModel())
        harness.view.setSelection(["branch-1"])

        // ⇧Space falls through to the old keyDown replace-edit path…
        harness.view.keyDown(with: try Self.key(" ", .shift))
        #expect(!harness.view.isSpacePanArmed)
        #expect(harness.view.editingNodeID == "branch-1")
        harness.view.commitEditing()

        // …and ⌘Space does neither (menu/shortcut territory).
        harness.view.setSelection(["branch-1"])
        harness.view.keyDown(with: try Self.key(" ", .command))
        #expect(!harness.view.isSpacePanArmed)
        #expect(!harness.view.isEditing)
    }
}
