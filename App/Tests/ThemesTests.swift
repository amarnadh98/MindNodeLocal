import AppKit
import CanvasKit
import MapCore
import MapRender
import Testing
import UniformTypeIdentifiers

@testable import Arbor

/// F-STY-5/6 (M2 slice): the user-theme catalog, the theme editor's
/// model and controller, the per-document appearance override, and the
/// Settings default theme.
@MainActor
struct ThemesTests {
    // MARK: helpers

    private func makeTempCatalog() -> ThemeCatalog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("themes-\(UUID().uuidString)", isDirectory: true)
        return ThemeCatalog(directory: directory)
    }

    private func makeDocumentController() throws -> (MapDocument, DocumentWindowController) {
        let document = MapDocument()
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        return (document, controller)
    }

    // MARK: ThemeCatalog (F-STY-5's file contract)

    @Test func themeCatalogSaveLoadRoundTrip() throws {
        let catalog = makeTempCatalog()
        var draft = ThemeCatalog.shared.theme(id: "ocean")
        // A user theme carries its OWN id — built-in ids always win
        // resolution (the catalog's documented rule).
        draft.id = "user-ocean-test"
        draft.name = "Test Ocean"
        try catalog.save(draft)

        let reloaded = ThemeCatalog(directory: catalog.directory)
        #expect(reloaded.userThemes.count == 1)
        #expect(reloaded.userThemes.first?.name == "Test Ocean")
        #expect(reloaded.theme(id: draft.id).name == "Test Ocean")

        // The saved bytes ARE the .arbortheme contract: a plain
        // JSONDecoder reads them back (ADR-0009/0024).
        let data = try Data(contentsOf: catalog.fileURL(for: draft))
        let decoded = try JSONDecoder().decode(Theme.self, from: data)
        #expect(decoded == draft)
        // Pretty, sorted, git-friendly.
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\n  \"id\""))
    }

    @Test func themeCatalogResolvesBuiltInsOverUserDuplicates() throws {
        let catalog = makeTempCatalog()
        var draft = catalog.theme(id: "paper")
        draft.name = "My Paper Clone"
        try catalog.save(draft)

        let reloaded = ThemeCatalog(directory: catalog.directory)
        // A user theme with its OWN id lists alongside; the built-in
        // "paper" keeps winning for the built-in id.
        #expect(reloaded.themes.count == BuiltInThemes.all.count + 1)
        #expect(reloaded.theme(id: "paper").name == "Paper")
        #expect(reloaded.theme(id: "ghost-id").id == BuiltInThemes.defaultID)
    }

    @Test func themeCatalogInstallExportDelete() throws {
        let catalog = makeTempCatalog()
        var source = catalog.theme(id: "sakura")
        source.id = "user-sakura"
        source.name = "Imported Sakura"

        // Export to a scratch file, then install it into a second
        // catalog (double-click install's exact path).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("exported-\(UUID().uuidString).arbortheme")
        try catalog.export(source, to: scratch)
        let other = makeTempCatalog()
        let installed = try other.install(from: scratch)
        #expect(installed == source)
        #expect(other.userThemes.contains { $0.id == "user-sakura" })

        // Delete removes the user theme; built-ins refuse.
        try other.deleteUserTheme(id: "user-sakura")
        #expect(other.userThemes.isEmpty)
        try? other.deleteUserTheme(id: "paper")
        #expect(ThemeCatalog(directory: other.directory).userThemes.isEmpty)
        try? FileManager.default.removeItem(at: scratch)
    }

    @Test func themeCatalogDefaultThemeNormalization() throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: ThemeCatalog.defaultThemeKey) as? String
        defer {
            if let original {
                defaults.set(original, forKey: ThemeCatalog.defaultThemeKey)
            } else {
                defaults.removeObject(forKey: ThemeCatalog.defaultThemeKey)
            }
        }

        defaults.set("ocean", forKey: ThemeCatalog.defaultThemeKey)
        #expect(ThemeCatalog.defaultThemeID == "ocean")
        // A deleted user theme's id falls back to Paper (the catalog
        // has no such user theme in this test's environment).
        defaults.set("user-ghost", forKey: ThemeCatalog.defaultThemeKey)
        #expect(ThemeCatalog.defaultThemeID == BuiltInThemes.defaultID)

        // New documents adopt the default (F-STY-6).
        defaults.set("graphite", forKey: ThemeCatalog.defaultThemeKey)
        let document = MapDocument()
        #expect(document.model.theme == ThemeSelection(id: "graphite"))
        document.close()
    }

    // MARK: theme editor (F-STY-5)

    @Test func themeEditorModelEditsBothVariantsAndPreviews() throws {
        let start = ThemeCatalog.shared.theme(id: "paper")
        let model = ThemeEditorModel(start: start)

        // The live preview renders through the shared path.
        #expect(model.preview != nil)

        // Canvas + palette edits on the LIGHT scheme leave dark alone.
        model.setVariant(.light)
        model.setCanvasColor("#101010")
        model.setPaletteColor(at: 0, hex: "#E5484D")
        #expect(model.draft.light.canvasColor == "#101010")
        #expect(model.draft.light.palette.first == "#E5484D")
        #expect(model.draft.dark.canvasColor == start.dark.canvasColor)

        // Palette add/remove bounds.
        let before = model.scheme.palette.count
        model.addPaletteColor()
        #expect(model.scheme.palette.count == before + 1)
        model.removePaletteColor(at: model.scheme.palette.count - 1)
        #expect(model.scheme.palette.count == before)

        // Level, branch, connection, boundary writes go through whole
        // values.
        var level = model.scheme.levels.level2
        level.shape = .pill
        model.setLevel(.level2, level)
        #expect(model.draft.light.levels.level2.shape == .pill)

        model.setRainbowBranches(!model.draft.rainbowBranches)
        #expect(model.draft.rainbowBranches != start.rainbowBranches)

        // A built-in draft reports itself as one.
        #expect(model.isBuiltInDraft)
        model.duplicateAsNewTheme()
        #expect(!model.isBuiltInDraft)
        #expect(model.draft.id.hasPrefix("user-"))
        #expect(model.draft.name.contains("Copy"))
    }

    @Test func themeEditorApplyPerformsOneUndoableSetTheme() throws {
        let (document, _) = try makeDocumentController()
        let catalog = makeTempCatalog()
        let controller = ThemeEditorController(document: document, catalog: catalog)

        // A new document runs the default theme; Paper stays implicit
        // (no stored selection).
        #expect((document.model.theme?.id ?? BuiltInThemes.defaultID) == ThemeCatalog.defaultThemeID)
        let previousThemeID = document.model.theme?.id

        controller.model.setName("My First Theme")
        controller.model.setCanvasColor("#202020")
        controller.applyToDocument()

        // The theme saved into the catalog…
        #expect(catalog.userThemes.contains { $0.name == "My First Theme" })
        // …and the document's selection changed via ONE command.
        let appliedID = document.model.theme?.id
        #expect(appliedID != previousThemeID)
        #expect(document.model.theme?.id == controller.model.draft.id)

        // One undo step restores the previous theme (F-STY-4: one
        // command, one undo entry).
        document.undoManager?.undo()
        #expect(document.model.theme?.id == previousThemeID)
        document.undoManager?.redo()
        #expect(document.model.theme?.id == appliedID)
        document.close()
    }

    // MARK: per-document appearance (F-STY-6)

    @Test func appearanceMenuActionIsOneUndoStepAndRebuildsVariant() throws {
        let (document, controller) = try makeDocumentController()
        controller.showWindow(nil)

        let darkItem = NSMenuItem(title: "Dark", action: nil, keyEquivalent: "")
        darkItem.tag = 2
        controller.setAppearanceAction(darkItem)
        #expect(document.model.appearance == .dark)
        #expect(controller.currentVariant() == .dark)

        // The rebuilt scene carries the dark canvas color.
        let darkCanvas = controller.canvas.scene?.canvasColor
        let paper = ThemeCatalog.shared.theme(id: ThemeCatalog.defaultThemeID)
        #expect(darkCanvas == paper.canvasColor(for: .dark))

        document.undoManager?.undo()
        #expect(document.model.appearance == .auto || document.model.appearance == nil)
        #expect(controller.currentVariant() == controller.canvas.effectiveVariant)

        // Follow System validates as the current state (checkmark).
        let autoItem = NSMenuItem(
            title: "Follow System", action: #selector(DocumentWindowController.setAppearanceAction(_:)),
            keyEquivalent: "")
        autoItem.tag = 0
        #expect(controller.validateThemesMenuItem(autoItem) == true)
        #expect(autoItem.state == .on)
        document.close()
    }

    @Test func appearanceRadioValidationTracksTheModel() throws {
        let (document, controller) = try makeDocumentController()
        let lightItem = NSMenuItem(
            title: "Light", action: #selector(DocumentWindowController.setAppearanceAction(_:)),
            keyEquivalent: "")
        lightItem.tag = 1
        #expect(controller.validateThemesMenuItem(lightItem) == true)
        #expect(lightItem.state == .off)

        try document.store.perform(.setAppearance(mode: .light))
        #expect(controller.validateThemesMenuItem(lightItem) == true)
        #expect(lightItem.state == .on)
        document.close()
    }

    @Test func editThemeValidationRefusesWithoutDocument() throws {
        // The chain's default (validateThemesMenuItem) is for real
        // controllers; here it only needs to hand back nil for foreign
        // items so the toolbar chain stays intact.
        let (_, controller) = try makeDocumentController()
        let foreign = NSMenuItem(title: "Nothing", action: #selector(NSApplication.hide(_:)), keyEquivalent: "")
        #expect(controller.validateThemesMenuItem(foreign) == nil)
    }

    // MARK: .arbortheme UTI plumbing

    @Test func arborthemeUTIAndSavePanelTypeResolve() {
        #expect(UTType(ThemeCatalog.themeUTI) != nil)
        #expect(ThemeCatalog.themeType.identifier == ThemeCatalog.themeUTI)
    }

    @Test func sceneGeometryExplicitThemeOverridesTheModelSelection() throws {
        // The seam the editor's preview rides: a Theme passed by value
        // wins over the model's stored id (SceneGeometry's new param).
        var model = MapModel.emptyDocument()
        let root = Node(id: "root", title: NodeTitle(text: "Theme Seam"))
        model.nodes[root.id] = root
        model.roots = [root.id]
        model.theme = ThemeSelection(id: "paper")

        let chalkboard = ThemeCatalog.shared.theme(id: "chalkboard")
        let scene = SceneGeometry.build(
            model: model, variant: .dark, measurer: SceneRenderer.sharedMeasurer,
            theme: chalkboard)
        #expect(scene.canvasColor == chalkboard.canvasColor(for: .dark))
        let defaultScene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let paper = ThemeCatalog.shared.theme(id: "paper")
        #expect(defaultScene.canvasColor == paper.canvasColor(for: .light))
    }
}
