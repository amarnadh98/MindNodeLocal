import CoreGraphics
import Foundation
import MapCore

extension Theme {
    /// The scheme for one appearance variant (F-STY-4: themes are dynamic).
    public func scheme(for variant: ThemeVariant) -> ThemeScheme {
        variant == .light ? light : dark
    }

    /// The canvas background color.
    public func canvasColor(for variant: ThemeVariant) -> CGColor {
        ThemeHex.color(scheme(for: variant).canvasColor)
            ?? PaperTheme.color(
                fromHex: variant == .light ? PaperTheme.canvasLightHex : PaperTheme.canvasDarkHex)
    }

    /// The palette index a branch actually uses (F-STY-8): the stored
    /// index when rainbow branches are on, palette color 0 for every
    /// branch when they are off.
    public func effectivePaletteIndex(_ level1Index: Int) -> Int {
        rainbowBranches ? level1Index : 0
    }

    /// The branch color for the level-1 branch at `level1Index` in
    /// creation order; descendants inherit it (F-STY-3). Indices wrap
    /// around the palette.
    public func branchColor(level1Index: Int, variant: ThemeVariant) -> CGColor {
        paletteColor(level1Index: level1Index, in: scheme(for: variant))
    }

    /// Width of a branch leaving a node at `level`: tapered styles fall
    /// from `startWidth` at the root to `endWidth` at the leaves; every
    /// other line style draws the constant `startWidth`.
    public func branchWidth(level: Int) -> CGFloat {
        let branchStyle = branch
        guard branchStyle.lineStyle == .tapered else { return CGFloat(branchStyle.startWidth) }
        return max(CGFloat(branchStyle.endWidth), CGFloat(branchStyle.startWidth) - CGFloat(level))
    }

    /// The F-STY-3 per-node override seam: folds a node's stored
    /// `NodeStylePatch` into an already theme-resolved style — after the
    /// level style and the branch color — for every patch field that
    /// addresses the node itself (shape, fill/none, border, corner
    /// radius, padding, shadow, typography, text color/alignment,
    /// min/max width). The branch fields (`branchColor`, `branchWidth`,
    /// `branchTaper`, `branchLineStyle`) do **not** land here: they
    /// override the one connector drawn from the node's *parent* to the
    /// node (ADR-0028), which `SceneGeometry` resolves while building
    /// branch connectors.
    ///
    /// Unknown values (bad hexes, unrecognized alignment strings) are
    /// ignored one field at a time — an override can never take the
    /// style invalid; the theme's value stands.
    ///
    /// Fast path: `nil` (the overwhelming majority of nodes) returns
    /// immediately — the `BuildCaches` memoization never pays for nodes
    /// without overrides.
    // One wide switch over the patch's fields, by design (mirrors the
    // command dispatchers).
    // swiftlint:disable cyclomatic_complexity
    public func applyingOverrides(
        _ overrides: NodeStylePatch?, to style: ResolvedNodeStyle, variant: ThemeVariant
    ) -> ResolvedNodeStyle {
        guard let overrides, !overrides.isEmpty else { return style }
        var resolved = style

        if let shape = overrides.shape {
            resolved.shape = shape
        }
        if let fill = overrides.fill {
            switch fill.lowercased() {
            case "none":
                resolved.fillColor = nil
            default:
                resolved.fillColor = ThemeHex.color(fill) ?? resolved.fillColor
            }
        }
        if let borderColor = overrides.borderColor {
            resolved.borderColor = ThemeHex.color(borderColor) ?? resolved.borderColor
        }
        if let borderWidth = overrides.borderWidth {
            resolved.borderWidth = CGFloat(borderWidth)
        }
        if let borderDash = overrides.borderDash {
            resolved.borderDash = borderDash
        }
        if overrides.shape != nil {
            // The border follows the shape's drawing mode (§7.2): an
            // underline shape draws the border AS the underline, and
            // leaving underline turns it back into a stroke.
            if resolved.shape == .underline {
                resolved.underlineWidth = max(resolved.underlineWidth, resolved.borderWidth)
                resolved.borderWidth = 0
            } else if resolved.underlineWidth > 0, resolved.borderWidth == 0 {
                resolved.borderWidth = resolved.underlineWidth
                resolved.underlineWidth = 0
            }
        }
        if let cornerRadius = overrides.cornerRadius {
            resolved.cornerRadius = CGFloat(cornerRadius)
        }
        if let padding = overrides.padding {
            resolved.paddingWidth = CGFloat(padding)
            resolved.paddingHeight = CGFloat(padding)
        }
        if let shadow = overrides.shadow {
            resolved.shadows = Self.overrideShadowLayers(shadow, variant: variant)
        }
        if let fontName = overrides.fontName {
            // An explicit family wins; the empty string returns to the
            // theme's system family.
            resolved.font = FontSpec(
                size: resolved.font.size, weight: resolved.font.weight,
                family: fontName.isEmpty ? nil : fontName,
                italic: resolved.font.italic, monospace: resolved.font.monospace)
        }
        if let fontSize = overrides.fontSize {
            resolved.font = FontSpec(
                size: CGFloat(fontSize), weight: resolved.font.weight,
                family: resolved.font.family,
                italic: resolved.font.italic, monospace: resolved.font.monospace)
        }
        if let fontWeight = overrides.fontWeight {
            resolved.font = FontSpec(
                size: resolved.font.size, weight: CGFloat(fontWeight),
                family: resolved.font.family,
                italic: resolved.font.italic, monospace: resolved.font.monospace)
        }
        if let fontItalic = overrides.fontItalic {
            resolved.font = FontSpec(
                size: resolved.font.size, weight: resolved.font.weight,
                family: resolved.font.family,
                italic: fontItalic, monospace: resolved.font.monospace)
        }
        if let textColor = overrides.textColor {
            resolved.textColor = ThemeHex.color(textColor) ?? resolved.textColor
        }
        if let alignment = overrides.alignment {
            switch alignment.lowercased() {
            case "left": resolved.textAlignment = .leading
            case "right": resolved.textAlignment = .trailing
            case "center": resolved.textAlignment = .center
            default: break
            }
        }
        if let minWidth = overrides.minWidth {
            resolved.minWidth = CGFloat(minWidth)
        }
        if let maxWidth = overrides.maxWidth {
            resolved.maxWidth = CGFloat(maxWidth)
        }
        return resolved
    }

    // swiftlint:enable cyclomatic_complexity

    /// F-STY-2 shadow presets at the current appearance, mirroring §7.2's
    /// reference definitions: raised is two layers in light / one
    /// compressed layer in dark; soft is a single close layer.
    private static func overrideShadowLayers(
        _ shadow: ShadowStyle, variant: ThemeVariant
    ) -> [ShadowLayer] {
        let black = { (alpha: CGFloat) -> CGColor in
            CGColor(gray: 0, alpha: alpha)
        }
        switch shadow {
        case .none:
            return []
        case .soft:
            return [ShadowLayer(offsetY: 2, blur: 6, color: black(variant == .light ? 0.10 : 0.30))]
        case .raised:
            return variant == .light
                ? [
                    ShadowLayer(offsetY: 1, blur: 3, color: black(0.08)),
                    ShadowLayer(offsetY: 4, blur: 12, color: black(0.06)),
                ]
                : [ShadowLayer(offsetY: 4, blur: 12, color: black(0.40))]
        }
    }

    /// Resolves the style for a node at `level` on the branch whose
    /// level-1 ancestor has palette index `level1Index` (F-STY-3):
    /// theme → level style → branch color → (per-node overrides via
    /// `applyingOverrides`, a later slice).
    public func resolvedStyle(
        level: Int,
        level1Index: Int,
        variant: ThemeVariant,
        overrides: NodeStylePatch? = nil
    ) -> ResolvedNodeStyle {
        let scheme = scheme(for: variant)
        let levelStyle = scheme.levels.style(forLevel: level)
        let branchColor = paletteColor(level1Index: level1Index, in: scheme)
        let textColor = ThemeHex.color(levelStyle.textColor) ?? PaperTheme.color(fromHex: 0x1C1C1E)

        let fillColor: CGColor?
        switch levelStyle.fill {
        case .none:
            fillColor = nil
        case .solid(let hex):
            fillColor = ThemeHex.color(hex)
        case .palette(let alpha):
            fillColor = branchColor.copy(alpha: CGFloat(alpha)) ?? branchColor
        }

        var borderColor: CGColor?
        var borderWidth: CGFloat = 0
        var underlineWidth: CGFloat = 0
        if let border = levelStyle.border {
            switch border.paint {
            case .solid(let hex):
                borderColor = ThemeHex.color(hex)
            case .palette:
                borderColor = branchColor
            }
            // Underline shapes draw the border as the underline itself
            // (SPEC §7.2); other shapes stroke it around the shape.
            if levelStyle.shape == .underline {
                underlineWidth = CGFloat(border.width)
            } else {
                borderWidth = CGFloat(border.width)
            }
        }

        let shadows = levelStyle.shadow.map { layer -> ShadowLayer in
            let base = ThemeHex.color(layer.color) ?? CGColor(gray: 0, alpha: 1)
            let color =
                base.copy(alpha: CGFloat(layer.alpha))
                ?? CGColor(gray: 0, alpha: CGFloat(layer.alpha))
            return ShadowLayer(offsetY: CGFloat(layer.offsetY), blur: CGFloat(layer.blur), color: color)
        }

        let font = levelStyle.font
        return applyingOverrides(
            overrides,
            to: ResolvedNodeStyle(
                shape: levelStyle.shape,
                fillColor: fillColor,
                borderColor: borderColor,
                borderWidth: borderWidth,
                cornerRadius: CGFloat(levelStyle.cornerRadius),
                paddingWidth: CGFloat(levelStyle.paddingWidth),
                paddingHeight: CGFloat(levelStyle.paddingHeight),
                textColor: textColor,
                font: FontSpec(
                    size: CGFloat(font.size),
                    weight: CGFloat(font.weight),
                    family: font.family,
                    italic: font.italic,
                    monospace: font.monospace),
                underlineWidth: underlineWidth,
                shadows: shadows,
                minWidth: CGFloat(levelStyle.minWidth ?? 0),
                maxWidth: CGFloat(levelStyle.maxWidth)),
            variant: variant)
    }

    /// The document's stored theme overrides (SPEC §8.2
    /// `theme.overrides`, F-STY-8): a derived theme value with the
    /// stored canvas color(s), palette, base font family and rainbow
    /// toggle replacing the built-in's. Unknown canvas hexes and an
    /// empty palette fall back to the theme's own values, one field at
    /// a time; `nil` (or an empty patch) returns the theme itself.
    public func applyingDocumentOverrides(_ patch: ThemePatch?) -> Theme {
        guard let patch else { return self }
        var theme = self
        if patch.rainbowBranches != nil {
            theme.rainbowBranches = patch.rainbowBranches ?? theme.rainbowBranches
        }
        if let canvasColor = patch.canvasColor, ThemeHex.color(canvasColor) != nil {
            theme.light.canvasColor = canvasColor
            theme.dark.canvasColor = canvasColor
        }
        if let paletteColors = patch.paletteColors, !paletteColors.isEmpty {
            let valid = paletteColors.filter { ThemeHex.color($0) != nil }
            if !valid.isEmpty {
                theme.light.palette = valid
                theme.dark.palette = valid
            }
        }
        if let baseFont = patch.baseFont, !baseFont.isEmpty {
            theme.light.levels.root.font.family = baseFont
            theme.light.levels.level1.font.family = baseFont
            theme.light.levels.level2.font.family = baseFont
            theme.light.levels.level3Plus.font.family = baseFont
            theme.dark.levels.root.font.family = baseFont
            theme.dark.levels.level1.font.family = baseFont
            theme.dark.levels.level2.font.family = baseFont
            theme.dark.levels.level3Plus.font.family = baseFont
        }
        return theme
    }

    /// The palette color at `level1Index`, wrapped around the palette.
    private func paletteColor(level1Index: Int, in scheme: ThemeScheme) -> CGColor {
        let count = max(scheme.palette.count, 1)
        let index = ((level1Index % count) + count) % count
        let raw = scheme.palette[index]
        return ThemeHex.color(raw)
            ?? PaperTheme.color(fromHex: PaperTheme.paletteHexes[index % PaperTheme.paletteHexes.count])
    }

    /// A connection's resolved style (F-REL-1): the theme's connection
    /// placeholder (§7.2: 1.5 pt, dashed, arrow at the end) with the
    /// document's per-connection overrides folded over it. `nil` style
    /// fields keep the theme default.
    public func resolvedConnectionStyle(
        variant: ThemeVariant, overrides: ConnectionStyle? = nil
    ) -> ResolvedConnectionStyle {
        let base = connection
        var resolved = ResolvedConnectionStyle(
            color: ThemeHex.color(base.color)
                ?? PaperTheme.color(fromHex: 0x8E8E93),
            width: CGFloat(base.width),
            dash: base.dash,
            arrowheads: base.arrowEnd ? .end : .none,
            lineStyle: .curve)
        if let overrides {
            resolved.apply(overrides)
        }
        return resolved
    }

    /// A boundary's resolved style (F-REL-2): the theme placeholder
    /// (§7.2: 1 pt stroke at 60%, tinted fill, 16 pt radius, 14 pt
    /// padding) with the boundary's stored style folded over it. A
    /// boundary reuses `ConnectionStyle` on disk; its `lineStyle`
    /// selects the outline shape (`.curve` = organic, §5.5 F-REL-2).
    public func resolvedBoundaryStyle(
        variant: ThemeVariant, overrides: ConnectionStyle? = nil
    ) -> ResolvedBoundaryStyle {
        let base = boundary
        let stroke = ThemeHex.color(base.strokeColor) ?? PaperTheme.color(fromHex: 0x8E8E93)
        let tint = ThemeHex.color(base.fillColor) ?? stroke
        var resolved = ResolvedBoundaryStyle(
            stroke: stroke.copy(alpha: 0.6) ?? stroke,
            fill: tint.copy(alpha: 0.10) ?? tint,
            lineWidth: 1,
            dash: false,
            cornerRadius: CGFloat(base.cornerRadius),
            padding: CGFloat(base.padding),
            organic: false)
        if let overrides {
            resolved.apply(overrides)
        }
        return resolved
    }
}

/// A connection's flattened style after theme + per-connection
/// overrides (F-REL-1). Render types carry `CGColor`; not `Sendable`.
public struct ResolvedConnectionStyle {
    public var color: CGColor
    public var width: CGFloat
    public var dash: Bool
    public var arrowheads: Arrowheads
    public var lineStyle: ConnectionLineStyle

    public init(
        color: CGColor, width: CGFloat, dash: Bool, arrowheads: Arrowheads,
        lineStyle: ConnectionLineStyle
    ) {
        self.color = color
        self.width = width
        self.dash = dash
        self.arrowheads = arrowheads
        self.lineStyle = lineStyle
    }

    /// Folds a stored `ConnectionStyle` (only the non-nil fields) over
    /// this style.
    public mutating func apply(_ overrides: ConnectionStyle) {
        if let hex = overrides.color, let color = ThemeHex.color(hex) {
            self.color = color
        }
        if let width = overrides.width {
            self.width = CGFloat(width)
        }
        if let dash = overrides.dash {
            self.dash = dash
        }
        if let arrowheads = overrides.arrowheads {
            self.arrowheads = arrowheads
        }
        if let lineStyle = overrides.lineStyle {
            self.lineStyle = lineStyle
        }
    }
}

/// A boundary's flattened style after theme + per-boundary overrides
/// (F-REL-2).
public struct ResolvedBoundaryStyle {
    public var stroke: CGColor
    public var fill: CGColor
    public var lineWidth: CGFloat
    public var dash: Bool
    public var cornerRadius: CGFloat
    public var padding: CGFloat
    /// `true` draws the smoothed hull instead of the rounded rect.
    public var organic: Bool

    public init(
        stroke: CGColor, fill: CGColor, lineWidth: CGFloat, dash: Bool,
        cornerRadius: CGFloat, padding: CGFloat, organic: Bool
    ) {
        self.stroke = stroke
        self.fill = fill
        self.lineWidth = lineWidth
        self.dash = dash
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.organic = organic
    }

    /// Folds a stored boundary style over this style. The reused
    /// `ConnectionStyle.lineStyle` carries the outline shape:
    /// `.curve` = organic (F-REL-2), `.straight`/nil = rounded.
    public mutating func apply(_ overrides: ConnectionStyle) {
        if let hex = overrides.color, let color = ThemeHex.color(hex) {
            // §7.2's alphas are part of the boundary look, not the
            // color: an override recolors but keeps 60% stroke / 10%
            // fill.
            stroke = color.copy(alpha: 0.6) ?? color
            fill = color.copy(alpha: 0.10) ?? color
        }
        if let width = overrides.width {
            lineWidth = CGFloat(width)
        }
        if let dash = overrides.dash {
            self.dash = dash
        }
        if let lineStyle = overrides.lineStyle {
            organic = lineStyle == .curve
        }
    }
}
