import AppKit

/// ⇧⌘P's source list (F-FOC-4): every enabled, visible leaf command of
/// the app's main menu, as "File ▸ Save"-shaped entries with their
/// shortcut strings. Walking the real `NSMenu` (rather than a static
/// list) keeps the palette true to what the menus can actually do —
/// including menu items later milestones add.
@MainActor
enum MenuCommandListing {
    struct Entry: Identifiable, Equatable {
        let path: String
        let shortcut: String
        let action: Selector
        /// The original item, sent as the action's sender so
        /// modifier-aware actions (⇧⌥⌘V paste-with-style) read their
        /// key equivalent off it.
        let menuItem: NSMenuItem

        var id: String { path }
    }

    /// The enabled leaf commands of `menu`, top-level titles included
    /// in each path. The app menu (index 0) is skipped: its items are
    /// app-lifecycle noise in a palette.
    static func entries(from menu: NSMenu?) -> [Entry] {
        guard let menu else { return [] }
        var result: [Entry] = []
        for (index, topLevel) in menu.items.enumerated() {
            guard index > 0, let submenu = topLevel.submenu else { continue }
            walk(submenu, pathPrefix: topLevel.title, into: &result)
        }
        return result
    }

    private static func walk(_ menu: NSMenu, pathPrefix: String, into result: inout [Entry]) {
        for item in menu.items {
            if item.isSeparatorItem { continue }
            if item.isHidden || item.title.isEmpty { continue }
            let path = pathPrefix.isEmpty ? item.title : "\(pathPrefix) ▸ \(item.title)"
            if let submenu = item.submenu, submenu.items.contains(where: { !$0.isSeparatorItem }) {
                walk(submenu, pathPrefix: path, into: &result)
                continue
            }
            // A leaf: needs someone who can perform the action right
            // now, and that someone must still validate the item as
            // enabled (e.g. "Find Next" needs an active find session).
            guard let action = item.action, !action.description.isEmpty else { continue }
            // In an autoenabling menu `isEnabled` only caches the last
            // menu update (stale when no document window was key then);
            // `isPermitted` below re-runs validation against today's target.
            guard item.isEnabled || menu.autoenablesItems else { continue }
            guard let target = target(for: action), isPermitted(item, target: target)
            else { continue }
            result.append(
                Entry(
                    path: path, shortcut: shortcutText(of: item),
                    action: action, menuItem: item))
        }
    }

    /// Performs the entry exactly as its menu item would: through the
    /// responder chain, with the item itself as sender.
    static func perform(_ entry: Entry) {
        NSApp.sendAction(entry.action, to: nil, from: entry.menuItem)
    }

    /// "⇧⌘F"-style shortcut text, or "" when the item has none.
    static func shortcutText(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent
    }

    /// Who in the app can perform `action` right now: the key/main
    /// window's responder chain first (NSApp.target), then — when no
    /// window is key (the palette opened before one became key, or a
    /// hosted test) — any window controller that implements it.
    private static func target(for action: Selector) -> NSObject? {
        if let found = NSApp.target(forAction: action, to: nil, from: nil) as? NSObject {
            return found
        }
        for window in NSApp.windows {
            if let controller = window.windowController, controller.responds(to: action) {
                return controller
            }
            if let responder = window.firstResponder, responder !== window,
                responder.responds(to: action)
            {
                return responder as? NSObject ?? responder.nextResponder as? NSObject
            }
        }
        return nil
    }

    /// Honors `validateMenuItem` when the target conforms — the same
    /// check the menu machinery runs while tracking. (`perform` cannot
    /// be used: the method returns BOOL, which the id-returning
    /// `perform` family misreads as a pointer.)
    private static func isPermitted(_ item: NSMenuItem, target: NSObject) -> Bool {
        guard let validating = target as? NSMenuItemValidation else { return true }
        return validating.validateMenuItem(item)
    }
}
