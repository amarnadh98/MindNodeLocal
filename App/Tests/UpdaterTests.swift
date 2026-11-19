import AppKit
import Foundation
import Testing

@testable import Arbor

/// Hosted app tests for the Sparkle integration (SPEC §13, ADR-0021):
/// the menu wiring, the SPEC §12 privacy default (no automatic checks
/// until the user opts in) and the shipped feed configuration.
@MainActor
struct UpdaterTests {
    /// The GitHub Pages appcast the release workflow publishes
    /// (SPEC §13 steps 6–8).
    private static let expectedFeedURL = "https://amarnadh98.github.io/MindNodeLocal/appcast.xml"

    private func withFreshChecksPreference<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: AppUpdater.automaticChecksKey)
        defer {
            defaults.removeObject(forKey: AppUpdater.automaticChecksKey)
            if let saved { defaults.set(saved, forKey: AppUpdater.automaticChecksKey) }
        }
        defaults.removeObject(forKey: AppUpdater.automaticChecksKey)
        return try body()
    }

    private func automaticChecksItem(in menu: NSMenu) throws -> NSMenuItem {
        let appMenu = try #require(menu.items.first?.submenu)
        return try #require(appMenu.items.first { $0.title == "Automatically Check for Updates" })
    }

    @Test func appMenuOffersCheckForUpdates() throws {
        let menu = AppDelegate().buildMenu()
        let appMenu = try #require(menu.items.first?.submenu)
        let check = try #require(appMenu.items.first { $0.title == "Check for Updates…" })
        #expect(check.action == #selector(AppDelegate.checkForUpdatesAction(_:)))
        // The SPEC §12 opt-in toggle rides right below it.
        let auto = try #require(appMenu.items.first { $0.title == "Automatically Check for Updates" })
        #expect(auto.action == #selector(AppDelegate.toggleAutomaticChecksAction(_:)))
    }

    @Test func automaticChecksDefaultToOffAndTheMenuShowsIt() throws {
        try withFreshChecksPreference {
            AppUpdater.registerPrivacyDefaults()
            // SPEC §12 / ADR-0021: first launch opts the user OUT.
            #expect(AppUpdater.shared.automaticallyChecks == false)

            let delegate = AppDelegate()
            let auto = try automaticChecksItem(in: delegate.buildMenu())
            #expect(delegate.validateMenuItem(auto) == true)
            #expect(auto.state == .off)
        }
    }

    @Test func togglingPersistsAndFlipsTheMenuItemState() throws {
        try withFreshChecksPreference {
            AppUpdater.registerPrivacyDefaults()
            let delegate = AppDelegate()
            let auto = try automaticChecksItem(in: delegate.buildMenu())

            // Toggle on: the value persists and validation checks it.
            delegate.toggleAutomaticChecksAction(nil)
            #expect(AppUpdater.shared.automaticallyChecks == true)
            _ = delegate.validateMenuItem(auto)
            #expect(auto.state == .on)

            // …and back off, restoring the privacy default.
            delegate.toggleAutomaticChecksAction(nil)
            #expect(AppUpdater.shared.automaticallyChecks == false)
            _ = delegate.validateMenuItem(auto)
            #expect(auto.state == .off)

            // Opting in or out never needs Sparkle itself: only the
            // manual Check for Updates… starts the controller.
            #expect(AppUpdater.shared.isUpdaterRunning == false)
        }
    }

    @Test func sparkleConfigurationIsBakedIntoTheHostApp() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == Self.expectedFeedURL)
        // The sandboxed install path runs through Sparkle's Installer
        // XPC service; the Downloader service is off because the app
        // already has the network-client entitlement (ADR-0021).
        #expect(info["SUEnableInstallerLauncherService"] as? Bool == true)
        // SPEC §12: no system profiling, ever.
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        // Read from the SPARKLE_PUBLIC_ED_KEY build setting — a
        // placeholder (possibly empty) until the owner generates the
        // EdDSA pair; see docs/release-checklist.md.
        #expect(info["SUPublicEDKey"] is String)
    }
}
