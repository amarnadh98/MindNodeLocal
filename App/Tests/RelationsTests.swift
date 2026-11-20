import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Hosted app tests for M3 slice b (F-REL-1/2/3 + F-REL-5's Copy Node
/// Link): every path goes through the real window controller and the
/// document's `MapStore` — one undo step per action — and the overlays
/// ride the ordinary scene rebuild.
@MainActor
struct RelationsTests {
    @Test func commandLThenClickCreatesAConnectionAsOneUndoStep() throws {
        let (document, controller, canvas) = try makeShownTree()
        document.undoManager?.groupsByEvent = false
        let ids = treeChildIDs(document)
        let first = ids[0]
        let second = ids[1]

        // ⌘L on the single selection enters connect mode; the click on
        // the other node performs ONE addConnection.
        canvas.setSelection([first])
        controller.addConnectionAction(nil)
        let frame = try #require(canvas.scene?.nodes[second]?.frame)
        canvas.completeConnectionMode(
            at: canvas.camera.screenPoint(
                for: CGPoint(x: frame.midX, y: frame.midY)))

        #expect(document.model.connections?.count == 1)
        let connection = try #require(document.model.connections?.first)
        #expect(Set([connection.from, connection.to]) == Set([first, second]))
        // The new connection is selected (⌫ and the jumps work on it).
        #expect(canvas.selectedConnectionIDs == [connection.id])

        // One undo step removes it again.
        document.undoManager?.undo()
        #expect(document.model.connections == nil)
        document.close()
    }

    @Test func deleteKeyDeletesASelectedConnection() throws {
        let (document, controller, canvas) = try makeShownTree()
        document.undoManager?.groupsByEvent = false
        let ids = treeChildIDs(document)
        let first = ids[0]
        let second = ids[1]

        // Connect, then ⌫ on the selected connection deletes it (the
        // Delete action consults the connection selection first).
        try document.store.perform(
            .addConnection(Connection(id: "conn", from: first, to: second)))
        canvas.setConnectionSelection(["conn"])
        controller.deleteSubtreeAction(nil)
        #expect(document.model.connections == nil)

        // One undo step restores it.
        document.undoManager?.undo()
        #expect(document.model.connections?.first?.id == "conn")
        document.close()
    }

    @Test func boundaryFollowsARelayout() throws {
        let (document, controller, canvas) = try makeShownTree()
        document.undoManager?.groupsByEvent = false
        let ids = treeChildIDs(document)

        // ⌥⌘G on two siblings: one boundary, drawn around their frames
        // plus padding.
        canvas.setSelection([ids[0], ids[1]])
        controller.addBoundaryAction(nil)
        #expect(document.model.boundaries?.count == 1)
        let boundary = try #require(document.model.boundaries?.first)
        #expect(boundary.nodes.sorted() == [ids[0], ids[1]].sorted())

        let sceneBoundaryBefore = try #require(canvas.scene?.boundaries.first)
        #expect(sceneBoundaryBefore.bounds.minX < (canvas.scene?.nodes[ids[0]]?.frame.minX ?? 0))

        // A relayout (a child grows) moves the frames; the pure
        // rebuild follows — the boundary still wraps the same nodes.
        try document.store.perform(
            .addChild(
                parent: ids[0], index: nil,
                node: Node(id: "growing", title: NodeTitle(text: "A long growing child"))))
        let sceneBoundaryAfter = try #require(canvas.scene?.boundaries.first)
        // The member subtree grew to the right; the outline follows.
        #expect(sceneBoundaryAfter.bounds.width > sceneBoundaryBefore.bounds.width)
        #expect(
            sceneBoundaryAfter.bounds.contains(
                try #require(canvas.scene?.nodes["growing"]?.frame)))

        // One undo step per action, in order: the add first, then the
        // boundary.
        document.undoManager?.undo()
        #expect(document.model.nodes["growing"] == nil)
        document.undoManager?.undo()
        #expect(document.model.boundaries == nil)
        document.close()
    }

    @Test func summaryCreatesARealNodeBeyondTheBrace() throws {
        let (document, controller, canvas) = try makeShownTree()
        document.undoManager?.groupsByEvent = false
        let ids = treeChildIDs(document)
        let parent = try #require(document.model.roots.first)

        // ⇧⌘] on consecutive siblings: one summary record + one real
        // summary node, opened for editing.
        canvas.setSelection([ids[0], ids[2]])
        controller.addSummaryAction(nil)
        #expect(document.model.summaries?.count == 1)
        let summary = try #require(document.model.summaries?.first)
        // The span covers the intermediate sibling so it stays a run.
        #expect(summary.range == [ids[0], ids[1], ids[2]])
        #expect(summary.parent == parent)
        #expect(document.model.nodes[summary.node]?.parent == parent)
        #expect(canvas.editingNodeID == summary.node)

        // The scene draws the brace and places the node beyond it.
        let sceneSummary = try #require(canvas.scene?.summaries.first)
        let nodeFrame = try #require(canvas.scene?.nodes[summary.node]?.frame)
        #expect(nodeFrame.minX > sceneSummary.brace.boundingBoxOfPath.maxX)

        // Typing the summary commits as the summary node's title.
        canvas.nodeTextEditor.insertText("The point of it all")
        canvas.commitEditing()
        #expect(document.model.nodes[summary.node]?.title.text == "The point of it all")

        // One undo step per action, in order: the title edit first,
        // then the grouped create (record AND node together).
        document.undoManager?.undo()
        #expect(document.model.nodes[summary.node]?.title.text.isEmpty == true)
        #expect(document.model.summaries?.count == 1)
        document.undoManager?.undo()
        #expect(document.model.summaries == nil)
        #expect(document.model.nodes[summary.node] == nil)
        document.close()
    }

    @Test func copyNodeLinkWritesTheArborURL() throws {
        let (document, controller, canvas) = try makeShownTree()
        let rootID = try #require(document.model.roots.first)
        let pasteboard = NSPasteboard(name: .init("RelationsTestsCopyLink"))
        controller.clipboard = pasteboard

        // ⌃⌘C on the single selection writes the cross-map link
        // (SPEC §8.2: x-arbor://open?doc=<docID>&node=<nodeID>).
        canvas.setSelection([rootID])
        controller.copyNodeLinkAction(nil)
        let written = try #require(pasteboard.string(forType: .string))
        #expect(written == "x-arbor://open?doc=\(document.model.docID)&node=\(rootID)")
        document.close()
    }

    // MARK: helpers

    /// A shown document with a root and three children, its placeholder
    /// editing session closed. The tree is pinned to a right-facing
    /// layout so sibling ranges sit on one side (the balanced map
    /// splits them across the root).
    private func makeShownTree() throws -> (MapDocument, DocumentWindowController, CanvasView) {
        let document = try Self.makeShownDocument()
        document.undoManager?.groupsByEvent = false
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas
        let rootID = try #require(document.model.roots.first)
        canvas.commitEditing()

        for title in ["Alpha", "Beta", "Gamma"] {
            let node = Node(id: UUID().uuidString, title: NodeTitle(text: title))
            try document.store.perform(.addChild(parent: rootID, index: nil, node: node))
        }
        // Pin the structure (test setup, not an undoable action): the
        // undo stacks are cleared wholesale, so the actions below own
        // the stack from scratch.
        var model = document.model
        model.nodes[rootID]?.structure = "mindmap.right"
        document.store.replaceModel(model)
        return (document, controller, canvas)
    }

    private func treeChildIDs(_ document: MapDocument) -> [String] {
        guard let rootID = document.model.roots.first,
            let children = document.model.nodes[rootID]?.children
        else { return [] }
        return children
    }

    private static func makeShownDocument() throws -> MapDocument {
        let document = try #require(
            try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
                as? MapDocument)
        document.makeWindowControllers()
        for case let controller as DocumentWindowController in document.windowControllers {
            controller.showWindow(nil)
        }
        return document
    }
}
