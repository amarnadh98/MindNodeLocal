import AppKit
import CanvasKit
import MapIO
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
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

    private func buildMenu() -> NSMenu {
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
                    // F-INT-9: Print keeps the macOS-standard ⌘P (the
                    // Quick Open conflict was settled in ADR-0013 —
                    // Quick Open ⇧⌘O, Command Palette ⇧⌘P — so Page
                    // Setup carries no shortcut).
                    item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
                    item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), ""),
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
                ]))
        mainMenu.addItem(
            menu(
                "Window",
                [
                    item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                    item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
                    .separator(),
                    item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
                ]))
        mainMenu.addItem(helpMenuItem())
        return mainMenu
    }

    private func appMenuItem() -> NSMenuItem {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = AppIdentity.appName
        appMenu.addItem(
            withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
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
