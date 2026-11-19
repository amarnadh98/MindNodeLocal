import AppKit
import MapCore
import MapRender
import MapStudy

/// Small shared helpers for the study UI (F-STD-4): the document theme's
/// typography at study sizes (§7.5: nothing renders under 18 pt) and the
/// breadcrumb path of a card's node.
@MainActor
enum StudyTheme {
    /// The document's resolved theme at a variant.
    static func theme(for model: MapModel, variant: ThemeVariant) -> Theme {
        BuiltInThemes.theme(id: model.theme?.id ?? BuiltInThemes.defaultID)
    }

    /// `NSFont` for a theme `FontSpec` (the study sibling of the editing
    /// overlay's converter — same constants, App-side so the session and
    /// dashboard don't reach into CanvasKit internals).
    static func nsFont(for spec: FontSpec) -> NSFont {
        if spec.monospace {
            return NSFont(name: "Menlo-Regular", size: spec.size) ?? NSFont.systemFont(ofSize: spec.size)
        }
        if let family = spec.family {
            return NSFont(name: family, size: spec.size) ?? NSFont.systemFont(ofSize: spec.size)
        }
        let base = NSFont.systemFont(ofSize: spec.size, weight: NSFont.Weight(rawValue: spec.weight))
        guard spec.italic else { return base }
        let traits = base.fontDescriptor.symbolicTraits.union(.italic)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 0) ?? base
    }

    /// The front side's font: the theme's level-1 style scaled up for
    /// study (at least 24 pt), answer lines at ≥ 18 pt (§7.5).
    static func frontFont(theme: Theme, variant: ThemeVariant) -> NSFont {
        let spec = theme.resolvedStyle(level: 1, level1Index: 0, variant: variant).font
        return nsFont(
            for: FontSpec(
                size: max(spec.size * 1.5, 24), weight: spec.weight, family: spec.family, italic: spec.italic,
                monospace: spec.monospace))
    }

    /// The answer lines' font (theme level-2 style at ≥ 18 pt).
    static func answerFont(theme: Theme, variant: ThemeVariant) -> NSFont {
        let spec = theme.resolvedStyle(level: 2, level1Index: 0, variant: variant).font
        return nsFont(
            for: FontSpec(
                size: max(spec.size * 1.2, 18), weight: spec.weight, family: spec.family, italic: spec.italic,
                monospace: spec.monospace))
    }

    /// The card text color for the variant.
    static func textColor(theme: Theme, variant: ThemeVariant) -> NSColor {
        let style = theme.resolvedStyle(level: 1, level1Index: 0, variant: variant)
        return NSColor(cgColor: style.textColor) ?? .labelColor
    }

    /// The canvas color for the variant (the session window's background).
    static func canvasColor(theme: Theme, variant: ThemeVariant) -> NSColor {
        NSColor(cgColor: theme.canvasColor(for: variant)) ?? .windowBackgroundColor
    }

    /// The ancestor-path breadcrumb of `nodeID` ("Biology › Cell"),
    /// F-STD-1's front-side context, for the label above the card.
    static func breadcrumb(of nodeID: String, in model: MapModel) -> [String] {
        var titles: [String] = []
        var current = model.nodes[nodeID]?.parent
        while let id = current {
            titles.insert(model.nodes[id]?.title.text ?? "", at: 0)
            current = model.nodes[id]?.parent
        }
        return titles.filter { !$0.isEmpty }
    }
}

/// Study settings the Settings ▸ Study tab will own (F-STD-4 daily
/// limits; SPEC §5.20). For now they read from UserDefaults with the
/// document's `studySettings` as the document-level default, so a
/// power user can `defaults write` them today and the settings UI lands
/// on the same keys.
enum StudyPreferences {
    static let newPerDayKey = "StudyNewPerDay"
    static let reviewsPerDayKey = "StudyReviewsPerDay"
    /// The reminder opt-in (F-STD-7): off until the user asks.
    static let dailyReminderKey = "StudyDailyReminderEnabled"

    /// New cards per day: a UserDefaults override wins, else the
    /// document's `studySettings.newPerDay`, else 20 (F-STD-4 default).
    static func newPerDay(model: MapModel, defaults: UserDefaults = .standard) -> Int {
        if let stored = defaults.object(forKey: newPerDayKey) as? Int {
            return max(0, stored)
        }
        return max(0, model.studySettings?.newPerDay ?? 20)
    }

    /// Reviews per day: UserDefaults override, else 200 (F-STD-4 default).
    static func reviewsPerDay(defaults: UserDefaults = .standard) -> Int {
        if let stored = defaults.object(forKey: reviewsPerDayKey) as? Int {
            return max(0, stored)
        }
        return StudyQueue.defaultReviewsPerDay
    }
}
