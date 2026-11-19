import AppKit
import CanvasKit
import Foundation
import MapCore
import MapIO
import Testing

@testable import Arbor

/// Hosted clipboard tests (F-EDT-9, M1 slice 7a): copy writes ALL four
/// flavours, paste is one undo step with fresh ids, cut+undo restores,
/// ⇧⌥⌘V keeps style, and an empty selection pastes as roots. The
/// controller exchanges a private `NSPasteboard(name:)`, never the
/// user's clipboard. The document's model is read fresh at each
/// assertion: the store replaces the whole `MapModel` value on every
/// command, so an earlier snapshot would show stale data.
@MainActor
struct ClipboardTests {
    /// root ─ a (with child a1) and b (leaf, styled red).
    private static func clipboardModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "clipboard")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for (id, parent) in [("root", nil as String?), ("a", "root"), ("a1", "a"), ("b", "root")] {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: "node \(id)"),
                created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        model.nodes["b"]?.style = NodeStylePatch(fill: "#ff0000")
        return model
    }

    @Test func copyPasteRoundTripIsOneUndoStepWithFreshIds() throws {
        let (document, controller) = try makeShownClipboardDocument()
        document.undoManager?.groupsByEvent = false
        let canvas = controller.canvas

        canvas.setSelection(["a"])
        controller.copy(nil)
        try assertAllFlavoursOnClipboard(controller.clipboard, copiedTitle: "node a")

        let childrenBefore = try #require(document.model.nodes["a"]?.children.count)
        controller.paste(nil)

        // Pasted under the selected node as its LAST children, with the
        // copied subtree's shape intact but fresh ids and timestamps.
        let pastedID = try #require(document.model.nodes["a"]?.children.last)
        #expect(document.model.nodes["a"]?.children.count == childrenBefore + 1)
        #expect(pastedID != "a")
        #expect(pastedID != "a1")
        let pasted = try #require(document.model.nodes[pastedID])
        #expect(pasted.parent == "a")
        #expect(pasted.title.text == "node a")
        #expect(Date().timeIntervalSince(pasted.created) < 60)
        let pastedChild = try #require(pasted.children.first, "copied grandchild must survive")
        #expect(document.model.nodes[pastedChild]?.title.text == "node a1")
        #expect(document.model.nodes[pastedChild]?.parent == pastedID)
        // The pasted top-level nodes become the selection.
        #expect(canvas.selection == [pastedID])

        // ONE undo step removes the whole paste; redo reinserts it.
        document.undoManager?.undo()
        #expect(document.model.nodes[pastedID] == nil)
        #expect(document.model.nodes[pastedChild] == nil)
        #expect(document.model.nodes["a"]?.children.count == childrenBefore)
        document.undoManager?.redo()
        #expect(document.model.nodes[pastedID] != nil)

        document.close()
    }

    @Test func cutCopiesAndDeletesInOneUndoStep() throws {
        let (document, controller) = try makeShownClipboardDocument()
        document.undoManager?.groupsByEvent = false
        let canvas = controller.canvas

        canvas.setSelection(["b"])
        controller.cut(nil)
        try assertAllFlavoursOnClipboard(controller.clipboard, copiedTitle: "node b")
        #expect(document.model.nodes["b"] == nil)
        // The delete lands on the cut node's nearest surviving sibling.
        #expect(canvas.selection == ["a"])

        // One undo step restores the cut subtree exactly.
        document.undoManager?.undo()
        let restored = try #require(document.model.nodes["b"])
        #expect(restored.title.text == "node b")
        #expect(restored.parent == "root")
        #expect(document.model.nodes["root"]?.children.last == "b")

        document.close()
    }

    @Test func plainPasteAdoptsStyleButPasteWithStyleKeepsIt() throws {
        let (document, controller) = try makeShownClipboardDocument()
        document.undoManager?.groupsByEvent = false
        let canvas = controller.canvas

        canvas.setSelection(["b"])
        controller.copy(nil)

        // Plain ⌘V adopts the target's theme: the override drops.
        controller.paste(nil)
        let plainID = try #require(document.model.nodes["b"]?.children.last)
        #expect(plainID != "b")
        #expect(document.model.nodes[plainID]?.style == nil)

        // ⇧⌥⌘V keeps the source style.
        canvas.setSelection(["b"])
        let styledPasteItem = NSMenuItem(
            title: "Paste with Style", action: nil, keyEquivalent: "v")
        styledPasteItem.keyEquivalentModifierMask = [.command, .option, .shift]
        controller.paste(styledPasteItem)
        let styledID = try #require(document.model.nodes["b"]?.children.last)
        #expect(styledID != plainID)
        #expect(document.model.nodes[styledID]?.style?.fill == "#ff0000")

        document.close()
    }

    @Test func emptySelectionPastesAsNewRoots() throws {
        let (document, controller) = try makeShownClipboardDocument()
        document.undoManager?.groupsByEvent = false
        let canvas = controller.canvas

        canvas.setSelection(["a"])
        controller.copy(nil)
        canvas.setSelection([])
        let rootsBefore = document.model.roots.count
        controller.paste(nil)

        #expect(document.model.roots.count == rootsBefore + 1)
        let pastedRoot = try #require(document.model.roots.last)
        #expect(document.model.nodes[pastedRoot]?.parent == nil)
        #expect(document.model.nodes[pastedRoot]?.title.text == "node a")
        #expect(canvas.selection == [pastedRoot])

        document.close()
    }

    @Test func pastedTextFromAnotherAppBuildsAHierarchy() throws {
        let (document, controller) = try makeShownClipboardDocument()
        document.undoManager?.groupsByEvent = false
        let canvas = controller.canvas

        // Markdown on the pasteboard — no internal payload — pastes as a
        // hierarchy under the selection (F-EDT-9's interop path).
        let item = NSPasteboardItem()
        item.setString("- Plan\n    - First\n    - Second", forType: .string)
        controller.clipboard.clearContents()
        controller.clipboard.writeObjects([item])

        canvas.setSelection(["root"])
        controller.paste(nil)

        let pastedRoot = try #require(document.model.nodes["root"]?.children.last)
        #expect(document.model.nodes[pastedRoot]?.title.text == "Plan")
        #expect(
            document.model.nodes[pastedRoot]?.children.map { document.model.nodes[$0]?.title.text ?? "" }
                == ["First", "Second"])

        document.close()
    }

    // MARK: helpers

    private func makeShownClipboardDocument() throws
        -> (MapDocument, DocumentWindowController)
    {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(
            Self.clipboardModel(), meta: PackageMeta(docID: "clipboard"), to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(
            document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        controller.clipboard = NSPasteboard(name: NSPasteboard.Name("arbor-tests-\(UUID().uuidString)"))
        return (document, controller)
    }

    private func assertAllFlavoursOnClipboard(_ pasteboard: NSPasteboard, copiedTitle: String) throws {
        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.data(forType: NSPasteboard.PasteboardType(PastePayload.uniformTypeIdentifier)) != nil)
        #expect(item.string(forType: .string)?.contains(copiedTitle) == true)
        #expect(
            item.string(forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))?
                .contains("- \(copiedTitle)") == true)
        #expect(
            item.string(forType: NSPasteboard.PasteboardType("org.opml.opml"))?.contains("<opml") == true)
    }
}
