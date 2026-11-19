import AppKit
import CanvasKit
import Foundation
import MapCore
import Testing

@testable import Arbor

/// M2 slice 2, hosted: the document toolbar (§4.1/§7.1) has the expected
/// items and validates by selection, and ⌥⌘M toggles the minimap
/// (F-CAN-6) with the preference persisted in UserDefaults.
@MainActor
struct MinimapToolbarTests {
    private func makeShownDocument() throws -> (MapDocument, DocumentWindowController) {
        var model = MapModel.emptyDocument()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "Chrome Root"), created: date, modified: date)
        model.roots = [rootID]
        let childID = "only-child"
        model.nodes[childID] = Node(
            id: childID, parent: rootID, title: NodeTitle(text: "child"),
            created: date, modified: date)
        model.nodes[rootID]?.children.append(childID)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        return (document, controller)
    }

    @Test func toolbarHasTheExpectedDefaultItems() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }

        let window = try #require(controller.window)
        let toolbar = try #require(window.toolbar)
        #expect(window.toolbarStyle == .unifiedCompact)
        #expect(toolbar.allowsUserCustomization)
        // The customization autosave persists per user under the
        // toolbar's identifier.
        #expect(toolbar.identifier == DocumentWindowController.toolbarAutosaveName)
        #expect(toolbar.autosavesConfiguration)
        #expect(toolbar.delegate != nil)

        // §4.1 order: editing left, zoom + minimap right of the space.
        let expected = DocumentWindowController.defaultToolbarItemOrder
        #expect(controller.toolbarDefaultItemIdentifiers(toolbar) == expected)
        #expect(
            controller.toolbarAllowedItemIdentifiers(toolbar)
                == [.flexibleSpace] + expected.filter { $0 != .flexibleSpace })

        let installed = Set(toolbar.items.map(\.itemIdentifier))
        for identifier in expected {
            #expect(installed.contains(identifier), "missing toolbar item \(identifier.rawValue)")
        }
    }

    @Test func toolbarValidationDisablesEditingItemsWithoutSelection() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }

        func item(_ identifier: NSToolbarItem.Identifier) throws -> NSToolbarItem {
            try #require(controller.toolbarItem(for: identifier))
        }
        let delete = try item(.deleteSelection)
        let addChild = try item(.addChild)
        let addSibling = try item(.addSibling)
        let fold = try item(.foldUnfold)
        let rootID = try #require(document.model.roots.first)

        // Nothing selected: every selection-dependent item disables.
        controller.canvas.setSelection([])
        #expect(!controller.validateToolbarItem(delete))
        #expect(!controller.validateToolbarItem(addChild))
        #expect(!controller.validateToolbarItem(addSibling))
        #expect(!controller.validateToolbarItem(fold))

        // The root selected: add/delete live; fold works on its children.
        controller.canvas.setSelection([rootID])
        #expect(controller.validateToolbarItem(delete))
        #expect(controller.validateToolbarItem(addChild))
        #expect(controller.validateToolbarItem(addSibling))
        #expect(controller.validateToolbarItem(fold))
        #expect(fold.label == "Fold")

        // Folded selection flips the fold item's face.
        try document.store.perform(.setFolded(id: rootID, folded: true))
        #expect(controller.validateToolbarItem(fold))
        #expect(fold.label == "Unfold")

        // Zoom and minimap never need a selection.
        #expect(controller.validateToolbarItem(try item(.zoomIn)))
        #expect(controller.validateToolbarItem(try item(.zoomToFit)))
        #expect(controller.validateToolbarItem(try item(.minimap)))

        // The menu items validate the same way (NSMenuItemValidation).
        let deleteMenu = NSMenuItem(
            title: "Delete", action: #selector(DocumentWindowController.deleteSubtreeAction(_:)),
            keyEquivalent: "\u{7f}")
        controller.canvas.setSelection([])
        #expect(!controller.validateMenuItem(deleteMenu))
        controller.canvas.setSelection([rootID])
        #expect(controller.validateMenuItem(deleteMenu))
    }

    @Test func optionCommandMTogglesTheMinimap() throws {
        UserDefaults.standard.set(true, forKey: DocumentWindowController.minimapDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: DocumentWindowController.minimapDefaultsKey) }

        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let minimap = try #require(controller.minimap)
        #expect(minimap.superview === controller.canvas)
        #expect(minimap.preferredVisible)

        // The map fits after the initial zoom-to-fit → auto-hidden
        // (F-CAN-6), even though the preference is on.
        #expect(minimap.isHidden)

        // Panned away: the minimap reappears.
        controller.canvas.camera = Camera(origin: CGPoint(x: 100_000, y: 100_000), scale: 1)
        #expect(!minimap.isHidden)

        // ⌥⌘M flips the persisted preference and hides the overlay.
        controller.toggleMinimapAction(nil)
        #expect(
            (UserDefaults.standard.object(forKey: DocumentWindowController.minimapDefaultsKey) as? Bool)
                == false)
        #expect(minimap.isHidden)
        // Panning again must not resurrect a turned-off minimap.
        controller.canvas.camera = Camera(origin: CGPoint(x: 200_000, y: 100_000), scale: 1)
        #expect(minimap.isHidden)

        // Back on: the auto-hide rule (not the preference) hides it
        // while the map fits, shows it otherwise.
        controller.toggleMinimapAction(nil)
        #expect(!minimap.isHidden)
        controller.canvas.zoomToFit()
        #expect(minimap.isHidden)

        // The View ▸ Minimap menu item mirrors the preference with its
        // checkmark state.
        let menuItem = NSMenuItem(
            title: "Minimap", action: #selector(DocumentWindowController.toggleMinimapAction(_:)),
            keyEquivalent: "m")
        menuItem.keyEquivalentModifierMask = [.command, .option]
        #expect(controller.validateMenuItem(menuItem))
        #expect(menuItem.state == .on)
        controller.toggleMinimapAction(nil)
        #expect(controller.validateMenuItem(menuItem))
        #expect(menuItem.state == .off)
    }

    @Test func minimapPanMovesTheCanvasCamera() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let minimap = try #require(controller.minimap)
        let scene = try #require(controller.canvas.scene)

        // Intercept one pan emission (a VoiceOver press: centre the
        // camera on the map) and check the camera it asks for.
        let original = minimap.onCameraChange
        var received: Camera?
        minimap.onCameraChange = { received = $0 }
        #expect(minimap.accessibilityPerformPress())
        minimap.onCameraChange = original

        let camera = try #require(received)
        let screen = camera.screenPoint(for: CGPoint(x: scene.bounds.midX, y: scene.bounds.midY))
        #expect(abs(screen.x - controller.canvas.bounds.midX) < 1e-6)
        #expect(abs(screen.y - controller.canvas.bounds.midY) < 1e-6)
        #expect(abs(camera.scale - controller.canvas.camera.scale) < 1e-9)

        // Replaying the emission through the host wiring lands the map's
        // centre in the middle of the real canvas.
        original?(camera)
        let canvasScreen = controller.canvas.camera.screenPoint(
            for: CGPoint(x: scene.bounds.midX, y: scene.bounds.midY))
        #expect(abs(canvasScreen.x - controller.canvas.bounds.midX) < 1e-6)
        #expect(abs(canvasScreen.y - controller.canvas.bounds.midY) < 1e-6)
    }
}
