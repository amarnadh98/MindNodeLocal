import AppKit
import CanvasKit
import Foundation
import MapCore
import MapIO
import MapRender
import Testing

@testable import Arbor

/// Hosted app tests for the Box|Line control (ADR-0037): the real
/// document → window → canvas → contextual bar / inspector wiring.
/// Every mutation is one `MapStore` command (one undo step), persists
/// through save/reopen, multi-selection applies in one step with the
/// mixed state shown, creation inherits the shapes the user chose
/// around the new node, and a brand-new document opens in Studio
/// even when the defaults domain still carries the stale "paper"
/// values.
@MainActor
struct BoxLineControlTests {
    private func makeShownDocument(
        themeID: String = BuiltInThemes.newDocumentDefaultID
    ) throws -> (document: MapDocument, controller: DocumentWindowController, source: URL) {
        var model = MapModel.emptyDocument()
        model.theme = ThemeSelection(id: themeID)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ id: String, parent: String?, text: String) {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: text),
                created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots = [id]
            }
        }
        // root (0) → one (1) → two (2) → three (3), plus siblings.
        add("root", parent: nil, text: "Root")
        add("one", parent: "root", text: "one")
        add("two", parent: "one", text: "two")
        add("three", parent: "two", text: "three")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-line-\(UUID().uuidString).arbor")
        try ArborPackage.write(model, meta: PackageMeta(docID: model.docID), to: url)

        let document = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        controller.showWindow(nil)
        return (document, controller, url)
    }

    // MARK: the control, one undo step, both UI routes

    @Test func contextualBarLineActionIsOneUndoStepAndResolvesTheLine() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas
        canvas.setSelection(["one"])
        document.store.undoManager.removeAllActions()

        // The exact action the bar's segment fires (segment 1 = Line).
        let segment = NSSegmentedControl()
        segment.segmentCount = 2
        segment.trackingMode = .selectAny
        segment.setSelected(true, forSegment: 1)
        controller.contextualBar.shapeSegmentChosen(segment)

        let style = try #require(canvas.scene?.nodes["one"]).style
        #expect(style.shape == .underline)
        #expect(style.fillColor == nil, "a Line never carries a fill")
        #expect(style.borderWidth == 0 && style.underlineWidth == 2.5)
        #expect(style.borderColor != nil, "the line itself, in the branch color")

        let undoManager = document.store.undoManager
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(canvas.scene?.nodes["one"]?.style.shape == .roundedRect)
        #expect(!undoManager.canUndo, "the Line choice is exactly one undo step")
    }

    @Test func inspectorBoxActionOnTheUnderlineLevelGivesTheBoxLook() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas
        canvas.setSelection(["three"])
        document.store.undoManager.removeAllActions()

        // The exact closure the inspector's segmented row invokes.
        controller.inspector.model.onStylePatch?(NodeStylePatch(shape: .roundedRect))

        let style = try #require(canvas.scene?.nodes["three"]).style
        #expect(style.shape == .roundedRect)
        #expect(style.fillColor != nil, "the level-1 donor's solid branch fill")
        #expect(style.cornerRadius == 16)
        #expect(style.paddingWidth == 24 && style.paddingHeight == 14)

        let undoManager = document.store.undoManager
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(canvas.scene?.nodes["three"]?.style.shape == .underline)
        #expect(!undoManager.canUndo)
    }

    @Test func theControlShowsTheCurrentAndMixedState() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas

        // No overrides yet: the theme decides (Studio: one/two are
        // boxes, three is a line).
        canvas.setSelection(["one", "two"])
        #expect(controller.selectionShapeClass() == true)

        canvas.setSelection(["three"])
        #expect(controller.selectionShapeClass() == false)

        // A mixed selection lights no segment.
        canvas.setSelection(["one", "three"])
        #expect(controller.selectionShapeClass() == nil)

        // An override wins over the level style.
        controller.setNodeShapeClass(box: false)
        canvas.setSelection(["one"])
        #expect(controller.selectionShapeClass() == false)
    }

    @Test func multiSelectionBoxActionIsOneUndoStep() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas
        canvas.setSelection(["two", "three"])
        document.store.undoManager.removeAllActions()

        controller.setNodeShapeClass(box: true)
        #expect(document.model.nodes["two"]?.style?.shape == .roundedRect)
        #expect(document.model.nodes["three"]?.style?.shape == .roundedRect)

        let undoManager = document.store.undoManager
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(document.model.nodes["two"]?.style == nil)
        #expect(document.model.nodes["three"]?.style == nil)
        #expect(!undoManager.canUndo, "a multi-selection Box|Line edit is ONE step")
    }

    // MARK: persistence

    @Test func shapeChoicePersistsThroughSaveAndReopen() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas

        canvas.setSelection(["one", "three"])
        controller.setNodeShapeClass(box: false)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-line-save-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.writeSafely(to: url, ofType: AppIdentity.documentUTI, for: .saveAsOperation)
        document.close()

        let reopened = try #require(
            try NSDocumentController.shared.makeDocument(
                withContentsOf: url, ofType: AppIdentity.documentUTI) as? MapDocument)
        defer { reopened.close() }
        #expect(reopened.model.nodes["one"]?.style?.shape == .underline)
        #expect(reopened.model.nodes["three"]?.style?.shape == .underline)
    }

    // MARK: creation defaults (ADR-0037)

    @Test func newSiblingInheritsTheAnchorShapeOverride() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas

        // The user turned "one" into a line; a sibling created next to
        // it (⏎ committing an edit) must be a line too.
        canvas.setSelection(["one"])
        controller.setNodeShapeClass(box: false)

        controller.handleEditingCommit(
            id: "one", title: NodeTitle(text: "one"), next: .siblingBelow)

        let siblingIDs = document.model.nodes["root"]?.children ?? []
        let newSibling = try #require(siblingIDs.last)
        #expect(document.model.nodes[newSibling]?.style?.shape == .underline)
    }

    @Test func newChildWithUnstyledSiblingsFollowsTheTheme() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas

        // "two" has one child ("three"), but no explicit shape anywhere:
        // the theme's level style decides — nothing is stored.
        canvas.setSelection(["two"])
        controller.addChildAction(nil)

        let childIDs = document.model.nodes["two"]?.children ?? []
        #expect(childIDs.count == 2)
        #expect(document.model.nodes[try #require(childIDs.last)]?.style == nil)
    }

    @Test func newChildCopiesTheLastSiblingWithAShape() throws {
        let (document, controller, source) = try makeShownDocument()
        defer {
            document.close()
            try? FileManager.default.removeItem(at: source)
        }
        let canvas = controller.canvas

        // The user turns "two"'s child "three" into a box; the NEXT
        // child (the Node Well's "+", ⇥) copies it — boxes stay boxes.
        canvas.setSelection(["three"])
        controller.setNodeShapeClass(box: true)

        canvas.setSelection(["two"])
        controller.addChildAction(nil)

        let childIDs = document.model.nodes["two"]?.children ?? []
        #expect(childIDs.count == 2)
        #expect(document.model.nodes[try #require(childIDs.last)]?.style?.shape == .roundedRect)
    }

    // MARK: the theme-default chain (ADR-0031 + the 0034 follow-up)

    @Test func brandNewDocumentUsesStudioEvenWithStalePaperDefaults() throws {
        let defaults = UserDefaults.standard
        // Reset & restore everything this test touches.
        let originalDefault = defaults.object(forKey: ThemeCatalog.defaultThemeKey)
        let originalLegacy = defaults.object(forKey: ThemeCatalog.legacyDefaultThemeKey)
        let originalClearFlag = defaults.object(forKey: ThemeCatalog.stalePaperClearKey)
        defer {
            for (key, value) in [
                (ThemeCatalog.defaultThemeKey, originalDefault),
                (ThemeCatalog.legacyDefaultThemeKey, originalLegacy),
                (ThemeCatalog.stalePaperClearKey, originalClearFlag),
            ] {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        // The observed stale state: both keys hold "paper".
        defaults.set("paper", forKey: ThemeCatalog.defaultThemeKey)
        defaults.set("paper", forKey: ThemeCatalog.legacyDefaultThemeKey)
        defaults.removeObject(forKey: ThemeCatalog.stalePaperClearKey)

        // Before the fix's migration runs, this reproduces the bug:
        // every new map opens in Paper.
        #expect(ThemeCatalog.defaultThemeID == "paper")

        // The launch task's migration: both stale values clear once.
        ThemeCatalog.clearStalePaperDefault()
        #expect(ThemeCatalog.defaultThemeID == BuiltInThemes.newDocumentDefaultID)
        #expect(defaults.string(forKey: ThemeCatalog.legacyDefaultThemeKey) == nil)

        // A brand-new document (the untitled/new-map/template/quick-
        // entry route) starts in Studio; a later deliberate pick
        // sticks because the clear never re-runs.
        let document = MapDocument()
        #expect(document.model.theme == ThemeSelection(id: BuiltInThemes.newDocumentDefaultID))
        document.close()

        defaults.set("paper", forKey: ThemeCatalog.defaultThemeKey)
        #expect(ThemeCatalog.defaultThemeID == "paper", "a deliberate pick sticks")

        // The foreign-import route keeps the default too (a theme-less
        // import is a NEW map, not a Paper one).
        defaults.removeObject(forKey: ThemeCatalog.defaultThemeKey)
    }
}
