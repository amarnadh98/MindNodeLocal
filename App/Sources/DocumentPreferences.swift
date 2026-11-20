import Foundation
import MapLayout

/// App-level (not per-document) preferences (F-STY-6, F-LAY-12): the
/// default theme for new documents, the inspector's visibility, the
/// recent-color list the color pickers offer (F-STY-7) and the layout
/// spacing rhythm every document lays out at. All UserDefaults-backed;
/// `UserDefaults` is MainActor-bound in Swift 6, so every accessor is.
@MainActor
enum DocumentPreferences {
    private static let suite = UserDefaults.standard

    /// The theme a brand-new document opens with. One stored value,
    /// shared with Settings ▸ General (`ThemeCatalog.defaultThemeID`).
    static var defaultThemeID: String {
        get { ThemeCatalog.defaultThemeID }
        set { ThemeCatalog.defaultThemeID = newValue }
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

    // MARK: layout spacing (F-LAY-12)

    /// SPEC §6.3: the contextual floating bar can be disabled; the
    /// inspector's Canvas pane writes this key.
    static let contextualBarKey = "arbor.showsContextualBar"

    /// The spacing preset index: 0 narrow, 1 default, 2 wide. Custom
    /// gaps (below) override the preset's corresponding value when
    /// set.
    static var spacingPreset: Int {
        get {
            guard let raw = suite.object(forKey: Keys.spacingPreset) as? Int else { return 1 }
            return min(max(raw, 0), 2)
        }
        set { suite.set(newValue, forKey: Keys.spacingPreset) }
    }

    /// A custom sibling gap, or nil to use the preset's.
    static var customSiblingGap: Double? {
        get {
            suite.object(forKey: Keys.siblingGap) == nil
                ? nil
                : suite.double(forKey: Keys.siblingGap)
        }
        set {
            if let value = newValue {
                suite.set(value, forKey: Keys.siblingGap)
            } else {
                suite.removeObject(forKey: Keys.siblingGap)
            }
        }
    }

    /// A custom level gap, or nil to use the preset's.
    static var customLevelGap: Double? {
        get {
            suite.object(forKey: Keys.levelGap) == nil
                ? nil
                : suite.double(forKey: Keys.levelGap)
        }
        set {
            if let value = newValue {
                suite.set(value, forKey: Keys.levelGap)
            } else {
                suite.removeObject(forKey: Keys.levelGap)
            }
        }
    }

    /// The effective spacing (F-LAY-12: preset ×0.7/×1/×1.4 of §7.3,
    /// then the custom gaps where set). A custom level gap applies to
    /// every parent→children step — the root's own gap included
    /// ("level gap" is what the slider says, not the engine's split
    /// between root and lower levels).
    static var layoutSpacing: LayoutSpacing {
        let preset: LayoutSpacing
        switch spacingPreset {
        case 0: preset = .narrow
        case 2: preset = .wide
        default: preset = .default
        }
        return LayoutSpacing(
            levelGap: CGFloat(customLevelGap ?? Double(preset.levelGap)),
            siblingGap: CGFloat(customSiblingGap ?? Double(preset.siblingGap)),
            subtreeGap: preset.subtreeGap,
            rootGap: CGFloat(customLevelGap ?? Double(preset.rootGap)))
    }

    private enum Keys {
        static let inspectorVisible = "arbor.inspectorVisible"
        static let recentColors = "arbor.recentColors"
        static let spacingPreset = "arbor.spacingPreset"
        static let siblingGap = "arbor.siblingGap"
        static let levelGap = "arbor.levelGap"
    }
}
