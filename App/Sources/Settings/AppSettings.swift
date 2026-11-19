import Foundation

/// UserDefaults keys (SPEC §5.20 F-SET). Only rows whose behaviour
/// exists read a key here; features not built yet have NO key at all —
/// the Settings window shows them disabled instead of persisting a
/// preference nothing would honor. Keys owned by earlier slices keep
/// their original spellings (`ShowsMinimap`, the export sheet's
/// last-choice) so the settings row drives the same storage the menus
/// already use.
enum AppSettings {
    // MARK: keys owned by landed features

    /// F-CAN-6: the ⌥⌘M minimap preference (owned by
    /// DocumentWindowController+Toolbar; aliased here so the Settings
    /// Appearance row writes the same storage — spelled literally
    /// because the owner's constant is main-actor-isolated).
    static let showsMinimapKey = "ShowsMinimap"

    /// F-SET Shortcuts / F-QEN-1: the Quick Entry global hotkey
    /// (`HotkeySpec.defaultsString`), owned by QuickEntryCoordinator.
    static let quickEntryHotkeyKey = HotkeySpec.defaultsKey

    /// F-QEN-1: show the menu-bar extra (default on).
    static let quickEntryMenuBarExtraKey = "QuickEntryMenuBarExtra"

    /// F-SET Editing: smart typing (quotes, dashes, links) in the Quick
    /// Entry editor (default on — the feature is the editor's own).
    static let smartTypingKey = "SmartTyping"

    /// F-SET Editing: spell check in the Quick Entry editor
    /// (default on).
    static let spellCheckKey = "SpellCheck"

    /// F-SET General: AppKit's own state-restoration key — the toggle
    /// writes the preference the system already reads.
    static let restoreWindowsKey = "NSQuitAlwaysKeepsWindows"

    // MARK: value helpers

    /// A Bool stored as object-or-absent (the codebase's convention:
    /// absent means the default), over an injectable suite for tests.
    static func bool(
        _ key: String, defaults: UserDefaults = .standard, fallback: Bool
    ) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }
}
