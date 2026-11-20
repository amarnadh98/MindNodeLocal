import Foundation
import MapCore

/// The twelve built-in themes (SPEC §5.8, names are ours), each with a
/// light and a dark scheme. Shipped as Swift literals rather than JSON
/// resources so the data is compile-time checked and loads with zero I/O
/// (ADR-0009); the `.arbortheme` JSON contract is the same `Theme`
/// `Codable` schema, proven by the round-trip tests, and the theme
/// editor slice (F-STY-5) will use it for import/export.
public enum BuiltInThemes {
    /// The engine's fallback theme id (SPEC §5.8 theme list, F-STY-6): what
    /// a document with no theme selection, and an unknown id, resolve to.
    public static let defaultID = "paper"

    /// The theme a NEW map starts with, unless the user picks another in
    /// Settings (the app's `ThemeCatalog.defaultThemeID`).
    public static let newDocumentDefaultID = "studio"

    /// The themes in the SPEC §5.8 order.
    public static let all: [Theme] = [
        studio, paper, graphite, pastel, ocean, forest, sunset,
        monoInk, chalkboard, neon, blueprint, sakura, study,
    ]

    /// The theme with `id`, or the default theme for an unknown id.
    public static func theme(id: String) -> Theme {
        all.first { $0.id == id } ?? theme(id: defaultID)
    }

    // MARK: builders (data-only helpers; every value below is theme data)

    static func font(
        _ size: Double, _ weight: Double = 0.0, family: String? = nil,
        italic: Bool = false, monospace: Bool = false
    ) -> ThemeFont {
        ThemeFont(size: size, weight: weight, family: family, italic: italic, monospace: monospace)
    }

    static func level(
        _ shape: NodeShape,
        fill: ThemeFill,
        border: ThemeBorder? = nil,
        radius: Double = 10,
        padWidth: Double = 16,
        padHeight: Double = 10,
        shadow: [ThemeShadowLayer] = [],
        font: ThemeFont,
        text: String,
        maxWidth: Double = 280,
        minWidth: Double? = nil
    ) -> ThemeLevelStyle {
        ThemeLevelStyle(
            shape: shape, fill: fill, border: border, cornerRadius: radius,
            paddingWidth: padWidth, paddingHeight: padHeight, shadow: shadow,
            font: font, textColor: text, maxWidth: maxWidth, minWidth: minWidth)
    }

    static func levels(
        root: ThemeLevelStyle, one: ThemeLevelStyle,
        two: ThemeLevelStyle, threePlus: ThemeLevelStyle? = nil
    ) -> ThemeLevels {
        ThemeLevels(root: root, level1: one, level2: two, level3Plus: threePlus ?? two)
    }

    static let raisedLightShadow: [ThemeShadowLayer] = [
        ThemeShadowLayer(offsetY: 1, blur: 3, color: "#000000", alpha: 0.08),
        ThemeShadowLayer(offsetY: 4, blur: 12, color: "#000000", alpha: 0.06),
    ]

    static let raisedDarkShadow: [ThemeShadowLayer] = [
        ThemeShadowLayer(offsetY: 4, blur: 12, color: "#000000", alpha: 0.40)
    ]

    static let softLightShadow: [ThemeShadowLayer] = [
        ThemeShadowLayer(offsetY: 2, blur: 6, color: "#000000", alpha: 0.10)
    ]

    static func connection(_ color: String) -> ThemeConnectionStyle {
        ThemeConnectionStyle(color: color, width: 1.5, dash: true, arrowEnd: true)
    }

    /// The boundary placeholder: a neutral stroke, consumed by the
    /// boundary drawing slice (F-REL-3).
    static func boundary(_ color: String) -> ThemeBoundaryStyle {
        ThemeBoundaryStyle(strokeColor: color, fillColor: color, cornerRadius: 16, padding: 14)
    }
}
