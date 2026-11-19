import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// WCAG AA (SPEC §5.8): every level style's text must hold a contrast
/// ratio of at least 4.5:1 against the background it actually sits on —
/// its fill composited over the canvas (palette-tinted fills composite
/// over the canvas color; underline nodes sit on the canvas itself).
/// Both appearance variants; palette-tinted fills are checked against
/// **every** palette entry, since a branch's fill follows its index.
struct ThemeContrastTests {
    @Test func everyLevelStyleHoldsWCAGAATextContrast() throws {
        for theme in BuiltInThemes.all {
            for variant in [ThemeVariant.light, .dark] {
                let scheme = theme.scheme(for: variant)
                let canvas = try #require(SRGBColor.parse(scheme.canvasColor))
                let levels = [
                    scheme.levels.root, scheme.levels.level1,
                    scheme.levels.level2, scheme.levels.level3Plus,
                ]
                for levelStyle in levels {
                    let text = try #require(SRGBColor.parse(levelStyle.textColor))
                    for background in try effectiveBackground(of: levelStyle, scheme: scheme, canvas: canvas) {
                        let ratio = text.contrastRatio(with: background)
                        let detail = String(format: "%.2f", ratio)
                        #expect(
                            ratio >= 4.5,
                            "\(theme.id)/\(variant) text \(levelStyle.textColor) on \(background.hex) is \(detail):1")
                    }
                }
            }
        }
    }

    /// The backgrounds the level style's text actually renders against:
    /// the canvas for transparent fills, the solid fill, or the palette
    /// tint composited over the canvas for every palette entry.
    private func effectiveBackground(
        of levelStyle: ThemeLevelStyle, scheme: ThemeScheme, canvas: SRGBColor
    ) throws -> [SRGBColor] {
        switch levelStyle.fill {
        case .none:
            return [canvas]
        case .solid(let raw):
            return [try #require(SRGBColor.parse(raw))]
        case .palette(let alpha):
            return try scheme.palette.map {
                try #require(SRGBColor.parse($0)).composited(over: canvas, alpha: alpha)
            }
        }
    }
}

/// One sRGB color (gamma-encoded channels 0…1) with WCAG luminance and
/// alpha compositing.
struct SRGBColor: Hashable {
    var red: Double
    var green: Double
    var blue: Double

    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    static func parse(_ raw: String) -> SRGBColor? {
        guard let color = ThemeHex.color(raw), let components = color.components,
            components.count >= 3
        else { return nil }
        return SRGBColor(
            red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]))
    }

    /// Alpha compositing in the sRGB (gamma) space the canvas blends in.
    func composited(over base: SRGBColor, alpha: Double) -> SRGBColor {
        SRGBColor(
            red: alpha * red + (1 - alpha) * base.red,
            green: alpha * green + (1 - alpha) * base.green,
            blue: alpha * blue + (1 - alpha) * base.blue)
    }

    /// WCAG relative luminance (linearized channels).
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1 for identical colors, ordered by contrast.
    func contrastRatio(with other: SRGBColor) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
