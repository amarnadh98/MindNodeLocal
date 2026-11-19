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
                    item("Select All", #selector(NSText.selectAll(_:)), "a"),
                ]))
        mainMenu.addItem(
            menu(
                "View",
                [
                    item("Zoom In", #selector(CanvasView.zoomInAction(_:)), "+"),
                    item("Zoom Out", #selector(CanvasView.zoomOutAction(_:)), "-"),
                    item("Actual Size", #selector(CanvasView.actualSizeAction(_:)), "0"),
                    item("Zoom to Fit", #selector(CanvasView.zoomToFitAction(_:)), "9"),
                    item("Zoom to Selection", #selector(CanvasView.zoomToSelectionAction(_:)), "0", option: true),
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
        _ title: String, _ action: Selector, _ key: String, option: Bool = false
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = nil
        if option {
            menuItem.keyEquivalentModifierMask = [.command, .option]
        }
        return menuItem
    }
}
