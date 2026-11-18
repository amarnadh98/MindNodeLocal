import CoreGraphics
import Foundation
import MapCore

/// Paper theme appearance (SPEC §7.2 light/dark token columns).
public enum ThemeVariant: Sendable, Hashable {
    case light
    case dark
}

/// Level styles resolved from the Paper theme (SPEC §7.2): root is a dark
/// rounded rectangle with white text; level 1 tints the branch palette
/// color at 16% (light) / 24% (dark); level 2+ is text on an underline in
/// the branch color. Level-1 branches take palette colors by index
/// (F-STY-8).
extension PaperTheme {
    /// Root text color (white on the dark root fill; near-black in dark
    /// mode on the light root fill).
    public static func rootTextColor(for variant: ThemeVariant) -> CGColor {
        let hex: UInt32 = variant == .light ? 0xFFFFFF : 0x1C1C1E
        return color(fromHex: hex)
    }

    /// Body text color.
    public static func textColor(for variant: ThemeVariant) -> CGColor {
        let hex: UInt32 = variant == .light ? 0x1C1C1E : 0xF2F2F7
        return color(fromHex: hex)
    }

    /// The branch color for the level-1 branch at `index` in creation
    /// order; descendants inherit it (F-STY-8).
    public static func branchColor(level1Index: Int) -> CGColor {
        let index = ((level1Index % paletteHexes.count) + paletteHexes.count) % paletteHexes.count
        return color(fromHex: paletteHexes[index])
    }

    /// A branch palette color with the alpha the theme uses for node fills
    /// (16% light, 24% dark — SPEC §7.2).
    public static func nodeFillColor(
        level1Index: Int, variant: ThemeVariant
    ) -> CGColor {
        let alpha: CGFloat = variant == .light ? 0.16 : 0.24
        return branchColor(level1Index: level1Index).copy(alpha: alpha)
            ?? branchColor(level1Index: level1Index)
    }

    /// Resolves the style for a node at `level` on the branch whose
    /// level-1 ancestor has palette index `level1Index`.
    public static func resolvedStyle(
        level: Int, level1Index: Int, variant: ThemeVariant
    ) -> ResolvedNodeStyle {
        let typography = ThemeTypography()
        switch level {
        case 0:
            let fill: UInt32 = variant == .light ? rootFillLightHex : rootFillDarkHex
            return ResolvedNodeStyle(
                shape: .roundedRect,
                fillColor: color(fromHex: fill),
                cornerRadius: 10,
                paddingWidth: 16,
                paddingHeight: 10,
                textColor: rootTextColor(for: variant),
                font: typography.root,
                shadow: .raised,
                maxWidth: 280
            )
        case 1:
            return ResolvedNodeStyle(
                shape: .roundedRect,
                fillColor: nodeFillColor(level1Index: level1Index, variant: variant),
                cornerRadius: 10,
                paddingWidth: 16,
                paddingHeight: 10,
                textColor: textColor(for: variant),
                font: typography.level1,
                maxWidth: 280
            )
        default:
            return ResolvedNodeStyle(
                shape: .underline,
                fillColor: nil,
                borderColor: branchColor(level1Index: level1Index),
                paddingWidth: 2,
                paddingHeight: 2,
                textColor: textColor(for: variant),
                font: typography.level2Plus,
                underlineWidth: 2,
                maxWidth: 280
            )
        }
    }

    /// Tapered branch widths (§7.2): 6 pt at the root down to 2 pt at the
    /// leaves.
    public static func branchWidths(level: Int) -> (start: CGFloat, end: CGFloat) {
        let start: CGFloat = max(2, 6 - CGFloat(level))
        return (start: start, end: 2)
    }
}
