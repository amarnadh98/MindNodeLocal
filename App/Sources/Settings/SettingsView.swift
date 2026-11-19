import AppKit
import SwiftUI

/// The Settings window's tab catalog (SPEC §5.20 F-SET). Every tab in
/// the SPEC table appears; rows whose feature is not built yet render
/// disabled with an honest note, and only rows with behaviour behind
/// them persist anything. `allCases` is the §14.1 completeness anchor a
/// hosted test asserts against.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case editing
    case appearance
    case themes
    case shortcuts
    case study
    case ai
    case integrations
    case updates
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .editing: "Editing"
        case .appearance: "Appearance"
        case .themes: "Themes"
        case .shortcuts: "Shortcuts"
        case .study: "Study"
        case .ai: "AI"
        case .integrations: "Integrations"
        case .updates: "Updates"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .editing: "square.and.pencil"
        case .appearance: "eye"
        case .themes: "paintpalette"
        case .shortcuts: "keyboard"
        case .study: "graduationcap"
        case .ai: "sparkles"
        case .integrations: "puzzlepiece"
        case .updates: "arrow.down.circle"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// The hosted-SwiftUI Settings content (F-SET): a sidebar-adaptable
/// tab view. Wired rows write the exact keys the owning features read;
/// everything else is disabled with the milestone note.
struct SettingsView: View {
    @AppStorage(AppSettings.restoreWindowsKey) private var restoreWindows = true
    @AppStorage(AppSettings.smartTypingKey) private var smartTyping = true
    @AppStorage(AppSettings.spellCheckKey) private var spellCheck = true
    @AppStorage(AppSettings.showsMinimapKey) private var showsMinimap = true
    @AppStorage(AppSettings.quickEntryMenuBarExtraKey) private var menuBarExtra = true
    @AppStorage(AppSettings.quickEntryHotkeyKey) private var quickEntryHotkey =
        HotkeySpec.quickEntryDefault.defaultsString

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Form { rows(for: tab) }
                    .formStyle(.grouped)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 620, minHeight: 460)
        .onChange(of: smartTyping) { applyEditorTypingPreferences() }
        .onChange(of: spellCheck) { applyEditorTypingPreferences() }
        .onChange(of: showsMinimap) { applyMinimapPreference(showsMinimap) }
        .onChange(of: menuBarExtra) {
            QuickEntryCoordinator.shared.setMenuBarExtra(menuBarExtra)
        }
    }

    /// One tab's rows. The wired ones write live behaviour; the rest are
    /// `UnavailableRow`s with their SPEC label.
    @ViewBuilder
    private func rows(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            wiredToggle("Restore windows", isOn: $restoreWindows)
            unavailable(
                "Default theme",
                note: "Documents remember their theme; a new-document default ships with the themes slice.")
            unavailable("Default structure", note: "Only the balanced map structure is built so far.")
            unavailable("New-document location", note: "New maps stay in the standard Documents flow.")
            unavailable("Open Library at launch", note: "The Library window ships with a later milestone.")
        case .editing:
            wiredToggle("Smart typing", isOn: $smartTyping)
            wiredToggle("Spell check", isOn: $spellCheck)
            unavailable("Typing replaces text", note: "Always on in the editor overlay.")
            unavailable("Node max width", note: "Fixed at the designed 280 pt for now.")
            unavailable("Default spacing", note: "Layout spacing is the designed default.")
            unavailable("Animation speed", note: "Motion follows the system Reduce Motion setting.")
        case .appearance:
            wiredToggle("Show minimap", isOn: $showsMinimap)
            unavailable("Toolbar style", note: "The unified-compact style is the only one built.")
            unavailable("Show status bar", note: "Not built yet.")
            unavailable("Reduced motion override", note: "Follows the system setting for now.")
        case .themes:
            unavailable(
                "Manage, import, export",
                note:
                    "Twelve built-in themes are available per document; theme import/export ships with the Library milestone."
            )
        case .shortcuts:
            hotkeyRow
            wiredToggle("Quick Entry in menu bar", isOn: $menuBarExtra)
            inboxRow
            unavailable("Custom key bindings", note: "Menu commands use the built-in shortcuts only.")
        case .study:
            unavailable("Daily limits", note: "Study settings are per document in this build.")
            unavailable("Desired retention", note: "Study settings are per document in this build.")
            unavailable("Learning steps", note: "Study settings are per document in this build.")
            unavailable("Reminder time", note: "Study reminders ship with the study UI milestone.")
        case .ai:
            unavailable("Provider and keys", note: "AI features are not wired into the app yet.")
            unavailable("AI off switch", note: "No AI call exists in this build — nothing sends data.")
            unavailable("Privacy", note: "No network calls are made by this build (SPEC §12).")
        case .integrations:
            unavailable("Reminders, MCP, URL scheme, Services", note: "Planned in a later milestone.")
        case .updates:
            unavailable("Automatic check, beta channel", note: "Sparkle lands with the release milestone.")
        case .advanced:
            unavailable("Rebuild index", note: "The library index ships with the Library milestone.")
            unavailable("Reset tips", note: "No tips store exists yet.")
            unavailable("Export diagnostics", note: "Planned in a later milestone.")
            unavailable("File-format pretty-print", note: "map.json is always written pretty-printed.")
        }
    }

    /// The Quick Entry global hotkey (F-SET Shortcuts, F-QEN-1).
    private var hotkeyRow: some View {
        LabeledContent {
            HotkeyRecorder(
                current: HotkeySpec(defaultsString: quickEntryHotkey) ?? .quickEntryDefault
            ) { spec in
                if QuickEntryCoordinator.shared.updateHotkey(spec) {
                    quickEntryHotkey = spec.defaultsString
                }
            }
        } label: {
            Text("Quick Entry hotkey")
        }
    }

    /// The designated inbox map (F-QEN-2): what "Append to Inbox"
    /// captures into.
    private var inboxRow: some View {
        LabeledContent {
            HStack {
                if let name = QuickEntryInboxStore.shared.displayName() {
                    Text(name)
                    Button("Choose…") { _ = QuickEntryInboxStore.shared.chooseInboxMap() }
                    Button("None") { QuickEntryInboxStore.shared.clear() }
                } else {
                    Text("None")
                    Button("Choose…") { _ = QuickEntryInboxStore.shared.chooseInboxMap() }
                }
            }
        } label: {
            Text("Inbox map")
        }
    }

    /// A row whose toggle writes a real key the owning feature reads.
    private func wiredToggle(_ title: String, isOn binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
    }

    /// A row whose feature is not built: shown, disabled, honest.
    private func unavailable(_ title: String, note: String) -> some View {
        LabeledContent(title) {
            Text("Not available yet")
                .foregroundStyle(.secondary)
        }
        .help(note)
        .disabled(true)
    }

    /// Editor preferences live-apply to an open Quick Entry panel.
    private func applyEditorTypingPreferences() {
        QuickEntryCoordinator.shared.refreshEditorTypingPreferences()
    }

    /// The minimap preference mirrors ⌥⌘M: existing windows follow the
    /// new value immediately.
    private func applyMinimapPreference(_ value: Bool) {
        for window in NSApp.windows {
            if let controller = window.windowController as? DocumentWindowController {
                controller.minimap?.preferredVisible = value
            }
        }
    }
}
