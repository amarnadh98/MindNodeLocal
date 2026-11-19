import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// Golden-path scenario 5, end to end (SPEC §3 item 5 — the M4 Quick
/// Entry slice): the global hotkey → Quick Entry → an indented list →
/// Create Map, plus the slice's own F-QEN-2 companion, Append to Inbox.
///
/// Every step drives the REAL app paths: the global ⌃⌥Space hotkey is
/// actually REGISTERED with Carbon (asserted — synthesizing a system
/// event is the only thing a hosted test won't do), the panel opens
/// through the exact closure the Carbon trampoline calls, the outline is
/// typed into the panel's real `NSTextView`, and Create Map runs the
/// button's action against the real `NSDocumentController`. The result
/// is a real untitled document whose first line is the root, the rest
/// descend by indent — ONE grouped `MapCommand`, one undo step.
/// `NSDocumentController`, the Quick Entry coordinator and the hotkey
/// center are process-wide; the suite serializes so its tests can't
/// observe each other's documents, panel or registration.
@Suite(.serialized)
@MainActor
struct GoldenScenarioFiveTests {
    @Test func globalHotkeyQuickEntryIndentedListCreateMap() throws {
        let before = Set(
            (NSDocumentController.shared.documents as? [MapDocument] ?? []).map(\.model.docID))

        // The launch wiring: AppDelegate.start() registered the persisted
        // (default ⌃⌥Space) hotkey with Carbon, and its trigger is the
        // coordinator's toggle.
        QuickEntryCoordinator.shared.start()
        #expect(GlobalHotkeyCenter.shared.activeSpec == HotkeySpec.quickEntryDefault)

        // Press the hotkey (the trampoline's exact target): the floating
        // panel appears with its editor focused.
        QuickEntryCoordinator.shared.togglePanel()
        let panelController = try #require(QuickEntryCoordinator.shared.panelController)
        #expect(panelController.isVisible)
        let editor = panelController.editorView

        // Type the indented outline (⏎ new line, ⇥ indent — typed into
        // the real NSTextView the user types into).
        editor.insertText("Book Launch")
        editor.insertText("\n")
        editor.insertText("\tWrite outline")
        editor.insertText("\n")
        editor.insertText("\tSend to editors")
        editor.insertText("\n")
        editor.insertText("\t\tSchedule review")
        editor.insertText("\n")
        editor.insertText("\tFinal cover")

        // Create Map: the emphasized button's action.
        panelController.createMapAction(nil)

        // The capture succeeded: the panel closed and cleared…
        #expect(!panelController.isVisible)
        #expect(panelController.text.isEmpty)
        // …and a NEW untitled document joined the document controller.
        let documents = (NSDocumentController.shared.documents as? [MapDocument]) ?? []
        let created = try #require(documents.first(where: { !before.contains($0.model.docID) }))
        defer { created.close() }
        let model = created.model
        #expect(created.fileURL == nil)

        // First line = root, the rest descend by indentation (F-QEN-2).
        let rootID = try #require(model.roots.first)
        #expect(model.nodes[rootID]?.title.text == "Book Launch")
        let childrenOfRoot = model.nodes[rootID]?.children ?? []
        #expect(childrenOfRoot.count == 3)
        #expect(model.nodes[childrenOfRoot[0]]?.title.text == "Write outline")
        #expect(model.nodes[childrenOfRoot[1]]?.title.text == "Send to editors")
        #expect(model.nodes[childrenOfRoot[2]]?.title.text == "Final cover")
        let editorsChildren = model.nodes[childrenOfRoot[1]]?.children ?? []
        #expect(editorsChildren.map { model.nodes[$0]?.title.text } == ["Schedule review"])
        // Every inserted node descends from the root — one map, one tree.
        #expect(model.nodes.count == 5)

        // One undo group: a single ⌘Z returns to the pristine empty map
        // (the store registers one explicit group per capture; the test
        // host's by-event wrapper is closed first, like scenario 1).
        created.undoManager?.groupsByEvent = false
        var undoSteps = 0
        while created.undoManager?.canUndo == true {
            created.undoManager?.undo()
            undoSteps += 1
        }
        #expect(undoSteps == 1)
        #expect(created.model.roots.isEmpty)
        #expect(created.model.nodes.isEmpty)

        // And redo rebuilds the whole capture in one step.
        created.undoManager?.redo()
        #expect(created.model.nodes.count == 5)
        #expect(created.model.nodes[created.model.roots.first ?? ""]?.title.text == "Book Launch")
    }

    /// F-QEN-2's second destination: an indented capture appended to the
    /// designated Inbox document — through the real open path, one
    /// grouped command in the inbox's store, one undo step.
    @Test func appendToInboxMapLandsAsChildrenOfItsRoot() throws {
        let inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString).arbor")
        defer {
            try? FileManager.default.removeItem(at: inboxURL)
            QuickEntryInboxStore.shared.clear()
        }

        // The designated inbox: a saved map with a single root.
        var inboxModel = MapModel.emptyDocument()
        let inboxRoot = UUID().uuidString
        inboxModel.roots = [inboxRoot]
        inboxModel.nodes[inboxRoot] = Node(id: inboxRoot, title: NodeTitle(text: "Inbox"))
        try ArborPackage.write(inboxModel, meta: PackageMeta(docID: inboxModel.docID), to: inboxURL)
        QuickEntryInboxStore.shared.setInbox(inboxURL)
        #expect(QuickEntryInboxStore.shared.resolve()?.path == inboxURL.path)

        // Hotkey → panel → an indented list.
        QuickEntryCoordinator.shared.togglePanel()
        let panelController = try #require(QuickEntryCoordinator.shared.panelController)
        panelController.text = "Sudden idea\n\tFlesh it out\n\t\tLater"

        // Append to Inbox: the button's action, no open instance yet.
        panelController.appendInboxAction(nil)

        // The inbox document opened with the capture under its root —
        // one map, one grouped command. (NSDocument normalizes package
        // URLs with a trailing slash; compare standardized.)
        let documents = (NSDocumentController.shared.documents as? [MapDocument]) ?? []
        let inbox = try #require(
            documents.first(where: { $0.fileURL?.standardizedFileURL == inboxURL.standardizedFileURL }))
        defer { inbox.close() }
        #expect(!panelController.isVisible)
        #expect(panelController.text.isEmpty)
        let model = inbox.model
        #expect(model.nodes[inboxRoot]?.title.text == "Inbox")
        let appended = model.nodes[inboxRoot]?.children ?? []
        #expect(appended.count == 1)
        #expect(model.nodes[appended[0]]?.title.text == "Sudden idea")
        let fleshed = model.nodes[appended[0]]?.children ?? []
        #expect(fleshed.map { model.nodes[$0]?.title.text } == ["Flesh it out"])
        #expect(
            model.nodes[fleshed.first ?? ""]?.children.map { model.nodes[$0]?.title.text }
                == ["Later"])

        // One undo step removes the whole capture again.
        inbox.undoManager?.groupsByEvent = false
        var undoSteps = 0
        while inbox.undoManager?.canUndo == true {
            inbox.undoManager?.undo()
            undoSteps += 1
        }
        #expect(undoSteps == 1)
        #expect(inbox.model.nodes[inboxRoot]?.children.isEmpty == true)
        #expect(inbox.model.nodes[inboxRoot]?.title.text == "Inbox")
    }
}
