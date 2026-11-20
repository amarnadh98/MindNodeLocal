import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Hosted app tests for the M4 outline slice (F-OUT): ⌘1/⌘2/⌘3 view
/// modes, outline editing driving the map through the same store (one
/// undo step), the two-way selection sync, disclosure mirroring
/// `node.folded` in both directions, and the ⏎ split through the real
/// key path.
@MainActor
struct OutlineViewTests {
    @Test func commandKeysSwitchBetweenMapOutlineAndSideBySide() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController

        // ⌘2: the outline fills the window and shows the document.
        controller.showOutlineViewAction(nil)
        #expect(controller.window?.contentView === outline.view)
        #expect(controller.activeViewMode == .outline)
        #expect(outline.outlineView.numberOfRows >= 1)

        // ⌘3: both panes live side by side, outline left, map right.
        controller.showSideBySideViewAction(nil)
        #expect(controller.window?.contentView === controller.documentSplitView)
        #expect(controller.documentSplitView.arrangedSubviews.first === outline.view)
        #expect(controller.documentSplitView.arrangedSubviews.last === controller.canvas)

        // ⌘1: the map alone; the same canvas instance, state intact.
        controller.showMapViewAction(nil)
        #expect(controller.window?.contentView === controller.canvas)
        #expect(controller.activeViewMode == .map)
    }

    /// AppKit asks the delegate for `outlineView(_:rowViewForItem:)`. The
    /// custom row view (depth guides) once never appeared, because the
    /// method was spelled `rowViewFor`, which nothing calls.
    @Test func outlineRowsUseTheCustomRowViewWithTheirDepth() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController
        let rootID = try #require(document.model.roots.first)
        let child = Node(id: "outline-child", title: NodeTitle(text: "child"))
        try document.store.perform(.addChild(parent: rootID, index: nil, node: child))

        controller.showOutlineViewAction(nil)
        outline.outlineView.expandItem(rootID)
        let row = outline.outlineView.row(forItem: "outline-child")
        #expect(row >= 0)
        let rowView = try #require(
            outline.outlineView.rowView(atRow: row, makeIfNecessary: true) as? OutlineRowView)
        #expect(rowView.depth == 1)
    }

    @Test func editingARowTitleThroughTheOutlineChangesTheMapNodeInOneUndoStep() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController
        let rootID = try #require(document.model.roots.first)

        controller.showOutlineViewAction(nil)
        outline.selectRows(ids: [rootID])
        outline.beginEditing(rowID: rootID, selectAllText: true)
        #expect(outline.isEditing)
        let editor = try #require(outline.editingTextView)
        editor.insertText("Outline Title", replacementRange: editor.selectedRange())
        // Typing is a draft: the model is untouched until commit.
        #expect(document.model.nodes[rootID]?.title.text.isEmpty == true)

        outline.commitEditingSession()
        #expect(document.model.nodes[rootID]?.title.text == "Outline Title")
        // The map node changed too — the scene is rebuilt from the same
        // store (F-OUT-1: both views live).
        #expect(controller.canvas.scene?.nodes[rootID]?.title.text == "Outline Title")

        // ONE undo step restores the pre-session title.
        document.undoManager?.undo()
        #expect(document.model.nodes[rootID]?.title.text.isEmpty == true)
        #expect(outline.isEditing == false)
    }

    @Test func selectionSyncsBetweenOutlineAndMapBothWays() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController
        let rootID = try #require(document.model.roots.first)
        try document.store.perform(
            .addChild(parent: rootID, index: nil, node: Node(id: "child-a", title: NodeTitle(text: "A"))))
        let childID = try #require(document.model.nodes[rootID]?.children.first)

        controller.showSideBySideViewAction(nil)

        // Outline → map: selecting the row through the outline view's
        // own selection path (the delegate fires, the canvas follows).
        let childRow = outline.outlineView.row(forItem: childID)
        outline.outlineView.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
        #expect(controller.canvas.selection == [childID])

        // Map → outline: a canvas selection change highlights the row.
        controller.canvas.setSelection([rootID])
        let selectedRows = outline.outlineView.selectedRowIndexes
        #expect(selectedRows.count == 1)
        #expect(outline.outlineView.item(atRow: selectedRows.first!) as? String == rootID)
    }

    @Test func disclosureMirrorsNodeFoldedInBothDirections() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController
        let rootID = try #require(document.model.roots.first)
        let branch = Node(id: "branch", title: NodeTitle(text: "Branch"))
        let leaf = Node(id: "leaf", title: NodeTitle(text: "Leaf"))
        try document.store.perform(.addChild(parent: rootID, index: nil, node: branch))
        try document.store.perform(.addChild(parent: "branch", index: nil, node: leaf))

        controller.showOutlineViewAction(nil)
        #expect(outline.outlineView.isItemExpanded("branch"))

        // Collapsing the row performs ONE setFolded — the same command
        // the map's fold performs (one source of truth, F-LAY-14).
        outline.outlineView.collapseItem("branch")
        #expect(document.model.nodes["branch"]?.folded == true)
        document.undoManager?.undo()
        #expect(document.model.nodes["branch"]?.folded == false)
        #expect(outline.outlineView.isItemExpanded("branch"))

        // Store-driven folding (the map's ⌥⌘.) collapses the row here.
        try document.store.perform(.setFolded(id: "branch", folded: true))
        #expect(outline.outlineView.isItemExpanded("branch") == false)
        // The hidden leaf has no row.
        #expect(outline.outlineView.row(forItem: "leaf") == -1)
    }

    @Test func returnKeySplitsTheRowAtTheCaretAsOneUndoStep() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController
        let rootID = try #require(document.model.roots.first)
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "row", title: NodeTitle(text: "Hello Brave"))))

        controller.showOutlineViewAction(nil)
        let row = outline.outlineView.row(forItem: "row")
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        // ⏎ with a row selected (F-OUT-3): a new row below, editing.
        outline.outlineView.keyDown(with: Self.keyEvent("\r"))
        #expect(outline.isEditing)
        let newRowID = try #require(outline.editingRowID)
        #expect(document.model.nodes[newRowID]?.parent == rootID)
        #expect(newRowID != "row")

        // Undoing ONE step removes the new row.
        document.undoManager?.undo()
        #expect(document.model.nodes[newRowID] == nil)
        #expect(outline.isEditing == false)
    }

    @Test func editingReturnSplitsTheTitleTextIntoTwoRows() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController
        let rootID = try #require(document.model.roots.first)
        try document.store.perform(
            .addChild(
                parent: rootID, index: nil,
                node: Node(id: "row", title: NodeTitle(text: "replaced"))))

        controller.showOutlineViewAction(nil)
        outline.beginEditing(rowID: "row", selectAllText: true)
        let editor = try #require(outline.editingTextView)
        editor.insertText("Hello Brave", replacementRange: editor.selectedRange())
        editor.selectedRange = NSRange(location: 5, length: 0)

        // ⏎ inside the editor (F-OUT-3): split at the caret — the head
        // stays, the tail moves to the new row, one grouped command.
        outline.editorSplit()
        #expect(document.model.nodes["row"]?.title.text == "Hello")
        let newRowID = try #require(document.model.nodes[rootID]?.children.last)
        #expect(newRowID != "row")
        #expect(document.model.nodes[newRowID]?.title.text == " Brave")

        // One undo step restores the pre-split state: the title the
        // grouped command replaced ("replaced" — the draft lived only
        // inside the split's own editText), and no new row.
        document.undoManager?.undo()
        #expect(document.model.nodes[newRowID] == nil)
        #expect(document.model.nodes["row"]?.title.text == "replaced")
    }

    @Test func firstLevelRowsFollowTheMapsClockwiseVisualOrder() throws {
        let (document, controller) = try Self.makeShownDocument()
        defer { document.close() }
        let outline = controller.outlineController
        let rootID = try #require(document.model.roots.first)

        // Children in model order: r1, l1, r2, l2 — the outline shows
        // the right side top→bottom, then the left side bottom→top
        // (F-OUT-2's clockwise rule).
        for (id, side) in [("r1", SidePin.right), ("l1", SidePin.left), ("r2", SidePin.right), ("l2", SidePin.left)] {
            var node = Node(id: id, title: NodeTitle(text: id))
            node.side = side
            try document.store.perform(.addChild(parent: rootID, index: nil, node: node))
        }

        controller.showOutlineViewAction(nil)
        let displayed = (0..<outline.outlineView.numberOfRows).compactMap {
            outline.outlineView.item(atRow: $0) as? String
        }
        #expect(displayed == [rootID, "r1", "r2", "l2", "l1"])
    }

    // MARK: helpers

    /// The untitled document with its window shown; the placeholder
    /// root's editing session is left closed.
    private static func makeShownDocument() throws -> (MapDocument, DocumentWindowController) {
        let document =
            try #require(
                try NSDocumentController.shared.makeUntitledDocument(
                    ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller =
            try #require(document.windowControllers.first as? DocumentWindowController)
        controller.viewStateStore = ViewStateStore(
            baseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("outline-tests-\(UUID().uuidString)"))
        controller.showWindow(nil)
        controller.canvas.commitEditing()
        document.undoManager?.groupsByEvent = false
        return (document, controller)
    }

    private static func keyEvent(_ key: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
    }
}
