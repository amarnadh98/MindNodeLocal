import AppKit

/// Updater menu wiring (SPEC §13 "In-app updates", ADR-0021).
///
/// The Sparkle controller lives in `AppUpdater` (separate file); this
/// extension only builds the two app-menu items and routes their
/// actions, so `AppDelegate`'s type body stays under swiftlint's
/// `type_body_length` limit.
extension AppDelegate: NSMenuItemValidation {
    /// The app-menu updater section, after About: the manual check and
    /// the SPEC §12 opt-in toggle for automatic checks.
    func addUpdaterItems(to appMenu: NSMenu) {
        appMenu.addItem(
            NSMenuItem(
                title: "Check for Updates…", action: #selector(checkForUpdatesAction(_:)),
                keyEquivalent: ""))
        appMenu.addItem(
            NSMenuItem(
                title: "Automatically Check for Updates",
                action: #selector(toggleAutomaticChecksAction(_:)), keyEquivalent: ""))
    }

    /// Manual check (SPEC §12): the only way Sparkle touches the
    /// network unless the user turned automatic checks on themselves.
    @objc func checkForUpdatesAction(_ sender: Any?) {
        AppUpdater.shared.checkForUpdates()
    }

    /// Flips the persisted preference; the menu's checkmark mirrors it
    /// through `validateMenuItem` below.
    @objc func toggleAutomaticChecksAction(_ sender: Any?) {
        AppUpdater.shared.setAutomaticallyChecks(!AppUpdater.shared.automaticallyChecks)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutomaticChecksAction(_:)) {
            item.state = AppUpdater.shared.automaticallyChecks ? .on : .off
            return true
        }
        // Match NSResponder's default for items that reach the delegate:
        // enabled iff it performs the action.
        return responds(to: item.action)
    }
}
