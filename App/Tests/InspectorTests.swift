import AppKit
import CanvasKit
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import Arbor

/// Hosted app tests for the inspector slice (F-STY-2/3/4/6/8,
/// F-LAY-12/14, SPEC §4.1/§6.3): the real document → window → split
/// view → inspector wiring, with every mutation a real `MapStore`
/// command — one undo step each.
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

        #expect(!controller.inspector.isInstalled, "SPEC §4.1: hidden by default")
        #expect(controller.window?.contentView === controller.canvas, "no pane: the plain canvas")

        // ⌥⌘I is the View menu item's action on this controller.
        controller.toggleInspectorAction(nil)
        #expect(controller.inspector.isVisible)
        #expect(DocumentPreferences.inspectorVisible == true, "visibility persists")
        // The main view survives the wrap: the canvas instance is the
        // split's main item's view (the scene, camera and editing state
        // never rebuild).
        #expect(controller.inspector.mainController?.view === controller.canvas)

        // The view modes still swap the main item in place.
        controller.applyViewMode(.outline)
        #expect(controller.inspector.mainController?.view === controller.outlineController.view)
        controller.applyViewMode(.map)
        #expect(controller.inspector.mainController?.view === controller.canvas)

        controller.toggleInspectorAction(nil)
        #expect(!controller.inspector.isInstalled)
        #expect(controller.window?.contentView === controller.canvas, "unwrapped: the plain canvas")
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

    @Test func shapeMenuActionAppliesTheTaggedShapeToTheSelection() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas
        canvas.setSelection(["alpha", "beta"])

        // The Format ▸ Shape menu item (tag = allCases index).
        let item = NSMenuItem(title: "Pill", action: nil, keyEquivalent: "")
        item.tag = NodeShape.allCases.firstIndex(of: .pill) ?? 1
        controller.applyShapeAction(item)
        #expect(canvas.scene?.nodes["alpha"]?.style.shape == .pill)
        #expect(canvas.scene?.nodes["beta"]?.style.shape == .pill)

        document.store.undoManager.undo()
        #expect(canvas.scene?.nodes["alpha"]?.style.shape == .roundedRect)
        #expect(!document.store.undoManager.canUndo)
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

        // Recolor Branches: one undo step per root (this model has one).
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

    @Test func canvasColorOverrideStoresWithTheThemePatch() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }

        controller.inspector.model.onCanvasColor?("#102A43")
        #expect(PaperTheme.hex(of: try #require(controller.canvas.scene?.canvasColor)) == 0x102A43)
        #expect(document.store.model.theme?.overrides?.canvasColor == "#102A43")
        #expect(
            document.store.model.theme?.overrides?.rainbowBranches == nil,
            "the canvas color keeps other stored overrides intact")

        // Reset returns the theme's own color.
        controller.inspector.model.onCanvasColor?(nil)
        let paper = BuiltInThemes.theme(id: "paper")
        #expect(
            PaperTheme.hex(of: try #require(controller.canvas.scene?.canvasColor))
                == PaperTheme.hex(of: paper.canvasColor(for: .light)))
    }

    @Test func structureChoiceRelaysTheRootTreeInOneUndoStep() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        let canvas = controller.canvas

        // The Layout pane's structure picker, on the selection's root.
        canvas.setSelection(["alpha"])
        #expect(controller.inspector.model.structureRootID == "root")

        controller.inspector.model.onStructure?("logic.right")
        #expect(document.store.model.nodes["root"]?.structure == "logic.right")
        // F-LAY-4's compact rhythm: the root's children sit one LEVEL
        // gap past the root (the mind map's root gap is wider).
        let root = try #require(canvas.scene?.nodes["root"])
        let firstChild = try #require(canvas.scene?.nodes["alpha"])
        let levelGap = LayoutSpacing.default.levelGap
        #expect(abs(firstChild.frame.minX - (root.frame.maxX + levelGap)) < 0.01)

        document.store.undoManager.undo()
        #expect(document.store.model.nodes["root"]?.structure == nil)
        #expect(!document.store.undoManager.canUndo)
    }

    @Test func spacingPresetRelaysTheDocumentAtTheChosenRhythm() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        defer {
            DocumentPreferences.spacingPreset = 1
            DocumentPreferences.customSiblingGap = nil
            DocumentPreferences.customLevelGap = nil
        }
        let canvas = controller.canvas

        controller.inspector.model.onSpacingPreset?(0)
        #expect(DocumentPreferences.spacingPreset == 0)
        let narrow = try #require(canvas.scene?.nodes["beta"])
        let root = try #require(canvas.scene?.nodes["root"])
        #expect(
            abs(narrow.frame.minX - (root.frame.maxX + LayoutSpacing.narrow.rootGap)) < 0.01,
            "the scene relayouts at the narrow rhythm")
    }

    @Test func customGapsOverrideThePresetValues() throws {
        let (document, controller) = try makeShownDocument()
        defer { document.close() }
        defer {
            DocumentPreferences.spacingPreset = 1
            DocumentPreferences.customSiblingGap = nil
            DocumentPreferences.customLevelGap = nil
        }
        let canvas = controller.canvas

        controller.inspector.model.onCustomGaps?(nil, 90)
        #expect(DocumentPreferences.customLevelGap == 90)
        let root = try #require(canvas.scene?.nodes["root"])
        let child = try #require(canvas.scene?.nodes["beta"])
        #expect(abs(child.frame.minX - (root.frame.maxX + 90)) < 0.01)
    }

    @Test func foldedCountPillClickUnfoldsInOneUndoStep() throws {
        var model = MapModel.emptyDocument()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "Root"), created: date, modified: date)
        model.roots = [rootID]
        model.nodes["alpha"] = Node(
            id: "alpha", parent: rootID, title: NodeTitle(text: "alpha"),
            created: date, modified: date)
        model.nodes[rootID]?.children = ["alpha"]
        model.nodes["leaf"] = Node(
            id: "leaf", parent: "alpha", title: NodeTitle(text: "leaf"),
            created: date, modified: date)
        model.nodes["alpha"]?.children = ["leaf"]
        model.nodes["alpha"]?.folded = true

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pill-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)
        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { document.close() }
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)

        // F-LAY-14: the folded node's pill carries the hidden count…
        #expect(controller.canvas.scene?.nodes["alpha"]?.foldedCount == 1)

        // …and the canvas's pill closure unfolds it in ONE undo step.
        controller.unfoldFromPill("alpha")
        #expect(document.store.model.nodes["alpha"]?.folded == false)
        #expect(controller.canvas.scene?.nodes["leaf"] != nil, "the descendant is back")

        document.store.undoManager.undo()
        #expect(document.store.model.nodes["alpha"]?.folded == true)
        #expect(!document.store.undoManager.canUndo)
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

    @Test func toggleInspectorMenuItemCarriesTheCheckmark() throws {
        DocumentPreferences.inspectorVisible = false
        let (document, controller) = try makeShownDocument()
        defer { document.close() }

        let item = NSMenuItem(
            title: "Toggle Inspector",
            action: #selector(DocumentWindowController.toggleInspectorAction(_:)),
            keyEquivalent: "i")
        #expect(controller.validateMenuItem(item) == true)
        #expect(item.state == .off)

        controller.toggleInspectorAction(nil)
        #expect(controller.validateMenuItem(item) == true)
        #expect(item.state == .on)
        controller.toggleInspectorAction(nil)
    }
}
