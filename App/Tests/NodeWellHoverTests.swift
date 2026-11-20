import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// The Node Well's hover + repeated-add flows (SPEC §6.2, the user
/// reports: "sometimes I can't add a box after clicking the plus from
/// the previous box", "can't get the plus on the LEFT side"),
/// end-to-end through the real window controller with real
/// `NSEvent`s. Every "+" click must add exactly one child — hover and
/// selected variants, on the previous box and on the new one.
@MainActor
struct NodeWellHoverTests {
    /// The shared shown-tree fixture (see CanvasInteractionTests): a
    /// root with Alpha/Beta/Gamma and no stored structure, children
    /// pinned to `pin` when set. Built through the store so the
    /// canvas scene stays in sync with the model.
    private func makeShownTree(pin: SidePin?) throws
        -> (MapDocument, DocumentWindowController, CanvasView)
    {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        document.undoManager?.groupsByEvent = false
        let canvas = controller.canvas
        canvas.commitEditing()
        // The placeholder-root session's commit leaves the root
        // selected; these flows start from an idle canvas.
        canvas.setSelection([])
        let rootID = try #require(document.model.roots.first)
        for title in ["Alpha", "Beta", "Gamma"] {
            var node = Node(id: UUID().uuidString, title: NodeTitle(text: title))
            node.side = pin
            try document.store.perform(.addChild(parent: rootID, index: nil, node: node))
        }
        return (document, controller, canvas)
    }

    /// A real mouse event for `viewPoint` (view space — carried as
    /// window coordinates like every AppKit event).
    private func mouse(
        _ type: NSEvent.EventType, at viewPoint: CGPoint, in canvas: CanvasView
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
    }

    /// Hover a node (crossing its frame on the way, like a real
    /// pointer), then travel out to its "+" button; returns the
    /// button's view-space center.
    private func hoverPlus(
        on id: String, side: AddHandleSide, in canvas: CanvasView
    ) throws -> CGPoint {
        let frame = try #require(canvas.scene?.nodes[id]?.frame)
        let center = canvas.camera.screenPoint(for: CGPoint(x: frame.midX, y: frame.midY))
        canvas.mouseMoved(with: try mouse(.mouseMoved, at: center, in: canvas))
        let anchorX = side == .left ? frame.minX : frame.maxX
        let edge = canvas.camera.screenPoint(for: CGPoint(x: anchorX, y: frame.midY))
        let direction: CGFloat = side == .left ? -1 : 1
        let spot = CGPoint(x: edge.x + direction * AddHandle.offset, y: edge.y)
        canvas.mouseMoved(with: try mouse(.mouseMoved, at: spot, in: canvas))
        return spot
    }

    @Test func hoveringABoxShowsItsPlusAndClickingAddsAChildWithoutSelecting() throws {
        let (document, _, canvas) = try makeShownTree(pin: .right)
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let alpha = try #require(document.model.nodes[rootID]?.children.first)
        let before = document.model.nodes.count

        // Nothing selected, pointer idle: no plus anywhere.
        #expect(canvas.addHandles.isEmpty)

        // Hover Alpha: its plus appears (SPEC §6.2) with no click.
        let spot = try hoverPlus(on: alpha, side: .right, in: canvas)
        #expect(canvas.addHandles.map(\.nodeID) == [alpha])
        #expect(canvas.selection.isEmpty)

        // Click it: exactly one child of Alpha, open for typing — the
        // same add path the selected-node plus takes.
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: spot, in: canvas))
        #expect(document.model.nodes.count == before + 1)
        let new = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[new]?.parent == alpha)
        #expect(canvas.addHandles.isEmpty, "the plus hides while its new node is edited")
    }

    @Test func aBalancedRootWithChildrenAllRightStillOffersTheLeftPlus() throws {
        let (document, _, canvas) = try makeShownTree(pin: .right)
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let before = document.model.nodes.count

        // The reported case: every child pinned right, yet the layout
        // is balanced — the left plus must show.
        let rootFrame = try #require(canvas.scene?.nodes[rootID]?.frame)
        let center = canvas.camera.screenPoint(for: CGPoint(x: rootFrame.midX, y: rootFrame.midY))
        canvas.mouseMoved(with: try mouse(.mouseMoved, at: center, in: canvas))
        #expect(Set(canvas.addHandles.map(\.side)) == [.left, .right])

        // Clicking the left plus adds one left-pinned child.
        let leftSpot = try hoverPlus(on: rootID, side: .left, in: canvas)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: leftSpot, in: canvas))
        #expect(document.model.nodes.count == before + 1)
        let new = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[new]?.parent == rootID)
        #expect(document.model.nodes[new]?.side == .left)
    }

    /// The reported flow: click "+", type, click away, then click the
    /// previous box's "+" again — hover and selected variants — and
    /// the new box's own "+". Every click adds exactly one child.
    @Test func plusClicksKeepAddingChildrenThroughTheRealFlow() throws {
        let (document, _, canvas) = try makeShownTree(pin: .right)
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let alpha = try #require(document.model.nodes[rootID]?.children.first)

        func clickAway() throws {
            // Well clear of every node.
            let bounds = try #require(canvas.scene?.bounds)
            let spot = canvas.camera.screenPoint(
                for: CGPoint(x: bounds.minX - 200, y: bounds.minY - 200))
            canvas.mouseDown(with: try mouse(.leftMouseDown, at: spot, in: canvas))
            canvas.mouseUp(with: try mouse(.leftMouseUp, at: spot, in: canvas))
            #expect(canvas.editingNodeID == nil, "the click-away commits the session")
        }

        /// Hover the node's plus, click it, type `text` into the new
        /// child, then click away — returning the new child's id.
        @discardableResult
        func clickPlus(on id: String, side: AddHandleSide = .right, text: String) throws -> String {
            let before = document.model.nodes.count
            let spot = try hoverPlus(on: id, side: side, in: canvas)
            canvas.mouseDown(with: try mouse(.leftMouseDown, at: spot, in: canvas))
            #expect(
                document.model.nodes.count == before + 1,
                "one plus click must add exactly one child")
            let new = try #require(canvas.editingNodeID)
            #expect(document.model.nodes[new]?.parent == id)
            canvas.nodeTextEditor.insertText(text)
            try clickAway()
            #expect(document.model.nodes[new]?.title.text == text)
            return new
        }

        let beta = try clickPlus(on: alpha, text: "Beta")
        let gamma = try clickPlus(on: alpha, text: "Gamma")
        _ = try clickPlus(on: beta, text: "Delta")
        #expect(document.model.nodes[alpha]?.children == [beta, gamma])
        #expect(document.model.nodes[beta]?.children.first != nil)

        // Selected variant: the still-selected node's plus.
        canvas.setSelection([alpha])
        let handle = try #require(canvas.addHandles.first { $0.side == .right })
        let before = document.model.nodes.count
        let center = handle.center(camera: canvas.camera)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas))
        #expect(document.model.nodes.count == before + 1)
        #expect(document.model.nodes[try #require(canvas.editingNodeID)]?.parent == alpha)
    }

    /// Return commits and creates the sibling below; the previous box's
    /// plus must still add afterwards, mid-flow.
    @Test func returnKeyEndsTheEditAndThePlusStillAdds() throws {
        let (document, _, canvas) = try makeShownTree(pin: .right)
        defer { document.close() }
        let rootID = try #require(document.model.roots.first)
        let alpha = try #require(document.model.nodes[rootID]?.children.first)
        let before = document.model.nodes.count

        // Selected plus on Alpha: Beta is created and open for typing.
        canvas.setSelection([alpha])
        let handle = try #require(canvas.addHandles.first { $0.side == .right })
        let center = handle.center(camera: canvas.camera)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: center, in: canvas))
        let beta = try #require(canvas.editingNodeID)
        #expect(document.model.nodes.count == before + 1)
        canvas.nodeTextEditor.insertText("Beta")

        // Return through the real first responder (the overlay's text
        // view): commit + sibling below, editing continues on it.
        let returnKey = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let editor = try #require(canvas.window?.firstResponder as? NSTextView)
        editor.keyDown(with: returnKey)
        let sibling = try #require(canvas.editingNodeID)
        #expect(sibling != beta)
        #expect(document.model.nodes[sibling]?.parent == alpha)
        #expect(document.model.nodes.count == before + 2)
        canvas.nodeTextEditor.insertText("Sibling")

        // Now Alpha's plus again, while the sibling's session is still
        // open: the click commits it first, then adds exactly one child.
        let spot = try hoverPlus(on: alpha, side: .right, in: canvas)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: spot, in: canvas))
        #expect(canvas.editingNodeID != sibling, "the sibling's session ended")
        #expect(document.model.nodes.count == before + 3)
        #expect(document.model.nodes[try #require(canvas.editingNodeID)]?.parent == alpha)
    }
}
