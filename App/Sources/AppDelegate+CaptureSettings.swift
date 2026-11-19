import AppKit

/// M4 capture & settings menu support (F-QEN, F-SET, F-DOC): the
/// actions and menu-item builders that would otherwise grow the
/// AppDelegate class body past `type_body_length`. Everything here is
/// reached through the standard responder chain (nil-target items) or
/// the singletons the actions own.
extension AppDelegate {
    /// File ▸ Quick Entry (F-QEN-1): the capture panel, same action the
    /// global ⌃⌥Space hotkey and the menu-bar extra trigger.
    @objc func quickEntryAction(_ sender: Any?) {
        QuickEntryCoordinator.shared.togglePanel()
    }

    /// App ▸ Settings… (⌘,, F-SET): the hosted-SwiftUI Settings window.
    @objc func settingsAction(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    // MARK: menu-item builders

    /// The Quick Entry menu item with the SPEC §6.1 default hotkey as
    /// its equivalent (⌃⌥Space; the global registration is the Carbon
    /// path, ADR-0020).
    func quickEntryMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Quick Entry", action: #selector(AppDelegate.quickEntryAction(_:)),
            keyEquivalent: " ")
        menuItem.keyEquivalentModifierMask = [.control, .option]
        menuItem.target = nil
        return menuItem
    }

    /// F-DOC-1's File items: the Revert To submenu (Last Saved, Browse
    /// All Versions…), Duplicate, and Lock/Unlock. All NSDocument's own
    /// actions, validated by `validateDocumentSafetyMenuItem`.
    func documentSafetyItems() -> [NSMenuItem] {
        let revertMenu = NSMenu(title: "Revert To")
        revertMenu.addItem(
            NSMenuItem(
                title: "Last Saved", action: #selector(NSDocument.revertToSaved(_:)),
                keyEquivalent: ""))
        revertMenu.addItem(
            NSMenuItem(
                title: "Browse All Versions…", action: #selector(NSDocument.browseVersions(_:)),
                keyEquivalent: ""))
        let revertTo = NSMenuItem()
        revertTo.title = "Revert To"
        revertTo.submenu = revertMenu

        let duplicate = NSMenuItem(
            title: "Duplicate", action: #selector(NSDocument.duplicate(_:)),
            keyEquivalent: "")
        let lock = NSMenuItem(
            title: "Lock", action: #selector(NSDocument.lock(_:)), keyEquivalent: "")
        let unlock = NSMenuItem(
            title: "Unlock", action: #selector(NSDocument.unlock(_:)), keyEquivalent: "")
        return [revertTo, duplicate, lock, unlock]
    }
}
