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

    /// The F-STY-3 per-node override seam. The inspector's stored
    /// `NodeStylePatch` folds in here — after the level style and the
    /// branch color — in the inspector slice; until then resolution is
    /// purely theme → level style → branch color and the patch has no
    /// effect.
    public func applyingOverrides(_ overrides: NodeStylePatch?, to style: ResolvedNodeStyle) -> ResolvedNodeStyle {
        _ = overrides
        return style
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
                maxWidth: CGFloat(levelStyle.maxWidth)))
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
