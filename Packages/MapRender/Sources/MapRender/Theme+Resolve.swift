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

    // One wide switch over the patch's fields, by design (mirrors the
    // command dispatchers): field order is the doc-comment order.
    // swiftlint:disable cyclomatic_complexity
    /// The F-STY-3 per-node override seam: folds a node's stored
    /// `NodeStylePatch` into an already theme-resolved style — after the
    /// level style and the branch color — for every patch field that
    /// addresses the node itself (shape, fill/none, border, corner
    /// radius, padding, shadow, typography, text color/alignment,
    /// min/max width). The branch fields (`branchColor`, `branchWidth`,
    /// `branchTaper`, `branchLineStyle`) do **not** land here: they
    /// override the one connector drawn from the node's *parent* to the
    /// node (ADR-0011), which `SceneGeometry` resolves while building
    /// branch connectors.
    ///
    /// Unknown values (bad hexes, unrecognized alignment/line-style
    /// strings) are ignored one field at a time — an override can never
    /// take the style invalid; the theme's value stands.
    ///
    /// Fast path: `nil` (the overwhelming majority of nodes) returns
    /// immediately — the BuildCaches memoization never pays for nodes
    /// without overrides.
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
                maxWidth: CGFloat(levelStyle.maxWidth)),
            variant: variant)
    }

    /// The palette color at `level1Index`, wrapped around the palette.
    private func paletteColor(level1Index: Int, in scheme: ThemeScheme) -> CGColor {
        let count = max(scheme.palette.count, 1)
        let index = ((level1Index % count) + count) % count
        let raw = scheme.palette[index]
        return ThemeHex.color(raw)
            ?? PaperTheme.color(fromHex: PaperTheme.paletteHexes[index % PaperTheme.paletteHexes.count])
    }
}
