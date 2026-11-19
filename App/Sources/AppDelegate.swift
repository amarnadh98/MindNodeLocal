import AppKit
import CanvasKit

@main
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

    private func buildMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(
            menu(
                "File",
                [
                    item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
                    item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
                    .separator(),
                    item("Save", #selector(NSDocument.save(_:)), "s"),
                    item("Save As…", #selector(NSDocument.saveAs(_:)), "S"),
                    item("Revert to Saved", #selector(NSDocument.revertToSaved(_:)), ""),
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
                    item("Cut", #selector(NSText.cut(_:)), "x"),
                    item("Copy", #selector(NSText.copy(_:)), "c"),
                    item("Paste", #selector(NSText.paste(_:)), "v"),
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
                    item(
                        "Fold/Unfold",
                        #selector(DocumentWindowController.toggleFoldAction(_:)),
                        ".", modifiers: [.option]),
                    item("Select All", #selector(DocumentWindowController.selectAllAction(_:)), "a"),
                    item(
                        "Select Children",
                        #selector(DocumentWindowController.selectChildrenAction(_:)),
                        "a", modifiers: [.command, .option]),
                    item("Select Root", #selector(DocumentWindowController.selectRootAction(_:)), "r"),
                    item(
                        "Deselect",
                        #selector(DocumentWindowController.deselectAction(_:)),
                        "\u{1b}", modifiers: []),
                ]))
        mainMenu.addItem(
            menu(
                "View",
                [
                    item("Zoom In", #selector(CanvasView.zoomInAction(_:)), "+"),
                    item("Zoom In", #selector(CanvasView.zoomInAction(_:)), "=", hidden: true),
                    item("Zoom Out", #selector(CanvasView.zoomOutAction(_:)), "-"),
                    item("Actual Size", #selector(CanvasView.actualSizeAction(_:)), "0"),
                    item("Zoom to Fit", #selector(CanvasView.zoomToFitAction(_:)), "9"),
                    item(
                        "Zoom to Selection", #selector(CanvasView.zoomToSelectionAction(_:)),
                        "0", modifiers: [.command, .option]),
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
        modifiers: NSEvent.ModifierFlags = [.command], hidden: Bool = false
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = nil
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.isHidden = hidden
        return menuItem
    }
}
