import AppKit
import CanvasKit
import MapIO
import MapLibrary
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The Library window's wiring (F-LIB): index, watcher, template
    /// store and the one window. Created at launch so saves are
    /// observed from the first document on.
    private var libraryCoordinator: LibraryCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SPEC §12 / ADR-0021: before anything can construct the
        // updater, register automatic checks OFF for first launch.
        AppUpdater.registerPrivacyDefaults()
        NSApp.mainMenu = buildMenu()
        libraryCoordinator = LibraryCoordinator()
    }

    /// Window ▸ Library (⇧⌘L, SPEC §4). AppKit calls delegate actions on
    /// the main thread; the annotation is for the compiler.
    @MainActor @objc func showLibraryAction(_ sender: Any?) {
        libraryCoordinator?.showLibrary()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Dock drops and Finder double-clicks of foreign formats
    /// (`.opml`, `.md`, `.txt`, `.mm`, `.xmind`, `.mindnode`): each opens
    /// as a NEW untitled Arbor document (never overwriting the source);
    /// an importer failure becomes a sheet on the key window with the
    /// importer's own message. Declared as handled here so AppKit's
    /// default document-controller routing (which would hand the file to
    /// `MapDocument.read` without the untitling bookkeeping below) is
    /// replaced by the explicit import path.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                _ = try DocumentImporter.openForeignDocument(at: url)
            } catch {
                DocumentImporter.presentImportError(error, for: NSApp.keyWindow)
            }
        }
    }

    /// File ▸ Import… (F-IO): pick foreign files, open each as a new
    /// untitled Arbor document.
    @objc func importAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentImporter.importableFormats.compactMap { format in
            UTType(format.utTypeIdentifier)
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        for url in panel.urls {
            do {
                _ = try DocumentImporter.openForeignDocument(at: url)
            } catch {
                DocumentImporter.presentImportError(error, for: panel.sheetParent ?? NSApp.keyWindow)
            }
        }
    }

    /// Internal (not private) so hosted tests can install the menu: the
    /// test host never finishes launching, so
    /// `applicationDidFinishLaunching` has not run when the palette's
    /// menu walk needs it. In a real launch the menu is set there.
    func buildMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(
            menu(
                "File",
                [
                    item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
                    item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
                    // F-IO: foreign files import as new untitled documents.
                    item("Import…", #selector(AppDelegate.importAction(_:)), ""),
                    .separator(),
                    // F-IO export UI: ⌥⌘E (SPEC §5.17).
                    item(
                        "Export…", #selector(DocumentWindowController.exportAction(_:)), "e",
                        modifiers: [.command, .option]),
                    .separator(),
                    item("Save", #selector(NSDocument.save(_:)), "s"),
                    item("Save As…", #selector(NSDocument.saveAs(_:)), "S"),
                    item("Revert to Saved", #selector(NSDocument.revertToSaved(_:)), ""),
                    .separator(),
                    // M6 (F-PRE-1/4): present the map; ⌘⏎ resumes a
                    // run paused into live edit (its item validates
                    // only then, so ⌘⏎ keeps its editing meaning).
                    item(
                        "Present", #selector(DocumentWindowController.presentAction(_:)),
                        "\r", modifiers: [.command, .option]),
                    item(
                        "Resume Presentation", #selector(DocumentWindowController.resumePresentationAction(_:)),
                        "\r", modifiers: [.command]),
                    item(
                        "Export Slides as PDF…",
                        #selector(DocumentWindowController.exportSlidesPDFAction(_:)), ""),
                    .separator(),
                    item("Close", #selector(NSWindow.performClose(_:)), "w"),
                ]))
        mainMenu.addItem(
            menu(
                "Edit",
                [
                    item("Undo", Selector(("undo:")), "z"),
                    item("Redo", Selector(("redo:")), "Z"),
                    .separator(),
                    // F-EDT-9: the standard selectors ride the responder
                    // chain — while a node edits, the overlay text view
                    // answers cut:/copy:/paste: itself.
                    item("Cut", #selector(NSText.cut(_:)), "x"),
                    item("Copy", #selector(NSText.copy(_:)), "c"),
                    item("Paste", #selector(NSText.paste(_:)), "v"),
                    item(
                        "Paste with Style",
                        #selector(NSText.paste(_:)),
                        "v", modifiers: [.command, .option, .shift]),
                    .separator(),
                    // F-FOC-3 (SPEC §6.1 Find): the standard find bar
                    // with replace, next/previous (wrap-around) and
                    // use-selection-for-find. The actions live on the
                    // window controller (DocumentWindowController+FocusFind).
                    findSubmenu(),
                    .separator(),
                    // Edit title (F-EDT-2): ⏎/⌘⏎ are the Add-Sibling keys
                    // in the menu; F2 is unambiguous.
                    item(
                        "Edit Title",
                        #selector(DocumentWindowController.editTitleAction(_:)),
                        "\u{f705}", modifiers: []),
                    .separator(),
                    // Create (F-EDT-1) and edit (F-EDT-4/9) keys per SPEC §6.1.
                    item(
                        "Add Child",
                        #selector(DocumentWindowController.addChildAction(_:)),
                        "\t", modifiers: []),
                    item(
                        "Add Sibling Below",
                        #selector(DocumentWindowController.addSiblingBelowAction(_:)),
                        "\r", modifiers: []),
                    item(
                        "Add Sibling Above",
                        #selector(DocumentWindowController.addSiblingAboveAction(_:)),
                        "\r", modifiers: [.option]),
                    item(
                        "Insert Parent",
                        #selector(DocumentWindowController.insertParentAction(_:)),
                        "\t", modifiers: [.option]),
                    item(
                        "New Root",
                        #selector(DocumentWindowController.addRootAction(_:)),
                        "\r", modifiers: [.shift]),
                    .separator(),
                    item(
                        "Delete",
                        #selector(DocumentWindowController.deleteSubtreeAction(_:)),
                        "\u{7f}", modifiers: []),
                    item(
                        "Delete",
                        #selector(DocumentWindowController.deleteSubtreeAction(_:)),
                        "\u{f728}", modifiers: [], hidden: true),
                    item(
                        "Delete Node Only",
                        #selector(DocumentWindowController.deleteNodeOnlyAction(_:)),
                        "\u{7f}", modifiers: [.option]),
                    .separator(),
                    item("Move Up", #selector(DocumentWindowController.reorderUpAction(_:)), "\u{f700}"),
                    item("Move Down", #selector(DocumentWindowController.reorderDownAction(_:)), "\u{f701}"),
                    item("Promote", #selector(DocumentWindowController.promoteAction(_:)), "\u{f702}"),
                    item("Demote", #selector(DocumentWindowController.demoteAction(_:)), "\u{f703}"),
                    item("Duplicate", #selector(DocumentWindowController.duplicateAction(_:)), "d"),
                    item(
                        "Detach",
                        #selector(DocumentWindowController.detachAction(_:)),
                        "d", modifiers: [.command, .shift]),
                    .separator(),
                ]))
        mainMenu.addItem(
            menu(
                "Select",
                [
                    // F-CAN-4's spatial moves. The keys themselves are
                    // keyDown-only: AppKit treats unmodified arrow
                    // equivalents as menu-tracking keys (see
                    // CanvasView+Navigation.swift), so the items carry
                    // no equivalents — the moves stay menu-reachable
                    // (§14.1) all the same.
                    item(
                        "Move Selection Up", #selector(CanvasView.navigateUpAction(_:)), ""),
                    item(
                        "Move Selection Down", #selector(CanvasView.navigateDownAction(_:)), ""),
                    item(
                        "Move Selection Left", #selector(CanvasView.navigateLeftAction(_:)), ""),
                    item(
                        "Move Selection Right", #selector(CanvasView.navigateRightAction(_:)), ""),
                    item(
                        "Extend Selection Up", #selector(CanvasView.extendUpAction(_:)), "",
                        hidden: true),
                    item(
                        "Extend Selection Down", #selector(CanvasView.extendDownAction(_:)), "",
                        hidden: true),
                    item(
                        "Extend Selection Left", #selector(CanvasView.extendLeftAction(_:)), "",
                        hidden: true),
                    item(
                        "Extend Selection Right", #selector(CanvasView.extendRightAction(_:)), "",
                        hidden: true),
                    .separator(),
                    // ⌃⌥N / ⌃⌥P (§6.1 Select).
                    item(
                        "Next Root", #selector(CanvasView.nextRootAction(_:)), "n",
                        modifiers: [.control, .option]),
                    item(
                        "Previous Root", #selector(CanvasView.previousRootAction(_:)), "p",
                        modifiers: [.control, .option]),
                    .separator(),
                    item("Select All", #selector(DocumentWindowController.selectAllAction(_:)), "a"),
                    item(
                        "Select Children", #selector(DocumentWindowController.selectChildrenAction(_:)),
                        "a", modifiers: [.command, .option]),
                    item("Select Root", #selector(DocumentWindowController.selectRootAction(_:)), "r"),
                    .separator(),
                    item(
                        "Jump to Selection", #selector(CanvasView.jumpToSelectionAction(_:)), "j"),
                    item(
                        "Deselect", #selector(DocumentWindowController.deselectAction(_:)),
                        "\u{1b}", modifiers: []),
                ]))
        mainMenu.addItem(
            menu(
                "Fold",
                [
                    // F-LAY-14, §6.1 Fold: each action is one grouped
                    // `setFolded` command — one undo step.
                    item(
                        "Fold/Unfold", #selector(DocumentWindowController.toggleFoldAction(_:)),
                        ".", modifiers: [.option]),
                    item(
                        "Fold with Siblings",
                        #selector(DocumentWindowController.foldWithSiblingsAction(_:)),
                        ".", modifiers: [.command, .option]),
                    item(
                        "Unfold One Level",
                        #selector(DocumentWindowController.unfoldOneLevelAction(_:)),
                        ".", modifiers: [.control, .option]),
                    .separator(),
                    item(
                        "Show Levels 1", #selector(DocumentWindowController.showLevelsAction(_:)),
                        "1", modifiers: [.control], tag: 1),
                    item(
                        "Show Levels 2", #selector(DocumentWindowController.showLevelsAction(_:)),
                        "2", modifiers: [.control], tag: 2),
                    item(
                        "Show Levels 3", #selector(DocumentWindowController.showLevelsAction(_:)),
                        "3", modifiers: [.control], tag: 3),
                    item(
                        "Show Levels 4", #selector(DocumentWindowController.showLevelsAction(_:)),
                        "4", modifiers: [.control], tag: 4),
                    item(
                        "Show Levels 5", #selector(DocumentWindowController.showLevelsAction(_:)),
                        "5", modifiers: [.control], tag: 5),
                    item(
                        "Show All Levels", #selector(DocumentWindowController.showLevelsAction(_:)),
                        "0", modifiers: [.control], tag: 0),
                ]))
        mainMenu.addItem(
            menu(
                "AI",
                [
                    // F-AI-2: ⌘. expands the selected node; pressed
                    // again while ghosts are showing it regenerates.
                    // The whole menu hides when AI is off (F-AI-1) —
                    // AIController.validateMenuItem drives item
                    // visibility, the submenu title hides via the
                    // delegate below.
                    item(
                        "Expand Node", #selector(DocumentWindowController.aiExpandAction(_:)),
                        "."),
                    item(
                        "Generate Map From…",
                        #selector(DocumentWindowController.generateMapAction(_:)), ""),
                    .separator(),
                    // F-AI-4 (P2) helpers: each is one undo step,
                    // author "ai".
                    item(
                        "Summarize Branch to Note",
                        #selector(DocumentWindowController.aiSummarizeBranchAction(_:)), ""),
                    item(
                        "Rewrite Titles Concisely",
                        #selector(DocumentWindowController.aiRewriteTitlesAction(_:)), ""),
                    item(
                        "Suggest Document Title",
                        #selector(DocumentWindowController.aiSuggestTitleAction(_:)), ""),
                    .separator(),
                    // SPEC §12: the per-document cloud opt-out, one
                    // undoable command.
                    item(
                        "Never Send to Cloud AI",
                        #selector(DocumentWindowController.aiToggleNeverSendToCloudAction(_:)), ""),
                ]))
        mainMenu.addItem(
            menu(
                "Format",
                [
                    // F-EDT-7: rich-text titles. The actions live on the
                    // editing overlay's text view (CanvasKit), reached
                    // through the responder chain while a node edits.
                    item("Bold", NSSelectorFromString("toggleBoldAction:"), "b"),
                    item("Italic", NSSelectorFromString("toggleItalicAction:"), "i"),
                    item("Underline", NSSelectorFromString("toggleUnderlineAction:"), "u"),
                ]))
        mainMenu.addItem(
            menu(
                "View",
                [
                    // F-OUT-1: the three document view modes; the
                    // window controller swaps the content view.
                    item(
                        "Map", #selector(DocumentWindowController.showMapViewAction(_:)), "1"),
                    item(
                        "Outline", #selector(DocumentWindowController.showOutlineViewAction(_:)),
                        "2"),
                    item(
                        "Side by Side",
                        #selector(DocumentWindowController.showSideBySideViewAction(_:)), "3"),
                    .separator(),
                    item("Zoom In", #selector(CanvasView.zoomInAction(_:)), "+"),
                    item("Zoom In", #selector(CanvasView.zoomInAction(_:)), "=", hidden: true),
                    item("Zoom Out", #selector(CanvasView.zoomOutAction(_:)), "-"),
                    item("Actual Size", #selector(CanvasView.actualSizeAction(_:)), "0"),
                    item("Zoom to Fit", #selector(CanvasView.zoomToFitAction(_:)), "9"),
                    item(
                        "Zoom to Selection", #selector(CanvasView.zoomToSelectionAction(_:)),
                        "0", modifiers: [.command, .option]),
                    .separator(),
                    // F-CAN-6: the minimap toggle, persisted per user in
                    // UserDefaults; the checkmark mirrors the preference
                    // (auto-hide applies only while the whole map fits).
                    item(
                        "Minimap", #selector(DocumentWindowController.toggleMinimapAction(_:)),
                        "m", modifiers: [.command, .option]),
                    // F-FOC (SPEC §6.1 View + Find): Focus dims and
                    // fits the selected branch; Zen clears the stage;
                    // Quick Open / the command palette fuzzy-jump. Quick
                    // Open is ⇧⌘O (Xcode's "Open Quickly"): ⌘P stays the
                    // macOS-standard Print (F-INT-9, ADR-0013).
                    item(
                        "Focus Mode", #selector(DocumentWindowController.focusModeAction(_:)),
                        "F", modifiers: [.command, .shift]),
                    item(
                        "Zen Mode", #selector(DocumentWindowController.zenModeAction(_:)),
                        "f", modifiers: [.command, .control]),
                    .separator(),
                    item(
                        "Quick Open", #selector(DocumentWindowController.quickOpenAction(_:)),
                        "O", modifiers: [.command, .shift]),
                    item(
                        "Command Palette", #selector(DocumentWindowController.commandPaletteAction(_:)),
                        "P", modifiers: [.command, .shift]),
                    .separator(),
                    // M6 (F-PRE-2): the Slides sidebar, hidden by
                    // default (§6.1 View: Sidebar ⌃⌘S).
                    item(
                        "Slides Sidebar", #selector(DocumentWindowController.toggleSlidesSidebarAction(_:)),
                        "s", modifiers: [.control, .command]),
                    // F-STD-6: the mastery overlay, persisted like the
                    // minimap; pure view state, never dirties the document.
                    item(
                        "Mastery Overlay", #selector(DocumentWindowController.toggleMasteryOverlayAction(_:)),
                        "h", modifiers: [.command, .option]),
                ]))
        mainMenu.addItem(studyMenuItem())
        mainMenu.addItem(
            menu(
                "Window",
                [
                    item(
                        "Library", #selector(AppDelegate.showLibraryAction(_:)),
                        "L", modifiers: [.command, .shift]),
                    .separator(),
                    item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                    item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
                    .separator(),
                    item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
                ]))
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }
}

// Menu-building helpers, split out to keep the class body small.
extension AppDelegate {
    /// Study (F-STD-1/2/4/6/7, SPEC §6.1).
    private func studyMenuItem() -> NSMenuItem {
        menu(
            "Study",
            [
                // F-STD-4: the three session scopes.
                item(
                    "Study Branch", #selector(DocumentWindowController.studyBranchAction(_:)), ""),
                item(
                    "Study Document", #selector(DocumentWindowController.studyDocumentAction(_:)), ""),
                item(
                    "Study Due", #selector(DocumentWindowController.studyDueAction(_:)),
                    "\r", modifiers: [.control, .command]),
                .separator(),
                // F-STD-5: spatial self-testing on the canvas.
                // ⌥⌘R is free (⌘R alone is Select ▸ Select Root).
                item(
                    "Recall", #selector(DocumentWindowController.recallAction(_:)),
                    "r", modifiers: [.command, .option]),
                .separator(),
                // F-STD-6.
                item(
                    "Study Weakest Branch",
                    #selector(DocumentWindowController.studyWeakestBranchAction(_:)), ""),
                // F-STD-7.
                item(
                    "Show Dashboard", #selector(DocumentWindowController.showStudyDashboardAction(_:)),
                    ""),
                .separator(),
                // F-STD-1: the deck toggle and the card policy radio
                // group (tags: 1 Card, 2 Not a Card, 3 Auto).
                item(
                    "Make Study Deck", #selector(DocumentWindowController.makeStudyDeckAction(_:)),
                    "s", modifiers: [.command, .option]),
                item(
                    "Card", #selector(DocumentWindowController.setCardPolicyAction(_:)), "", tag: 1),
                item(
                    "Not a Card", #selector(DocumentWindowController.setCardPolicyAction(_:)), "", tag: 2),
                item(
                    "Auto", #selector(DocumentWindowController.setCardPolicyAction(_:)), "", tag: 3),
                .separator(),
                // F-STD-2: wraps the selected title text in the editor.
                item(
                    "Make Cloze", #selector(DocumentWindowController.makeClozeAction(_:)),
                    "C", modifiers: [.command, .shift]),
            ])
    }

    /// Edit ▸ Find (F-FOC-3, SPEC §6.1): NSTextFinder-style items whose
    /// actions live on the document window controller and validate
    /// against the find session (DocumentWindowController+FocusFind).
    private func findSubmenu() -> NSMenuItem {
        let submenu = NSMenu(title: "Find")
        submenu.addItem(
            item("Find…", #selector(DocumentWindowController.findAction(_:)), "f"))
        submenu.addItem(
            item(
                "Find and Replace…", #selector(DocumentWindowController.findReplaceAction(_:)),
                "f", modifiers: [.command, .option]))
        submenu.addItem(
            item("Find Next", #selector(DocumentWindowController.findNextAction(_:)), "g"))
        submenu.addItem(
            item(
                "Find Previous", #selector(DocumentWindowController.findPreviousAction(_:)),
                "G", modifiers: [.command, .shift]))
        submenu.addItem(
            item(
                "Use Selection for Find",
                #selector(DocumentWindowController.useSelectionForFindAction(_:)), "e"))
        let menuItem = NSMenuItem()
        menuItem.title = "Find"
        menuItem.submenu = submenu
        return menuItem
    }

    private func appMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = AppIdentity.appName
        appMenu.addItem(
            withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        // SPEC §13 in-app updates (ADR-0021): the wiring lives in
        // AppDelegate+Updater so this type stays under
        // swiftlint's type_body_length.
        addUpdaterItems(to: appMenu)
        appMenu.addItem(.separator())
        let services = NSMenuItem()
        services.title = "Services"
        services.submenu = NSMenu(title: "Services")
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "H")
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Settings ▸ AI (F-AI-1): ⌘,.
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenuItem.title = appName
        appMenuItem.submenu = appMenu
        return appMenuItem
    }

    private func helpMenuItem() -> NSMenuItem {
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(
            withTitle: "\(AppIdentity.appName) Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "")
        helpItem.title = "Help"
        helpItem.submenu = helpMenu
        return helpItem
    }

    // MARK: Settings ▸ AI (F-AI-1)

    /// ⌘, opens Settings ▸ AI. The app had no settings window before
    /// this milestone; AI is its first pane.
    @objc func showSettings(_ sender: Any?) {
        AISettingsPresenter.present()
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let submenu = NSMenu(title: title)
        for entry in items {
            submenu.addItem(entry)
        }
        menuItem.title = title
        menuItem.submenu = submenu
        return menuItem
    }

    private func item(
        _ title: String, _ action: Selector, _ key: String,
        modifiers: NSEvent.ModifierFlags = [.command], hidden: Bool = false, tag: Int = 0
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = nil
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.isHidden = hidden
        menuItem.tag = tag
        return menuItem
    }
}
