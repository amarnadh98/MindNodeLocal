import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// F-LAY-1/ADR-0034: a sibling or inserted parent created by ⏎/⌥⏎/⌥⇥
/// or the toolbar inherits the anchor's pinned side, so the next box
/// lands on the same side of the balanced map as the node it was
/// created from — the reported "Return puts my next box on the LEFT
/// side" fix. Driven through the real editing commit path with real
/// key events.
@MainActor
struct SideInheritanceTests {
    @Test func returnAfterTypingInARightPinnedChildCreatesARightSibling() throws {
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
        #expect(document.model.nodes[first]?.side == .right)
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.type(
                "right side", into: EditingCommitDriving.liveEditor(in: canvas, editing: first))
        }
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.liveEditor(in: canvas, editing: first)
                .keyDown(with: try EditingCommitDriving.keyDown("\r", keyCode: 36))
        }
        let rootFrame = try #require(canvas.scene?.nodes[rootID]?.frame)

        // The next box lands on the SAME (right) side of the map, not
        // on the left where the balanced layout's alternation would put
        // an unpinned node.
        let sibling = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[sibling]?.side == .right)
        let siblingFrame = try #require(canvas.scene?.nodes[sibling]?.frame)
        #expect(siblingFrame.minX > rootFrame.maxX, "the new box is drawn right of the root")
        #expect(document.model.nodes[first]?.title.text == "right side")

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[sibling] == nil)
    }

    @Test func returnAfterTypingInALeftPinnedChildCreatesALeftSibling() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)

        canvas.setSelection([rootID])
        let handle = try #require(
            canvas.addHandles.first { $0.nodeID == rootID && $0.side == .left })
        try EditingCommitDriving.driveEvent(of: document) {
            canvas.mouseDown(with: try EditingCommitDriving.click(at: handle.center(camera: canvas.camera), in: canvas))
        }
        let first = try #require(document.model.nodes[rootID]?.children.last)
        #expect(document.model.nodes[first]?.side == .left)
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.type(
                "left side", into: EditingCommitDriving.liveEditor(in: canvas, editing: first))
        }
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.liveEditor(in: canvas, editing: first)
                .keyDown(with: try EditingCommitDriving.keyDown("\r", keyCode: 36))
        }
        let rootFrame = try #require(canvas.scene?.nodes[rootID]?.frame)

        let sibling = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[sibling]?.side == .left)
        let siblingFrame = try #require(canvas.scene?.nodes[sibling]?.frame)
        #expect(siblingFrame.maxX < rootFrame.minX, "the new box is drawn left of the root")
        #expect(document.model.nodes[first]?.title.text == "left side")

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[sibling] == nil)
    }

    @Test func aSiblingCreatedFromTheToolbarInheritsTheAnchorSide() throws {
        let (document, controller, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)

        // Pin Alpha right the way the canvas does (the Node Well pins
        // root children by the clicked side), then create its sibling
        // with the no-keyboard path: the pin carries over.
        let alpha = try #require(document.model.nodes[rootID]?.children.first)
        try document.store.perform(.setSide(id: alpha, side: .right))
        canvas.setSelection([alpha])
        try EditingCommitDriving.driveEvent(of: document) {
            controller.addSiblingBelow(nil)
        }
        let sibling = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[sibling]?.side == .right)

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[sibling] == nil)
        EditingCommitDriving.assertNoBlankChildren(in: document)
    }

    @Test func optionReturnOnAnUntouchedNodeKeepsItAndDropsTheBlankSibling() throws {
        let (document, _, canvas) = try EditingCommitDriving.makeShownBalancedTree()
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let before = try #require(document.model.nodes[rootID]?.children)

        // ⌥⏎ while editing an existing (still-untouched) node: the node
        // is never dropped — only the blank sibling above goes away.
        canvas.setSelection([before[1]])
        canvas.beginEditing(nodeID: before[1])
        try EditingCommitDriving.driveEvent(of: document) {
            try EditingCommitDriving.liveEditor(in: canvas, editing: before[1])
                .keyDown(with: try EditingCommitDriving.keyDown("\r", keyCode: 36, flags: .option))
        }
        let sibling = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[rootID]?.children[1] == sibling)

        try EditingCommitDriving.clickAwayFromEditing(in: canvas)
        #expect(document.model.nodes[sibling] == nil)
        #expect(document.model.nodes[rootID]?.children == before)
        #expect(document.model.nodes[before[1]]?.title.text == "Beta")
    }
}
