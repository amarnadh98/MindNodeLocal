import AppKit
import SwiftUI

/// F-ONB-2: Help ▸ Keyboard Shortcuts (⌘/) — a searchable cheat-sheet
/// overlay. The menu section is WALKED from the live `NSApp.mainMenu`
/// (the ⇧⌘P command-palette walker's source of truth), so it can never
/// drift from what the menus actually do; the "Canvas", "Presenting",
/// "Studying" and "Recall" sections are the SPEC §6 keys that are
/// deliberately keyDown-only (arrows, hold-keys, drag modifiers) and
/// therefore never appear as menu equivalents.
@MainActor
enum ShortcutsSheet {
    struct Entry: Identifiable, Equatable {
        let section: String
        let action: String
        let shortcut: String
        var id: String { "\(section)·\(action)" }
    }

    /// Every entry the sheet lists. Menu order first, then the
    /// keyDown-only tables.
    static func entries(from menu: NSMenu?) -> [Entry] {
        menuEntries(from: menu) + canvasOnlyEntries
    }

    /// The menu walk: one entry per visible leaf item that carries a
    /// key equivalent, grouped under its top-level menu's title.
    /// Disabled items are included on purpose — a cheat-sheet is a
    /// reference, not a command list.
    static func menuEntries(from menu: NSMenu?) -> [Entry] {
        guard let menu else { return [] }
        var result: [Entry] = []
        for (index, topLevel) in menu.items.enumerated() {
            guard index > 0, let submenu = topLevel.submenu else { continue }
            walkLeaves(submenu, section: topLevel.title, into: &result)
        }
        return result
    }

    private static func walkLeaves(_ menu: NSMenu, section: String, into result: inout [Entry]) {
        for item in menu.items {
            if item.isSeparatorItem || item.isHidden || item.title.isEmpty { continue }
            if let submenu = item.submenu, submenu.items.contains(where: { !$0.isSeparatorItem }) {
                walkLeaves(submenu, section: section, into: &result)
                continue
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            result.append(
                Entry(section: section, action: item.title, shortcut: shortcutText(of: item)))
        }
    }

    /// The SPEC §6 keys with no menu equivalent: they are canvas-level
    /// keyDown handlers and drag modifiers, exactly as built (the
    /// presentation/recall state machines in CanvasKit/MapStudy).
    /// Space-as-connection during a drag is deliberately absent — it
    /// is the F-REL-1 follow-up.
    static let canvasOnlyEntries: [Entry] = [
        Entry(section: "Canvas", action: "Move selection (spatial)", shortcut: "← ↑ ↓ →"),
        Entry(section: "Canvas", action: "Extend selection", shortcut: "⇧ + arrows"),
        Entry(section: "Canvas", action: "Pan the canvas", shortcut: "Space-drag"),
        Entry(section: "Canvas", action: "New floating note", shortcut: "double-click empty canvas"),
        Entry(section: "Canvas", action: "Place a dragged node freely", shortcut: "hold ⌥"),
        Entry(section: "Canvas", action: "Keep a dragged node's own style", shortcut: "hold ⌘"),
        Entry(section: "Canvas", action: "Detach a dragged branch into a new root", shortcut: "D"),
        Entry(section: "Canvas", action: "Cancel a drag", shortcut: "⎋"),
        Entry(section: "Presenting", action: "Next build or slide", shortcut: "→ / Space / ⏎"),
        Entry(section: "Presenting", action: "Back", shortcut: "←"),
        Entry(section: "Presenting", action: "First / last slide", shortcut: "Home / End"),
        Entry(section: "Presenting", action: "Jump to slide", shortcut: "number + ⏎"),
        Entry(section: "Presenting", action: "Blank the screen", shortcut: "B / W"),
        Entry(section: "Presenting", action: "Pause to edit, then resume", shortcut: "E, then ⌘⏎"),
        Entry(section: "Presenting", action: "Presenter view (one display)", shortcut: "⌥P"),
        Entry(section: "Presenting", action: "Laser pointer", shortcut: "hold L"),
        Entry(section: "Presenting", action: "Spotlight", shortcut: "hold S"),
        Entry(section: "Presenting", action: "Exit", shortcut: "⎋"),
        Entry(section: "Studying", action: "Show answer, then grade Good", shortcut: "Space"),
        Entry(section: "Studying", action: "Grade Again / Hard / Good / Easy", shortcut: "1 2 3 4"),
        Entry(section: "Recall", action: "Reveal the next hidden node", shortcut: "→"),
        Entry(section: "Recall", action: "Reveal a whole subtree", shortcut: "⌥-click a card"),
        Entry(section: "Recall", action: "Mark remembered / forgot", shortcut: "1 / 2"),
        Entry(section: "Recall", action: "Exit recall", shortcut: "⎋"),
    ]

    /// The ⇧⌘P palette's notation (one source of truth for both
    /// surfaces).
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

    /// Filters `entries` by a query: case-insensitive over the action,
    /// the section and the shortcut's letters.
    static func filtered(_ entries: [Entry], query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        let folded = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return entries.filter { entry in
            entry.action.folding(options: .caseInsensitive, locale: nil).contains(folded)
                || entry.section.folding(options: .caseInsensitive, locale: nil).contains(folded)
                || entry.shortcut.folding(options: .caseInsensitive, locale: nil).contains(folded)
        }
    }

    // MARK: presentation (a floating panel, the Quick Open pattern)

    private static var panel: NSPanel?

    /// Opens (or re-fronts) the cheat sheet.
    static func toggle() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "Keyboard Shortcuts"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isRestorable = false
        panel.contentView = NSHostingView(
            rootView: ShortcutsSheetView(entries: entries(from: NSApp.mainMenu)))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    /// For hosted tests: the open panel, if any.
    static var panelForTesting: NSPanel? { panel }
}

/// The cheat-sheet face: a search field over the grouped list.
/// VoiceOver: each row reads "action, shortcut, section".
struct ShortcutsSheetView: View {
    let entries: [ShortcutsSheet.Entry]
    @State private var query = ""

    private var filtered: [ShortcutsSheet.Entry] {
        ShortcutsSheet.filtered(entries, query: query)
    }

    /// Stable section order (menu order, then the keyDown tables).
    private var sectionOrder: [String] {
        var seen: [String] = []
        for entry in entries where !seen.contains(entry.section) {
            seen.append(entry.section)
        }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                "Search shortcuts",
                text: $query,
                onEditingChanged: { _ in }
            )
            .textFieldStyle(.roundedBorder)
            .padding(12)
            .accessibilityLabel("Search shortcuts")
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No shortcuts match “\(query)”")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(
                            sectionOrder.filter { section in
                                filtered.contains { $0.section == section }
                            }, id: \.self
                        ) { section in
                            sectionGroup(section)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    @ViewBuilder
    private func sectionGroup(_ section: String) -> some View {
        if let first = filtered.first(where: { $0.section == section }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section)
                    .font(.headline)
                ForEach(filtered.filter { $0.section == section }) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.action)
                        Spacer(minLength: 8)
                        Text(entry.shortcut)
                            .font(.system(size: NSFont.smallSystemFontSize, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(entry.action), \(entry.shortcut), in \(entry.section)")
                }
            }
        }
    }
}
