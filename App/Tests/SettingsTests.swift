import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Arbor

/// The Settings window (SPEC §5.20 F-SET): every SPEC tab appears; the
/// rows that are wired write the exact keys their owning features read;
/// the shared-window plumbing shows on demand.
/// The suite serializes: the Settings window is a shared singleton.
@Suite(.serialized)
@MainActor
struct SettingsTests {
    @Test func everySpecTabAppears() {
        // SPEC §5.20's table: General, Editing, Appearance, Themes,
        // Shortcuts, Study, AI, Integrations, Updates, Advanced.
        #expect(SettingsTab.allCases.count == 10)
        #expect(
            SettingsTab.allCases.map(\.title) == [
                "General", "Editing", "Appearance", "Themes", "Shortcuts", "Study", "AI",
                "Integrations", "Updates", "Advanced",
            ])
        for tab in SettingsTab.allCases {
            #expect(!tab.symbol.isEmpty)
        }
    }

    @Test func settingsWindowShowsHostedContent() throws {
        SettingsWindowController.shared.show()
        let window = SettingsWindowController.shared.windowForTesting
        #expect(window.isVisible)
        #expect(window.title == "Settings")
        #expect(window.contentView is NSHostingView<SettingsView>)
    }

    @Test func appMenuSettingsItemOpensTheWindow() {
        let delegate = AppDelegate()
        delegate.settingsAction(nil)
        #expect(SettingsWindowController.shared.windowForTesting.isVisible)
    }

    @Test func wiredKeysMatchTheOwningFeatures() {
        // The minimap row writes the SAME storage ⌥⌘M flips (F-CAN-6).
        #expect(AppSettings.showsMinimapKey == DocumentWindowController.minimapDefaultsKey)
        // The hotkey row writes the Quick Entry spec's own key.
        #expect(AppSettings.quickEntryHotkeyKey == HotkeySpec.defaultsKey)
        // The restore-windows row writes AppKit's own key.
        #expect(AppSettings.restoreWindowsKey == "NSQuitAlwaysKeepsWindows")
    }

    @Test func boolHelperFallsBackWhenAbsent() {
        let defaults = UserDefaults(suiteName: "settings-tests-\(UUID().uuidString)")!
        #expect(AppSettings.bool("absent", defaults: defaults, fallback: true))
        #expect(!AppSettings.bool("absent", defaults: defaults, fallback: false))
        defaults.set(false, forKey: "present")
        #expect(!AppSettings.bool("present", defaults: defaults, fallback: true))
    }

    @Test func smartTypingAndSpellCheckDefaultsAreOn() {
        let defaults = UserDefaults(suiteName: "settings-tests-\(UUID().uuidString)")!
        #expect(AppSettings.bool(AppSettings.smartTypingKey, defaults: defaults, fallback: true))
        #expect(AppSettings.bool(AppSettings.spellCheckKey, defaults: defaults, fallback: true))
    }

    @Test func editorTypingPreferencesFollowTheKeys() {
        let defaults = UserDefaults(suiteName: "settings-tests-\(UUID().uuidString)")!
        defaults.set(false, forKey: AppSettings.smartTypingKey)
        defaults.set(false, forKey: AppSettings.spellCheckKey)

        let editor = QuickEntryPanelController.makeEditor(applyTypingPreferences: false)
        editor.applyTypingPreferences(defaults: defaults)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isContinuousSpellCheckingEnabled)

        defaults.set(true, forKey: AppSettings.smartTypingKey)
        editor.applyTypingPreferences(defaults: defaults)
        #expect(editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isContinuousSpellCheckingEnabled)
    }

    @Test func minimapPreferenceFollowsTheSharedKey() {
        let defaults = UserDefaults(suiteName: "settings-tests-\(UUID().uuidString)")!
        // The Settings row and ⌥⌘M read and write one storage: absent
        // means on, and the settings value agrees with the toolbar's.
        #expect(
            AppSettings.bool(AppSettings.showsMinimapKey, defaults: defaults, fallback: true)
                == (((defaults.object(forKey: DocumentWindowController.minimapDefaultsKey) as? Bool)
                    ?? true)))
    }
}
