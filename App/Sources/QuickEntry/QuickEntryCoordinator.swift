import AppKit
import Foundation

/// Quick Entry's single owner (F-QEN-1/2): the global hotkey
/// (Carbon, ADR-0020), the toggleable menu-bar extra, and the floating
/// panel. Everything the Settings window's Shortcuts tab changes goes
/// through here, so the preferences are enforced by one object with
/// testable entry points.
@MainActor
final class QuickEntryCoordinator {
    static let shared = QuickEntryCoordinator()

    /// The capture panel.
    private(set) var panelController: QuickEntryPanelController?

    /// The menu-bar extra (SPEC §5.11: toggleable), nil while off.
    private(set) var statusItem: NSStatusItem?

    private init() {}

    /// Called once at launch: registers the hotkey from the persisted
    /// preference (default ⌃⌥Space) and installs the menu-bar extra per
    /// its preference (default on).
    func start(defaults: UserDefaults = .standard) {
        registerHotkeyFromPreference(defaults: defaults)
        applyMenuBarExtraPreference(defaults: defaults)
    }

    // MARK: panel

    /// The hotkey's target: shows or hides the capture panel.
    func togglePanel() {
        if let panelController, panelController.isVisible {
            panelController.close()
        } else {
            panel().show()
        }
    }

    /// Builds the panel on first use (lazy: launch never pays for it).
    private func panel() -> QuickEntryPanelController {
        if let panelController { return panelController }
        let controller = QuickEntryPanelController()
        panelController = controller
        return controller
    }

    // MARK: hotkey (F-QEN-1)

    /// The spec the persisted preference describes (or the default when
    /// nothing valid is stored).
    static func hotkeySpec(defaults: UserDefaults = .standard) -> HotkeySpec {
        if let raw = defaults.string(forKey: AppSettings.quickEntryHotkeyKey),
            let spec = HotkeySpec(defaultsString: raw)
        {
            return spec
        }
        return .quickEntryDefault
    }

    /// Sets and persists `spec` as the global hotkey (Settings ▸
    /// Shortcuts). Unregister-first keeps the swap atomic. The File ▸
    /// Quick Entry item's key equivalent follows the spec, so the
    /// menu always shows the truth.
    @discardableResult
    func updateHotkey(_ spec: HotkeySpec, defaults: UserDefaults = .standard) -> Bool {
        let center = GlobalHotkeyCenter.shared
        center.onTrigger = { [weak self] in
            self?.hotkeyTriggered()
        }
        guard center.register(spec) else { return false }
        defaults.set(spec.defaultsString, forKey: AppSettings.quickEntryHotkeyKey)
        syncMenuHotkeyEquivalent(spec)
        return true
    }

    /// The Carbon trampoline's target. While Arbor is FRONTMOST, the
    /// File ▸ Quick Entry item with the same equivalent delivers this
    /// same key press to the app's own menu — the handler must not
    /// fire too, or one press would toggle the panel twice (open then
    /// closed in the same event). While any other app is frontmost
    /// only Carbon sees the key — that is the whole point of a global
    /// hotkey.
    private func hotkeyTriggered() {
        if let spec = GlobalHotkeyCenter.shared.activeSpec, menuCarries(spec) {
            return
        }
        togglePanel()
    }

    /// True when NSApp is active AND the menu item carries exactly
    /// `spec` (then the menu equivalent will fire for it). Exotic keys
    /// the menu can't represent (`#<code>`) have no equivalent to
    /// double-fire.
    private func menuCarries(_ spec: HotkeySpec) -> Bool {
        guard NSApp.isActive, !spec.keyEquivalentString.isEmpty else { return false }
        guard let item = quickEntryMenuItem() else { return false }
        return item.keyEquivalent == spec.keyEquivalentString
            && item.keyEquivalentModifierMask == spec.eventModifierFlags
    }

    /// The File ▸ Quick Entry item, when the menu is installed.
    private func quickEntryMenuItem() -> NSMenuItem? {
        NSApp.mainMenu?.items.first?.submenu?.items.first {
            $0.action == #selector(AppDelegate.quickEntryAction(_:))
        }
    }

    /// Keeps the menu item's equivalent equal to the registered spec
    /// (the ⌃⌥Space default as shipped, whatever the recorder captured
    /// afterwards).
    private func syncMenuHotkeyEquivalent(_ spec: HotkeySpec) {
        guard let item = quickEntryMenuItem() else { return }
        item.keyEquivalent = spec.keyEquivalentString
        item.keyEquivalentModifierMask = spec.eventModifierFlags
    }

    /// Registers the persisted hotkey preference (launch + after a
    /// Settings change). Returns false when Carbon refuses the
    /// combination (another app owns it).
    @discardableResult
    func registerHotkeyFromPreference(defaults: UserDefaults = .standard) -> Bool {
        updateHotkey(Self.hotkeySpec(defaults: defaults), defaults: defaults)
    }

    /// The currently registered hotkey (nil when Carbon refused).
    var registeredHotkey: HotkeySpec? {
        GlobalHotkeyCenter.shared.activeSpec
    }

    // MARK: menu-bar extra (F-QEN-1)

    /// Applies the persisted menu-bar-extra preference.
    func applyMenuBarExtraPreference(defaults: UserDefaults = .standard) {
        setMenuBarExtra(
            AppSettings.bool(AppSettings.quickEntryMenuBarExtraKey, defaults: defaults, fallback: true),
            defaults: defaults)
    }

    /// Installs or removes the menu-bar extra and persists the choice.
    func setMenuBarExtra(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppSettings.quickEntryMenuBarExtraKey)
        if enabled, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(
                systemSymbolName: "leaf.circle",
                accessibilityDescription: "Arbor Quick Entry")
            item.button?.action = #selector(QuickEntryCoordinator.statusItemAction(_:))
            item.button?.target = self
            statusItem = item
        } else if !enabled, let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
    }

    /// The menu-bar extra's click: the capture panel.
    @objc private func statusItemAction(_ sender: Any?) {
        togglePanel()
    }

    /// F-SET Editing changes (smart typing, spell check) live-apply to
    /// an open Quick Entry panel.
    func refreshEditorTypingPreferences() {
        panelController?.editorView.applyTypingPreferences()
    }
}
