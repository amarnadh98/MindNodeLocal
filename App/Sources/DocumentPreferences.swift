import Foundation

/// App-level (not per-document) preferences (F-STY-6): the default theme
/// for new documents, the inspector's visibility, and the recent-color
/// list the color pickers offer (F-STY-7). All UserDefaults-backed;
/// `UserDefaults` is MainActor-bound in Swift 6, so every accessor is.
@MainActor
enum DocumentPreferences {
    private static let suite = UserDefaults.standard

    /// The theme a brand-new document opens with ("paper" default).
    static var defaultThemeID: String {
        get { suite.string(forKey: Keys.defaultTheme) ?? "paper" }
        set { suite.set(newValue, forKey: Keys.defaultTheme) }
    }

    /// Whether the inspector pane is visible (SPEC §4.1: hidden by
    /// default). A window-chrome preference, deliberately not per-map
    /// view state: it applies to every window the user opens, like
    /// Xcode's inspector.
    static var inspectorVisible: Bool {
        get {
            // Absent = hidden; the raw flag stores `true` only.
            suite.bool(forKey: Keys.inspectorVisible)
        }
        set { suite.set(newValue, forKey: Keys.inspectorVisible) }
    }

    /// Recently picked colors, newest first (F-STY-7), capped at 12.
    static var recentColors: [String] {
        get { suite.stringArray(forKey: Keys.recentColors) ?? [] }
        set {
            var unique: [String] = []
            for hex in newValue where !unique.contains(hex) {
                unique.append(hex)
            }
            suite.set(Array(unique.prefix(12)), forKey: Keys.recentColors)
        }
    }

    /// Records a color pick for the recent list.
    static func noteColorPick(_ hex: String) {
        var recents = recentColors
        recents.removeAll { $0 == hex }
        recents.insert(hex, at: 0)
        recentColors = recents
    }

    private enum Keys {
        static let defaultTheme = "arbor.defaultThemeID"
        static let inspectorVisible = "arbor.inspectorVisible"
        static let recentColors = "arbor.recentColors"
    }
}
