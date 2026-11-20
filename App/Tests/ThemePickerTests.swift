import AppKit
import CanvasKit
import Foundation
import MapCore
import MapRender
import Testing

@testable import Arbor

/// F-STY-4's discoverability slice (user feedback: "there is no theme
/// selection in the Arbor app"): the Format ▸ Theme submenu and the
/// toolbar's Theme pull-down list every catalog theme with the current
/// one checked, apply as ONE `setTheme` undo step, hover-preview
/// view-only, and disable honestly with no document window.
@MainActor
struct ThemePickerTests {
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
            id: rootID, title: NodeTitle(text: "Theme Root"), created: date, modified: date)
        model.roots = [rootID]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("themepicker-\(UUID().uuidString).arbor")
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

    /// The Format ▸ Theme submenu of a freshly built main menu.
    private func themeSubmenu(of menu: NSMenu) throws -> NSMenu {
        let format = try #require(menu.items.first { $0.title == "Format" }?.submenu)
        return try #require(format.items.first { $0.title == "Theme" }?.submenu)
    }

    // MARK: Format ▸ Theme (F-STY-4's menu door)

    @Test func formatThemeMenuListsEveryThemeWithTheCurrentOneChecked() throws {
        let (document, controller) = try makeShownDocument(themeID: "paper")
        defer { document.close() }

        // A freshly built menu already lists every theme (the walkers
        // read it before it is ever opened); opening it re-populates
        // against the front document — same list, fresh state.
        let built = try themeSubmenu(of: AppDelegate().buildMenu())
        ThemeMenuController.shared.populate(built, frontController: controller)

        // One item per theme: the 13 built-ins plus user themes, in
        // catalog order, the new-map default marked in its title.
        let themes = ThemeCatalog.shared.themes
        #expect(themes.count == BuiltInThemes.all.count + ThemeCatalog.shared.userThemes.count)
        let items = built.items.filter { $0.representedObject is String }
        #expect(items.compactMap { $0.representedObject as? String } == themes.map(\.id))
        #expect(
            items.map(\.title)
                == themes.map { $0.id == ThemeCatalog.defaultThemeID ? "\($0.name) — Default" : $0.name })
        #expect(
            items.first { ($0.representedObject as? String) == ThemeCatalog.defaultThemeID }?.title
                .contains("Default") == true)

        // The current theme carries the one checkmark.
        let checked = items.filter { $0.state == .on }
        #expect(checked.count == 1)
        #expect(checked.first?.representedObject as? String == "paper")

        // The two doors ride along: the editor (its ⇧⌘E item moved
        // here from the Format top level) and the inspector's tab.
        #expect(
            built.items.contains {
                $0.title == "Edit Theme…" && $0.keyEquivalent == "E"
                    && $0.keyEquivalentModifierMask == [.command, .shift]
            })
        #expect(built.items.contains { $0.title == "Show Theme Inspector" })
        // Swatches make the list readable at a glance.
        #expect(items.allSatisfy { $0.image != nil })
    }

    @Test func choosingAThemeMenuItemIsOneUndoStepAndUndoRestores() throws {
        let (document, controller) = try makeShownDocument(themeID: "paper")
        defer { document.close() }

        let menu = ThemeMenuController.shared.makeMenu(title: "Theme")
        ThemeMenuController.shared.populate(menu, frontController: controller)
        let ocean = try #require(menu.items.first { ($0.representedObject as? String) == "ocean" })

        controller.setDocumentThemeAction(ocean)
        #expect(document.model.theme?.id == "ocean", "choosing changes the document theme")

        // ONE undo step: undo restores, redo re-applies, and after the
        // single undo nothing remains on the stack.
        let undoManager = try #require(document.store.undoManager)
        undoManager.undo()
        #expect(document.model.theme?.id == "paper")
        #expect(!undoManager.canUndo, "applying a theme is exactly one undo step")
        undoManager.redo()
        #expect(document.model.theme?.id == "ocean")

        // Choosing the already-current theme is a no-op: the undo
        // stack is unchanged, so one undo still lands on Paper (a
        // spurious second entry would have landed on Ocean).
        let current = try #require(menu.items.first { ($0.representedObject as? String) == "ocean" })
        controller.setDocumentThemeAction(current)
        #expect(document.model.theme?.id == "ocean")
        undoManager.undo()
        #expect(document.model.theme?.id == "paper", "the no-op registered no undo entry")
    }

    @Test func themeMenuItemsValidateOnlyWithADocumentWindow() throws {
        let (document, controller) = try makeShownDocument(themeID: "paper")
        defer { document.close() }

        // With a document behind the controller, the chain validates
        // every theme door enabled.
        let choose = NSMenuItem(
            title: "Ocean", action: #selector(DocumentWindowController.setDocumentThemeAction(_:)),
            keyEquivalent: "")
        #expect(controller.validateMenuItem(choose) == true)
        let showInspector = NSMenuItem(
            title: "Show Theme Inspector",
            action: #selector(DocumentWindowController.showThemeInspectorAction(_:)),
            keyEquivalent: "")
        #expect(controller.validateMenuItem(showInspector) == true)

        // With no front document window, populate disables every item —
        // the same truth the responder chain tells.
        let menu = ThemeMenuController.shared.makeMenu(title: "Theme")
        ThemeMenuController.shared.populate(menu, frontController: nil)
        #expect(!menu.items.isEmpty)
        #expect(menu.items.allSatisfy { !$0.isEnabled })
        #expect(menu.items.allSatisfy { $0.state == .off })
    }

    // MARK: F-STY-4 live hover preview (view-only)

    @Test func hoverPreviewAppliesAndRevertsWithoutTouchingTheModelOrUndo() throws {
        let (document, controller) = try makeShownDocument(themeID: "paper")
        defer { document.close() }
        let canvas = controller.canvas
        let editedBefore = document.isDocumentEdited
        let ocean = BuiltInThemes.theme(id: "ocean")
        let paper = BuiltInThemes.theme(id: "paper")

        // The toolbar pull-down is owned by this window, so hover
        // previews target exactly this document (the menu-bar copy
        // resolves through the key window).
        let menu = ThemeMenuController.shared.makeMenu(title: "Theme", owner: controller)
        let oceanItem = try #require(menu.items.first { ($0.representedObject as? String) == "ocean" })

        // Hovering the item pins Ocean on the canvas…
        ThemeMenuController.shared.menu(menu, willHighlight: oceanItem)
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: ocean.canvasColor(for: .light)),
            "the preview must recolor the canvas")
        // …as a pure view state: model, dirty flag and undo stack stay.
        #expect(document.model.theme?.id == "paper")
        #expect(document.isDocumentEdited == editedBefore, "hover never dirties the document")
        #expect(!document.store.undoManager.canUndo, "hover registers no undo step")

        // Leaving the list (highlight gone) restores the stored theme.
        ThemeMenuController.shared.menu(menu, willHighlight: nil)
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: paper.canvasColor(for: .light)))

        // A menu dismissed mid-hover restores too (menuDidClose).
        ThemeMenuController.shared.menu(menu, willHighlight: oceanItem)
        ThemeMenuController.shared.menuDidClose(menu)
        #expect(
            PaperTheme.hex(of: try #require(canvas.scene?.canvasColor))
                == PaperTheme.hex(of: paper.canvasColor(for: .light)))
        #expect(controller.previewThemeID == nil)
    }

    // MARK: the toolbar door (§4.1)

    @Test func themeToolbarItemRidesTheDefaultAndInstalledSets() throws {
        let (document, controller) = try makeShownDocument(themeID: "paper")
        defer { document.close() }

        #expect(DocumentWindowController.defaultToolbarItemOrder.contains(.theme))
        // The pull-down is the same shared menu: every theme, the
        // current one checked.
        let item = try #require(controller.toolbarItem(for: .theme))
        let pullDown = try #require(item as? NSMenuToolbarItem)
        #expect(item.label == "Theme")
        #expect(pullDown.menu.items.contains { $0.representedObject is String })
        #expect(
            pullDown.menu.items.contains { ($0.representedObject as? String) == "paper" && $0.state == .on })
        // Never selection-dependent: a theme is always choosable.
        controller.canvas.setSelection([])
        #expect(controller.validateToolbarItem(item))

        // The real window's toolbar installs it (the `.v3` autosave
        // reset hands the new default item to existing users).
        let toolbar = try #require(controller.window?.toolbar)
        #expect(toolbar.items.map(\.itemIdentifier).contains(.theme))
    }

    // MARK: the Inspector door

    @Test func settingsDefaultThemePickerListsStudioFirst() {
        // F-STY-6/ADR-0031: Studio is the new-map default and leads
        // every default-theme list (Settings ▸ General and the
        // Inspector's New Documents picker read these orders).
        #expect(BuiltInThemes.all.first?.id == BuiltInThemes.newDocumentDefaultID)
        #expect(ThemeCatalog.shared.themes.first?.id == BuiltInThemes.newDocumentDefaultID)
    }

    @Test func showThemeInspectorOpensThePaneOnTheThemeTab() throws {
        let original = DocumentPreferences.inspectorVisible
        defer { DocumentPreferences.inspectorVisible = original }
        DocumentPreferences.inspectorVisible = false

        let (document, controller) = try makeShownDocument(themeID: "paper")
        defer { document.close() }
        #expect(!controller.inspector.isInstalled)

        controller.showThemeInspectorAction(nil)
        #expect(controller.inspector.isVisible, "the hidden pane installs shown")
        #expect(controller.inspector.model.tab == .theme)
        #expect(DocumentPreferences.inspectorVisible, "the show persists like ⌥⌘I")

        // Already visible on another tab: switching stays a show.
        controller.inspector.model.tab = .style
        controller.showThemeInspectorAction(nil)
        #expect(controller.inspector.isVisible)
        #expect(controller.inspector.model.tab == .theme)
    }
}
