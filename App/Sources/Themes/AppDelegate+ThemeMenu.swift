import AppKit

// Menu-building helpers (split out of AppDelegate.buildMenu so the
// class body stays under swiftlint's length limits).

@MainActor
extension AppDelegate {
    /// F-STY-4's discoverable door (user feedback: theme selection
    /// could not be found): Format ▸ Theme — the shared theme menu
    /// (every catalog theme, the current one checked, the new-map
    /// default marked, live hover preview on the canvas) plus the
    /// Edit Theme… (⇧⌘E) and Show Theme Inspector items. One
    /// `setTheme` undo step per choice; see ThemeMenuController.
    func themeMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        menuItem.title = "Theme"
        menuItem.submenu = ThemeMenuController.shared.makeMenu(title: "Theme")
        return menuItem
    }
}
