import AppKit
import MapRender
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
    /// Settings ▸ AI (F-AI-1): the AI slice's own pane, hosted as a tab.
    @StateObject private var aiModel = AISettingsModel()
    @StateObject private var integrationsModel = IntegrationsModel()
    @State private var automaticUpdateChecks = AppUpdater.shared.automaticallyChecks
    /// F-STY-6/5: the themes the pickers offer (built-ins + user
    /// themes), re-read when the tab appears so an import shows up.
    @State private var knownThemes: [MapRender.Theme] = []
    /// F-STY-6: the default theme for new documents.
    @State private var defaultThemeID = ThemeCatalog.defaultThemeID
    /// F-STY-5: the theme chosen for the Themes tab's Export row.
    @State private var exportThemeID = BuiltInThemes.defaultID
    @State private var themesStatus = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                tabContent(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 620, minHeight: 460)
        .onAppear { reloadThemes() }
        .onChange(of: smartTyping) { applyEditorTypingPreferences() }
        .onChange(of: spellCheck) { applyEditorTypingPreferences() }
        .onChange(of: showsMinimap) { applyMinimapPreference(showsMinimap) }
        .onChange(of: menuBarExtra) {
            QuickEntryCoordinator.shared.setMenuBarExtra(menuBarExtra)
        }
    }

    /// F-STY-5/6: the catalog re-reads its folder so an import or a
    /// theme-editor save is reflected immediately.
    private func reloadThemes() {
        ThemeCatalog.shared.reload()
        knownThemes = ThemeCatalog.shared.themes
        defaultThemeID = ThemeCatalog.defaultThemeID
    }

    /// The AI and Integrations tabs host their slices' panes (each its
    /// own grouped Form); every other tab is a grouped Form of rows.
    @ViewBuilder
    private func tabContent(_ tab: SettingsTab) -> some View {
        if tab == .ai {
            AISettingsView().environmentObject(aiModel)
        } else if tab == .integrations {
            // F-INT-4/6: the MCP toggle, client config and Services inbox.
            IntegrationsView(model: integrationsModel)
        } else {
            Form { rows(for: tab) }
                .formStyle(.grouped)
        }
    }

    /// One tab's rows. The wired ones write live behaviour; the rest are
    /// `UnavailableRow`s with their SPEC label.
    @ViewBuilder
    private func rows(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            wiredToggle("Restore windows", isOn: $restoreWindows)
            defaultThemeRow
            unavailable("Default structure", note: "Only the balanced map structure is built so far.")
            unavailable("New-document location", note: "New maps stay in the standard Documents flow.")
            unavailable("Open Library at launch", note: "Open it from Window ▸ Library (⇧⌘L).")
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
            themeManagementRows
        case .shortcuts:
            hotkeyRow
            wiredToggle("Quick Entry in menu bar", isOn: $menuBarExtra)
            inboxRow
            unavailable("Custom key bindings", note: "Menu commands use the built-in shortcuts only.")
        case .study:
            unavailable("Daily limits", note: "Study settings are per document in this build.")
            unavailable("Desired retention", note: "Study settings are per document in this build.")
            unavailable("Learning steps", note: "Study settings are per document in this build.")
            unavailable("Reminder time", note: "Set the daily reminder in the Study dashboard.")
        case .ai:
            EmptyView()  // Hosted by `tabContent(_:)`.
        case .integrations:
            // Hosted by `tabContent` (IntegrationsView); Reminders sync
            // is still to come.
            unavailable("Reminders", note: "Planned in a later milestone.")
        case .updates:
            // SPEC §12/§13 (ADR-0021): off by default; Sparkle reads the
            // same defaults key.
            Toggle(
                "Automatically check for updates",
                isOn: Binding(
                    get: { automaticUpdateChecks },
                    set: { value in
                        automaticUpdateChecks = value
                        AppUpdater.shared.setAutomaticallyChecks(value)
                    }))
            LabeledContent("Check now") {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            }
            unavailable("Beta channel", note: "Only the stable appcast is published.")
        case .advanced:
            unavailable("Rebuild index", note: "Use Library ▸ Advanced ▸ Rebuild Index.")
            resetTipsRow
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

    // MARK: F-STY-6 default theme (General)

    /// The default theme picker (F-STY-6): new documents start here
    /// (MapDocument reads the same key when it builds a fresh model).
    private var defaultThemeRow: some View {
        Picker("Default theme", selection: $defaultThemeID) {
            ForEach(knownThemes, id: \.id) { theme in
                Text(theme.name).tag(theme.id)
            }
        }
        .onChange(of: defaultThemeID) { _, newValue in
            ThemeCatalog.defaultThemeID = newValue
        }
        .accessibilityLabel("Default theme for new documents")
    }

    // MARK: F-STY-5 manage / import / export (Themes)

    /// The Themes tab: manage, import, export rows (SPEC §5.20).
    private var themeManagementRows: some View {
        Section("Themes") {
            LabeledContent("Themes folder") {
                Button("Open in Finder") { openThemesFolder() }
            }
            LabeledContent("Import theme…") {
                Button("Choose File…") { importTheme() }
            }
            exportThemeRow
            if !userThemes.isEmpty {
                userThemeList
            }
            if !themesStatus.isEmpty {
                Text(themesStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportThemeRow: some View {
        LabeledContent("Export theme…") {
            HStack {
                Picker("", selection: $exportThemeID) {
                    ForEach(knownThemes, id: \.id) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                Button("Export…") { exportTheme() }
            }
        }
    }

    /// User themes with per-row default/delete (built-ins are
    /// read-only app data).
    private var userThemeList: some View {
        Section("Your themes") {
            ForEach(userThemes, id: \.id) { theme in
                LabeledContent(theme.name) {
                    HStack {
                        Button("Make Default") {
                            defaultThemeID = theme.id
                            ThemeCatalog.defaultThemeID = theme.id
                            themesStatus = "New maps start in \(theme.name)."
                        }
                        Button("Delete", role: .destructive) { deleteUserTheme(theme) }
                    }
                }
            }
        }
    }

    private var userThemes: [Theme] {
        knownThemes.filter { theme in !BuiltInThemes.all.contains { $0.id == theme.id } }
    }

    private func openThemesFolder() {
        try? FileManager.default.createDirectory(
            at: ThemeCatalog.shared.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ThemeCatalog.shared.directory)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [ThemeCatalog.themeType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let installed = try ThemeCatalog.shared.install(from: url)
            reloadThemes()
            themesStatus = "Installed \(installed.name)."
        } catch {
            themesStatus = "The theme file could not be read."
        }
    }

    private func exportTheme() {
        guard let theme = knownThemes.first(where: { $0.id == exportThemeID }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ThemeCatalog.themeType]
        panel.nameFieldStringValue =
            ThemeCatalog.sanitizedName(theme.name, fallback: theme.id)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeCatalog.shared.export(theme, to: url)
            themesStatus = "Exported \(theme.name)."
        } catch {
            themesStatus = "The theme could not be exported."
        }
    }

    private func deleteUserTheme(_ theme: Theme) {
        try? ThemeCatalog.shared.deleteUserTheme(id: theme.id)
        reloadThemes()
        if defaultThemeID == theme.id {
            defaultThemeID = BuiltInThemes.newDocumentDefaultID
            ThemeCatalog.defaultThemeID = BuiltInThemes.newDocumentDefaultID
        }
    }

    // MARK: F-ONB-4 reset tips (Advanced)

    /// Settings ▸ Advanced ▸ Reset tips: every "Got it" goes, so
    /// contextual tips may show again from the next session.
    private var resetTipsRow: some View {
        LabeledContent("Reset tips") {
            Button("Reset") {
                TipCenter.resetAllDismissed()
                themesStatus = ""
            }
        }
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
