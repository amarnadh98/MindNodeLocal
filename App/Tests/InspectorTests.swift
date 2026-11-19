import AppKit
import CanvasKit
import Foundation
import MapCore
import MapRender
import Testing

@testable import Arbor

/// Hosted app tests for the inspector slice (F-STY-2/3/4/6, SPEC §4.1):
/// the real document → window → split view → inspector wiring, with every
/// mutation a real `MapStore` command — one undo step each.
@MainActor
struct InspectorTests {
    private func makeShownDocument(
        themeID: String? = nil, appearance: AppearanceMode? = .light
    ) throws -> (document: MapDocument, controller: DocumentWindowController) {
        var model = MapModel.emptyDocument()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        if let themeID {
            model.theme = ThemeSelection(id: themeID)
        }
        if let appearance {
            model.appearance = appearance
        }
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "Root"), created: date, modified: date)
        model.roots = [rootID]
        for id in ["alpha", "beta"] {
            model.nodes[id] = Node(
                id: id, parent: rootID, title: NodeTitle(text: id), created: date, modified: date)
            model.nodes[rootID]?.children.append(id)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-\(UUID().uuidString).arbor")
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

    @Test func inspectorIsHiddenByDefaultAndOptionCommandITogglesIt() throws {
        // Hermetic: the persisted visibility survives test runs, so pin
        // the hidden default first.
        DocumentPreferences.inspectorVisible = false
        let (document, controller) = try makeShownDocument()
        defer { document.close() }

        #expect(controller.inspector.inspectorItem?.isCollapsed == true, "SPEC §4.1: hidden by default")

        // ⌥⌘I is the View menu item's action on this controller.
        controller.toggleInspectorAction(nil)
        #expect(controller.inspector.inspectorItem?.isCollapsed == false)
        #expect(DocumentPreferences.inspectorVisible == true, "visibility persists")

        controller.toggleInspectorAction(nil)
        #expect(controller.inspector.inspectorItem?.isCollapsed == true)
        #expect(DocumentPreferences.inspectorVisible == false)
    }

    @Test func fillChangeThroughTheInspectorIsOneUndoStep() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas
        canvas.setSelection(["alpha"])

        // The exact closure the inspector's fill swatch invokes.
        controller.inspector.model.onStylePatch?(NodeStylePatch(fill: "#E5484D"))

        let styled = try #require(canvas.scene?.nodes["alpha"])
        #expect(PaperTheme.hex(of: try #require(styled.style.fillColor)) == 0xE5484D)

        // One undo step restores the theme's fill.
        let undoManager = document.store.undoManager
        #expect(undoManager.canUndo)
        undoManager.undo()
        let restored = try #require(canvas.scene?.nodes["alpha"])
        let paper = BuiltInThemes.theme(id: "paper")
        let themeFill = paper.resolvedStyle(level: 1, level1Index: 0, variant: .light).fillColor
        #expect(
            PaperTheme.hex(of: try #require(restored.style.fillColor))
                == PaperTheme.hex(of: try #require(themeFill)))
        #expect(!undoManager.canUndo, "the fill change must be exactly one undo step")
    }

    @Test func multiSelectionStyleEditIsOneUndoStep() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas
        canvas.setSelection(["alpha", "beta"])

        controller.inspector.model.onStylePatch?(NodeStylePatch(shape: .hexagon))
        #expect(canvas.scene?.nodes["alpha"]?.style.shape == .hexagon)
        #expect(canvas.scene?.nodes["beta"]?.style.shape == .hexagon)

        let undoManager = document.store.undoManager
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(canvas.scene?.nodes["alpha"]?.style.shape == .roundedRect)
        #expect(canvas.scene?.nodes["beta"]?.style.shape == .roundedRect)
        #expect(!undoManager.canUndo, "a multi-selection edit is ONE step")
    }

    @Test func resetStyleReturnsTheNodeToTheTheme() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas
        canvas.setSelection(["alpha"])
        controller.inspector.model.onStylePatch?(NodeStylePatch(shape: .cloud, fill: "#0090FF"))

        // The per-field "Reset to theme" closure.
        controller.inspector.model.onResetKeys?([.fill, .shape])
        let style = try #require(canvas.scene?.nodes["alpha"]?.style)
        let paper = BuiltInThemes.theme(id: "paper")
        let themeStyle = paper.resolvedStyle(level: 1, level1Index: 0, variant: .light)
        #expect(style.shape == themeStyle.shape)
        #expect(
            PaperTheme.hex(of: try #require(style.fillColor))
                == PaperTheme.hex(of: try #require(themeStyle.fillColor)))
    }

    @Test func applyingAThemeFromTheGridRecolorsTheCanvasInOneUndoStep() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas
        let ocean = BuiltInThemes.theme(id: "ocean")
        let paper = BuiltInThemes.theme(id: "paper")

        controller.inspector.model.onApplyTheme?("ocean")
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: ocean.canvasColor(for: .light)))
        let branch = try #require(canvas.scene?.branches.first { $0.childID == "beta" })
        #expect(
            PaperTheme.hex(of: branch.color)
                == PaperTheme.hex(of: ocean.branchColor(level1Index: 1, variant: .light)))

        let undoManager = document.store.undoManager
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: paper.canvasColor(for: .light)))
        #expect(!undoManager.canUndo, "applying a theme is exactly one undo step")
    }

    @Test func hoverPreviewRecolorsTheCanvasWithoutDirtyingTheDocument() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas
        let editedBefore = document.isDocumentEdited
        let ocean = BuiltInThemes.theme(id: "ocean")

        // The theme tile's onHover → onPreviewTheme path.
        controller.inspector.model.onPreviewTheme?("ocean")
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: ocean.canvasColor(for: .light)),
            "the preview must recolor the canvas")
        #expect(document.store.model.theme?.id != "ocean", "the model is untouched")
        #expect(document.isDocumentEdited == editedBefore, "hover never dirties the document")
        #expect(!document.store.undoManager.canUndo, "hover registers no undo step")

        // Leaving the tile restores the stored theme.
        controller.inspector.model.onPreviewTheme?(nil)
        let paper = BuiltInThemes.theme(id: "paper")
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: paper.canvasColor(for: .light)))
    }

    @Test func rainbowToggleAndRecolorBranchesActThroughTheStore() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }

        // Rainbow off: every branch takes palette color 0 (F-STY-8).
        controller.inspector.model.onRainbowToggle?(false)
        let branches = controller.canvas.scene?.branches ?? []
        let colors = Set(branches.map { PaperTheme.hex(of: $0.color) })
        #expect(colors.count == 1, "with rainbow off every branch shares palette color 0")

        // Recolor Branches: one grouped undo step (two roots → still
        // one command per root; this model has one).
        controller.inspector.model.onRecolorBranches?()
        let undoManager = document.store.undoManager
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(!undoManager.canUndo)
    }

    @Test func appearanceOverrideDrivesTheVariantAndPersists() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas
        let chalkboard = BuiltInThemes.theme(id: "chalkboard")
        let dark = chalkboard.canvasColor(for: .dark)
        let light = chalkboard.canvasColor(for: .light)

        controller.inspector.model.onApplyTheme?("chalkboard")
        controller.inspector.model.onAppearance?(.dark)
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: dark),
            "the per-document override wins over the system look")
        controller.inspector.model.onAppearance?(.light)
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: light))
        #expect(document.store.model.appearance == .light, "persisted in the model (SPEC §8.2)")
    }

    @Test func defaultThemePreferenceAppliesToNewDocuments() throws {
        DocumentPreferences.defaultThemeID = "sakura"
        defer { DocumentPreferences.defaultThemeID = "paper" }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("default-theme-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(
            MapDocument.initialModel(), meta: PackageMeta(docID: "fresh"), to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }
        #expect(document.store.model.theme?.id == "sakura", "F-STY-6: applied at creation")

        // The preference reads back; the untitled in-memory path uses
        // the same initializer.
        let fresh = MapDocument.initialModel()
        #expect(fresh.theme?.id == "sakura")
    }
}
