import AppKit

/// F-ONB (SPEC §5.19) app-menu wiring: the Help items' actions and the
/// menu-item builders that would otherwise grow the AppDelegate class
/// body. Both actions are app-level (no document), so they need no
/// `validateMenuItem` conformance.
extension AppDelegate {
    /// Help ▸ "Welcome to Arbor" (F-ONB-1): reopens the welcome
    /// regardless of the seen flag.
    @objc func welcomeAction(_ sender: Any?) {
        welcomeCoordinator.showIfNeeded(force: true)
    }

    /// Help ▸ "Keyboard Shortcuts…" (⌘/, F-ONB-2): the searchable
    /// cheat-sheet overlay.
    @objc func shortcutsAction(_ sender: Any?) {
        ShortcutsSheet.toggle()
    }

    // MARK: menu-item builders

    /// View ▸ Appearance (F-STY-6): Auto / Light / Dark. The radio
    /// state comes from `validateThemesMenuItem`; the tags are the
    /// appearance modes (0 auto, 1 light, 2 dark).
    func appearanceMenuItem() -> NSMenuItem {
        func radio(_ title: String, tag: Int) -> NSMenuItem {
            let menuItem = NSMenuItem(
                title: title, action: #selector(DocumentWindowController.setAppearanceAction(_:)),
                keyEquivalent: "")
            menuItem.target = nil
            menuItem.tag = tag
            return menuItem
        }
        let submenu = NSMenu(title: "Appearance")
        submenu.addItem(radio("Follow System", tag: 0))
        submenu.addItem(radio("Light", tag: 1))
        submenu.addItem(radio("Dark", tag: 2))
        let menuItem = NSMenuItem()
        menuItem.title = "Appearance"
        menuItem.submenu = submenu
        return menuItem
    }

    /// The Help menu (rebuilt here so the app menu builder stays
    /// small): the welcome, the cheat sheet, then the system Help.
    func helpMenuItem() -> NSMenuItem {
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        // F-ONB-1: the first-launch welcome, reopened on demand.
        helpMenu.addItem(
            NSMenuItem(
                title: "Welcome to \(AppIdentity.appName)", action: #selector(welcomeAction(_:)),
                keyEquivalent: ""))
        // F-ONB-2: ⌘/ opens the searchable cheat sheet.
        helpMenu.addItem(
            NSMenuItem(
                title: "Keyboard Shortcuts…", action: #selector(shortcutsAction(_:)),
                keyEquivalent: "/"))
        helpMenu.addItem(.separator())
        helpMenu.addItem(
            NSMenuItem(
                title: "\(AppIdentity.appName) Help", action: #selector(NSApplication.showHelp(_:)),
                keyEquivalent: ""))
        helpItem.title = "Help"
        helpItem.submenu = helpMenu
        return helpItem
    }
}
