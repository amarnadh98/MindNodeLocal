import AppKit
import Testing

@testable import Arbor

/// The app must actually install its delegate at launch. `@main` alone
/// never created it (there is no main nib), so the running app had no
/// menus, Library, hotkey, Services or URL handling while every test that
/// built an `AppDelegate()` by hand still passed.
@MainActor
struct AppLaunchTests {
    @Test func launchInstallsTheAppDelegate() {
        #expect(NSApp.delegate === AppDelegate.shared)
        // `applicationDidFinishLaunching` ran: the full menu bar, not
        // just AppKit's default app menu.
        #expect((NSApp.mainMenu?.numberOfItems ?? 0) > 1)
    }

    /// A launch with nothing open must show something: a new map, or the
    /// first-launch welcome (which offers "New Map").
    @Test func launchWithNothingOpenStartsANewMap() {
        #expect(AppDelegate.opensUntitledMap(welcomeShowing: false, isTestHost: false))
        #expect(!AppDelegate.opensUntitledMap(welcomeShowing: true, isTestHost: false))
        #expect(!AppDelegate.opensUntitledMap(welcomeShowing: false, isTestHost: true))
    }
}
