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
