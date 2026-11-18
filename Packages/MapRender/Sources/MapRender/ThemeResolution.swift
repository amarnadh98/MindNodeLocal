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
    /// order; descendants inherit it (F-STY-8). The dark variant raises
    /// each hue's lightness by 8% (SPEC §7.2: "same hues, adjusted for
    /// contrast ≥ 4.5:1").
    public static func branchColor(level1Index: Int, variant: ThemeVariant) -> CGColor {
        let index = ((level1Index % paletteHexes.count) + paletteHexes.count) % paletteHexes.count
        let base = color(fromHex: paletteHexes[index])
        guard variant == .dark else { return base }
        return adjustedLightness(base, boost: 0.08) ?? base
    }

    /// A branch palette color with the alpha the theme uses for node fills
    /// (16% light, 24% dark — SPEC §7.2).
    public static func nodeFillColor(
        level1Index: Int, variant: ThemeVariant
    ) -> CGColor {
        let alpha: CGFloat = variant == .light ? 0.16 : 0.24
        let base = branchColor(level1Index: level1Index, variant: variant)
        return base.copy(alpha: alpha) ?? base
    }

    /// Shadow layers per SPEC §7.2: raised is two layers (y 1, blur 3,
    /// black 8% + y 4, blur 12, black 6%); the dark column compresses the
    /// description to "black 40%".
    public static func shadowLayers(for variant: ThemeVariant) -> [ShadowLayer] {
        switch variant {
        case .light:
            return [
                ShadowLayer(offsetY: 1, blur: 3, color: CGColor(gray: 0, alpha: 0.08)),
                ShadowLayer(offsetY: 4, blur: 12, color: CGColor(gray: 0, alpha: 0.06)),
            ]
        case .dark:
            return [ShadowLayer(offsetY: 4, blur: 12, color: CGColor(gray: 0, alpha: 0.40))]
        }
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
                shadows: shadowLayers(for: variant),
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
                borderColor: branchColor(level1Index: level1Index, variant: variant),
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

    /// HSL lightness adjustment, applied channel-wise through a full
    /// RGB → HSL → RGB round trip so hues and saturations stay exact.
    private static func adjustedLightness(_ color: CGColor, boost: CGFloat) -> CGColor? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let red = components[0]
        let green = components[1]
        let blue = components[2]
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        let lightness = (maxChannel + minChannel) / 2
        let delta = maxChannel - minChannel
        guard delta > 0, lightness > 0 else {
            let scaled = min(1, lightness * (1 + boost))
            return CGColor(
                srgbRed: scaled, green: scaled, blue: scaled, alpha: color.alpha)
        }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: CGFloat
        if maxChannel == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxChannel == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }

        let boosted = min(1, lightness * (1 + boost))
        let chroma = (1 - abs(2 * boosted - 1)) * saturation
        let sector = hue / 60
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let channels = hslSectorChannels(sector, chroma: chroma, secondary: secondary)
        let lift = boosted - chroma / 2
        return CGColor(
            srgbRed: channels.red + lift, green: channels.green + lift,
            blue: channels.blue + lift, alpha: color.alpha)
    }

    private struct ChannelRGB {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }

    private static func hslSectorChannels(
        _ sector: CGFloat, chroma: CGFloat, secondary: CGFloat
    ) -> ChannelRGB {
        switch sector {
        case ..<1: return ChannelRGB(red: chroma, green: secondary, blue: 0)
        case ..<2: return ChannelRGB(red: secondary, green: chroma, blue: 0)
        case ..<3: return ChannelRGB(red: 0, green: chroma, blue: secondary)
        case ..<4: return ChannelRGB(red: 0, green: secondary, blue: chroma)
        case ..<5: return ChannelRGB(red: secondary, green: 0, blue: chroma)
        default: return ChannelRGB(red: chroma, green: 0, blue: secondary)
        }
    }
}
