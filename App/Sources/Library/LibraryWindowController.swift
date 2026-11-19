import AppKit
import MapLibrary
import SwiftUI

/// The one Library window (SPEC §4: "Library window (one; optional,
/// ⇧⌘L)"), hosting the SwiftUI split view.
@MainActor
final class LibraryWindowController: NSWindowController {
    init(model: LibraryModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Library"
        window.minSize = NSSize(width: 560, height: 360)
        let hosting = NSHostingView(
            rootView: LibrarySplitView().environmentObject(model))
        window.contentView = hosting
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}
