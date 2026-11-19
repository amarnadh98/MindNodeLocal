import AppKit
import SwiftUI

/// The Settings window (F-SET): a single shared titled window hosting
/// the SwiftUI tab view. ⌘, toggles it (the app-menu item routes
/// here); built once, shown forever after.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Settings"
        window.minSize = NSSize(width: 620, height: 460)
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
    }

    /// ⌘,: show (or bring forward) the Settings window.
    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window itself, so hosted tests can assert visibility.
    var windowForTesting: NSWindow { window }
}
