import CoreGraphics

/// Paper theme color tokens (SPEC §7.2), stored as sRGB hex and exposed as `CGColor`.
public enum PaperTheme {
    /// Canvas background, light appearance.
    public static let canvasLightHex: UInt32 = 0xFAF9F7
    /// Canvas background, dark appearance.
    public static let canvasDarkHex: UInt32 = 0x1C1C1E
    /// Root node fill, light appearance.
    public static let rootFillLightHex: UInt32 = 0x2C2C2E
    /// Root node fill, dark appearance.
    public static let rootFillDarkHex: UInt32 = 0xF2F2F7

    /// The 8-color branch palette (SPEC §7.2): red, orange, amber, green, teal, blue, purple, pink.
    public static let paletteHexes: [UInt32] = [
        0xE5484D, 0xF76B15, 0xFFC53D, 0x46A758,
        0x12A594, 0x0090FF, 0x8E4EC6, 0xD6409F,
    ]

    /// Canvas background, light appearance.
    public static var canvasLight: CGColor { color(fromHex: canvasLightHex) }
    /// Canvas background, dark appearance.
    public static var canvasDark: CGColor { color(fromHex: canvasDarkHex) }
    /// Root node fill, light appearance.
    public static var rootFillLight: CGColor { color(fromHex: rootFillLightHex) }
    /// Root node fill, dark appearance.
    public static var rootFillDark: CGColor { color(fromHex: rootFillDarkHex) }

    /// Builds an opaque sRGB color from a `0xRRGGBB` hex value.
    public static func color(fromHex hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// The `0xRRGGBB` hex value of a color, converted to sRGB, or `nil` if not convertible.
    public static func hex(of color: CGColor) -> UInt32? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let converted = color.converted(to: space, intent: .defaultIntent, options: nil) else {
            return nil
        }
        guard let components = converted.components, components.count >= 3 else { return nil }
        let red = UInt32((components[0] * 255.0).rounded())
        let green = UInt32((components[1] * 255.0).rounded())
        let blue = UInt32((components[2] * 255.0).rounded())
        guard red <= 255, green <= 255, blue <= 255 else { return nil }
        return red << 16 | green << 8 | blue
    }
}
