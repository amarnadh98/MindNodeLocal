import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// ADR-0034's regression suite, reproducing the reported data loss:
/// with the app's real undo grouping, a ⏎ commit-and-create presses the
/// just-typed `editText` and the post-commit add into ONE undo group,
/// and the old blank-drop's `undo()` reverted the typed text with the
/// blank sibling. These tests keep `groupsByEvent` on and drive real
/// key events (⏎ = keyCode 36) through the live editor; they fail on
/// the pre-fix code and pass with the deterministic-command drop.
@MainActor
struct BlankNodeDropTests {
    @Test func clickingAwayAfterReturnKeepsTheTypedText() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)

        // The user's exact flow: "+" on the root's right edge, type,
        // ⏎ for the next box, then click anywhere else on the canvas.
        canvas.setSelection([rootID])
        let handle = try #require(
            canvas.addHandles.first { $0.nodeID == rootID && $0.side == .right })
        try EditingCommitDriving.driveEvent(of: document) {
            canvas.mouseDown(with: try EditingCommitDriving.click(at: handle.center(camera: canvas.camera), in: canvas))
        }
        let first = try #require(document.model.nodes[rootID]?.children.last)
        let typed = "idea"
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.type(typed, into: EditingCommitDriving.liveEditor(in: canvas, editing: first))
        }
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.liveEditor(in: canvas, editing: first)
                .keyDown(with: try EditingCommitDriving.keyDown("\r", keyCode: 36))
        }

        // ⏎ committed the text and created the still-blank next box.
        let sibling = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[sibling] != nil)
        #expect(document.model.nodes[first]?.title.text == typed)

        // Click away from the blank sibling: it goes away…
        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[sibling] == nil, "the blank sibling is gone")
        #expect(canvas.editingNodeID == nil)
        EditingCommitDriving.assertNoBlankChildren(in: document)
        // …and — the reported data loss — the typed text SURVIVES.
        #expect(document.model.nodes[first]?.title.text == typed)
        #expect(document.model.nodes[rootID]?.children.last == first)

        // The drop is one ordinary delete step: one ⌘Z restores the
        // blank box and nothing else.
        document.undoManager?.undo()
        #expect(document.model.nodes[sibling] != nil)
        #expect(document.model.nodes[first]?.title.text == typed)
    }

    @Test func clickingAwayAfterTabKeepsTheTypedText() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)

        canvas.setSelection([rootID])
        let handle = try #require(
            canvas.addHandles.first { $0.nodeID == rootID && $0.side == .right })
        try EditingCommitDriving.driveEvent(of: document) {
            canvas.mouseDown(with: try EditingCommitDriving.click(at: handle.center(camera: canvas.camera), in: canvas))
        }
        let first = try #require(document.model.nodes[rootID]?.children.last)
        let typed = "thought"
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.type(typed, into: EditingCommitDriving.liveEditor(in: canvas, editing: first))
        }
        // ⇥ commits and creates a child of the typed node.
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.liveEditor(in: canvas, editing: first)
                .keyDown(with: try EditingCommitDriving.keyDown("\t", keyCode: 48))
        }

        let child = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[child]?.parent == first)
        // A child of a non-root keeps no side pin.
        #expect(document.model.nodes[child]?.side == nil)

        // Click away from the blank child: it is dropped and the typed
        // text above survives.
        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[child] == nil)
        EditingCommitDriving.assertNoBlankChildren(in: document)
        #expect(document.model.nodes[first]?.title.text == typed)
    }

    @Test func anEmptyInsertedParentIsDroppedAndTheAnchorReturnsToItsSlot() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let before = try #require(document.model.nodes[rootID]?.children)

        // ⌥⇥ while typing: the typed node slips under a fresh blank
        // parent. Ending that session empty must promote the typed
        // node back into its slot — not leave a stray empty box above.
        canvas.setSelection([before[1]])
        canvas.beginEditing(nodeID: before[1])
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.type(
                "typed", into: EditingCommitDriving.liveEditor(in: canvas, editing: before[1]))
        }
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.liveEditor(in: canvas, editing: before[1])
                .keyDown(with: try EditingCommitDriving.keyDown("\t", keyCode: 48, flags: .option))
        }
        let inserted = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[inserted]?.children == [before[1]])
        #expect(document.model.nodes[rootID]?.children[1] == inserted)

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[inserted] == nil)
        #expect(document.model.nodes[rootID]?.children == before)
        #expect(document.model.nodes[before[1]]?.title.text == "typed")
        EditingCommitDriving.assertNoBlankChildren(in: document)
    }

    @Test func escapeOnAnEmptyInsertedParentAlsoRestoresTheAnchor() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let before = try #require(document.model.nodes[rootID]?.children)

        canvas.setSelection([before[1]])
        canvas.beginEditing(nodeID: before[1])
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.type("kept", into: EditingCommitDriving.liveEditor(in: canvas, editing: before[1]))
        }
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.liveEditor(in: canvas, editing: before[1])
                .keyDown(with: try EditingCommitDriving.keyDown("\t", keyCode: 48, flags: .option))
        }
        let inserted = try #require(canvas.editingNodeID)

        // ⎋ ends the session: same tidy-up as a click away.
        try EditingCommitDriving.liveEditor(in: canvas, editing: inserted)
            .keyDown(with: try EditingCommitDriving.keyDown("\u{1b}", keyCode: 53))
        EditingCommitDriving.settle()
        #expect(document.model.nodes[inserted] == nil)
        #expect(document.model.nodes[rootID]?.children == before)
        #expect(document.model.nodes[before[1]]?.title.text == "kept")
    }

    @Test func escapeDropsANodeCreatedAndLeftEmpty() throws {
        let (document, controller, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let before = try #require(document.model.nodes[rootID]?.children)
        let count = document.model.nodes.count

        // ⇥ creates a blank child; ⎋ on it, still empty, drops it.
        canvas.setSelection([before[1]])
        try EditingCommitDriving.driveEvent(of: document) {
            controller.addChildAction(nil)
        }
        let created = try #require(canvas.editingNodeID)
        try EditingCommitDriving.liveEditor(in: canvas, editing: created)
            .keyDown(with: try EditingCommitDriving.keyDown("\u{1b}", keyCode: 53))
        EditingCommitDriving.settle()

        #expect(document.model.nodes[created] == nil)
        #expect(document.model.nodes.count == count)
        #expect(document.model.nodes[rootID]?.children == before)
        EditingCommitDriving.assertNoBlankChildren(in: document)
    }

    @Test func focusLossDropsANodeLeftEmpty() throws {
        let (document, controller, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let before = try #require(document.model.nodes[rootID]?.children)
        let count = document.model.nodes.count

        // A window switch mid-session (the overlay resigns focus) runs
        // the same empty-commit tidy-up.
        canvas.setSelection([before[1]])
        try EditingCommitDriving.driveEvent(of: document) {
            controller.addChildAction(nil)
        }
        let created = try #require(canvas.editingNodeID)
        canvas.window?.makeFirstResponder(nil)
        EditingCommitDriving.settle()

        #expect(document.model.nodes[created] == nil)
        #expect(document.model.nodes.count == count)
        #expect(document.model.nodes[rootID]?.children == before)
        EditingCommitDriving.assertNoBlankChildren(in: document)
    }

    @Test func aBlankFloatingRootFromADoubleClickDoesNotSurviveClickingAway() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootsBefore = document.model.roots

        // Double-click on empty canvas creates a floating root open for
        // typing; clicking away without typing removes it again.
        let point = EditingCommitDriving.emptyCanvasPoint(in: canvas)
        let doubleClick = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 2, pressure: 1))
        try EditingCommitDriving.driveEvent(of: document) {
            canvas.mouseDown(with: doubleClick)
        }
        let created = try #require(canvas.editingNodeID)
        #expect(document.model.roots.count == rootsBefore.count + 1)

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[created] == nil)
        #expect(document.model.roots == rootsBefore)
    }

    @Test func aBlankNewRootFromShiftReturnDoesNotSurviveClickingAway() throws {
        let (document, controller, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootsBefore = document.model.roots

        try EditingCommitDriving.driveEvent(of: document) {
            controller.addRootAction(nil)
        }
        let created = try #require(canvas.editingNodeID)
        #expect(document.model.roots.count == rootsBefore.count + 1)

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[created] == nil)
        #expect(document.model.roots == rootsBefore)
    }

    @Test func aBlankChildFromTheNodeWellDoesNotSurviveClickingAway() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let count = document.model.nodes.count

        canvas.setSelection([rootID])
        let handle = try #require(
            canvas.addHandles.first { $0.nodeID == rootID && $0.side == .right })
        try EditingCommitDriving.driveEvent(of: document) {
            canvas.mouseDown(with: try EditingCommitDriving.click(at: handle.center(camera: canvas.camera), in: canvas))
        }
        let created = try #require(canvas.editingNodeID)
        #expect(document.model.nodes.count == count + 1)

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[created] == nil)
        #expect(document.model.nodes.count == count)
        EditingCommitDriving.assertNoBlankChildren(in: document)
    }
}
