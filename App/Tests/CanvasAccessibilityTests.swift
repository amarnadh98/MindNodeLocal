import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Hosted app tests for the accessibility slice (M1 7c, SPEC §11.6):
/// the window's canvas exposes one row per document node, labelled
/// with the document name, and VoiceOver's Add Child custom action
/// creates a node through the document's store — one undo step.
@MainActor
struct CanvasAccessibilityTests {
    @Test func canvasExposesRowsForTheDocumentNodes() throws {
        let document = try Self.makeShownDocument()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas
        // Leave the placeholder root's editing session (F-CAN-3).
        canvas.commitEditing()
        let rootID = try #require(document.model.roots.first)

        // The canvas is a labelled container, not an element itself.
        #expect(canvas.isAccessibilityElement() == false)
        #expect(canvas.accessibilityLabel() == document.displayName)

        let rows = try #require(canvas.accessibilityChildren())
        #expect(rows.count == 1)
        let rootRow = try #require(rows.first as? NSAccessibilityElement)
        #expect(rootRow.accessibilityRole() == .row)
        // The seeded root has no text yet: it reads "Empty node".
        #expect(rootRow.accessibilityLabel() == "Empty node")
        #expect(rootRow.accessibilityValue() as? String == "leaf")

        // Selecting through the canvas marks the row selected.
        canvas.setSelection([rootID])
        #expect(rootRow.isAccessibilitySelected() == true)
        #expect(canvas.accessibilitySelectedChildren()?.count == 1)

        document.close()
    }

    @Test func addChildCustomActionAddsOneNodeViaTheStore() throws {
        let document = try Self.makeShownDocument()
        // One long run-loop pass in a test would merge the store's undo
        // groups by event; the app closes one event group per key event.
        document.undoManager?.groupsByEvent = false
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let canvas = controller.canvas
        canvas.commitEditing()
        let rootID = try #require(document.model.roots.first)

        let rows = try #require(canvas.accessibilityChildren())
        let rootRow = try #require(rows.first as? NSAccessibilityElement)

        // Add Child, performed the way VoiceOver performs it (the
        // action's handler), routes through the store: one new child.
        let actions = try #require(rootRow.accessibilityCustomActions())
        let addAction = try #require(actions.first { $0.name == "Add Child" })
        #expect(addAction.handler?() == true)

        let childID = try #require(canvas.editingNodeID)
        #expect(document.model.nodes[childID]?.parent == rootID)
        #expect(document.model.nodes[rootID]?.children == [childID])

        // The scene rebuilt: the child's row is exposed, the root's
        // value updated (rows are rebuilt with the scene), and the
        // child's row is the selected one.
        let updatedRows = try #require(canvas.accessibilityChildren())
        #expect(updatedRows.count == 2)
        let values = updatedRows.compactMap {
            ($0 as? NSAccessibilityElement)?.accessibilityValue() as? String
        }
        #expect(values.contains("1 child, expanded"))
        #expect(values.contains("leaf"))
        let selectedRows = updatedRows.compactMap { $0 as? NSAccessibilityElement }
            .filter { $0.isAccessibilitySelected() }
        #expect(selectedRows.count == 1)

        // The empty commit drops the fresh child — one deterministic
        // delete step (ADR-0034), never an undo: undoing first
        // RESTORES the child, a second undo removes the creation.
        canvas.commitEditing()
        #expect(document.model.nodes[childID] == nil)
        document.undoManager?.undo()
        #expect(document.model.nodes[childID] != nil)
        document.undoManager?.undo()
        #expect(document.model.nodes[childID] == nil)
        #expect(document.model.nodes[rootID]?.children.isEmpty == true)

        document.close()
    }

    // MARK: helpers

    /// An untitled document with its window shown (which also seeds and
    /// begins editing the F-CAN-3 placeholder root).
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
