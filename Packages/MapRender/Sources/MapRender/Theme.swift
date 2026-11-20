import CoreGraphics
import Foundation
import MapCore

/// Theme color notation: `#RRGGBB` (sRGB, opaque). Alpha lives in the
/// style field that references the color (`ThemeFill.palette(alpha:)`,
/// `ThemeShadowLayer.alpha`), never inside the string — the same hex
/// always names the same color.
public enum ThemeHex {
    /// Parses `#RRGGBB` (or `RRGGBB`) into an opaque sRGB `CGColor`.
    public static func color(_ raw: String) -> CGColor? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1.0)
    }

    /// Formats a `0xRRGGBB` value back into the theme notation.
    public static func string(_ hex: UInt32) -> String {
        String(format: "#%06X", hex)
    }
}

/// How a theme property picks its color: a fixed hex, or the branch's
/// palette color (F-STY-3: the level-1 ancestor's palette index).
///
/// `.arbortheme` JSON: `"#RRGGBB"` for solid, `"palette"` for the branch
/// color — `#` can never start a palette keyword, so the two readings
/// never collide.
public enum ThemePaint: Codable, Sendable, Hashable {
    /// `#RRGGBB`.
    case solid(String)
    /// The palette color of the node's level-1 ancestor.
    case palette

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = raw == "palette" ? .palette : .solid(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .solid(let raw): try container.encode(raw)
        case .palette: try container.encode("palette")
        }
    }
}

/// A node fill. Level-1 nodes in most themes tint the branch palette
/// color at a theme-chosen alpha over the canvas.
///
/// `.arbortheme` JSON: `"none"`, `"#RRGGBB"`, or `{"palette": 0.16}`.
public enum ThemeFill: Codable, Sendable, Hashable {
    case none
    /// `#RRGGBB`.
    case solid(String)
    /// The branch palette color at `alpha` (composited over the canvas).
    case palette(alpha: Double)

    private enum CodingKeys: String, CodingKey {
        case palette
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let raw = try? single.decode(String.self)
        {
            if raw == "none" {
                self = .none
                return
            }
            if raw == "palette" {
                self = .palette(alpha: 1)
                return
            }
            self = .solid(raw)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .palette(alpha: try container.decode(Double.self, forKey: .palette))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode("none")
        case .solid(let raw):
            var container = encoder.singleValueContainer()
            try container.encode(raw)
        case .palette(let alpha):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(alpha, forKey: .palette)
        }
    }
}

/// A node border. For `underline` shapes the border *is* the underline:
/// `width` becomes the underline thickness and `paint` its color.
public struct ThemeBorder: Codable, Sendable, Hashable {
    public var paint: ThemePaint
    public var width: Double
    public var dash: Bool

    public init(paint: ThemePaint, width: Double = 1.5, dash: Bool = false) {
        self.paint = paint
        self.width = width
        self.dash = dash
    }
}

/// One shadow layer (SPEC §7.2: Paper's "raised" style is two layers).
/// `color` is `#RRGGBB`; `alpha` is separate so it stays exact float data.
public struct ThemeShadowLayer: Codable, Sendable, Hashable {
    public var offsetY: Double
    public var blur: Double
    public var color: String
    public var alpha: Double

    public init(offsetY: Double, blur: Double, color: String, alpha: Double) {
        self.offsetY = offsetY
        self.blur = blur
        self.color = color
        self.alpha = alpha
    }
}

/// A font request as pure theme data; maps onto `FontSpec` (whose weight
/// is a Core Text constant: 0 regular, 0.23 medium, 0.3 semibold, 0.4 bold).
public struct ThemeFont: Codable, Sendable, Hashable {
    public var size: Double
    public var weight: Double
    /// `nil` picks the system family (SPEC §7.5).
    public var family: String?
    public var italic: Bool
    public var monospace: Bool

    public init(
        size: Double, weight: Double = 0.0, family: String? = nil,
        italic: Bool = false, monospace: Bool = false
    ) {
        self.size = size
        self.weight = weight
        self.family = family
        self.italic = italic
        self.monospace = monospace
    }
}

/// One level's node style (F-STY-3): shape, fill, border, corner radius,
/// padding, shadow, typography and text color.
public struct ThemeLevelStyle: Codable, Sendable, Hashable {
    public var shape: NodeShape
    public var fill: ThemeFill
    public var border: ThemeBorder?
    public var cornerRadius: Double
    public var paddingWidth: Double
    public var paddingHeight: Double
    public var shadow: [ThemeShadowLayer]
    public var font: ThemeFont
    /// `#RRGGBB`.
    public var textColor: String
    public var maxWidth: Double
    /// Auto-width floors here, so short siblings share a width (nil = no
    /// floor).
    public var minWidth: Double?

    public init(
        shape: NodeShape,
        fill: ThemeFill,
        border: ThemeBorder? = nil,
        cornerRadius: Double = 10,
        paddingWidth: Double = 16,
        paddingHeight: Double = 10,
        shadow: [ThemeShadowLayer] = [],
        font: ThemeFont,
        textColor: String,
        maxWidth: Double = 280,
        minWidth: Double? = nil
    ) {
        self.shape = shape
        self.fill = fill
        self.border = border
        self.cornerRadius = cornerRadius
        self.paddingWidth = paddingWidth
        self.paddingHeight = paddingHeight
        self.shadow = shadow
        self.font = font
        self.textColor = textColor
        self.maxWidth = maxWidth
        self.minWidth = minWidth
    }
}

/// The four level styles every theme defines (F-STY-3): root, level 1,
/// level 2, level 3+.
public struct ThemeLevels: Codable, Sendable, Hashable {
    public var root: ThemeLevelStyle
    public var level1: ThemeLevelStyle
    public var level2: ThemeLevelStyle
    public var level3Plus: ThemeLevelStyle

    public init(
        root: ThemeLevelStyle, level1: ThemeLevelStyle,
        level2: ThemeLevelStyle, level3Plus: ThemeLevelStyle
    ) {
        self.root = root
        self.level1 = level1
        self.level2 = level2
        self.level3Plus = level3Plus
    }

    /// The style for a node at `level` (0 = root, 1, 2, ≥3).
    public func style(forLevel level: Int) -> ThemeLevelStyle {
        switch level {
        case 0: root
        case 1: level1
        case 2: level2
        default: level3Plus
        }
    }
}

/// One appearance variant of a theme (F-STY-4: every theme is dynamic):
/// its canvas color, branch palette (8–12 colors, SPEC §5.8) and level
/// styles.
public struct ThemeScheme: Codable, Sendable, Hashable {
    /// `#RRGGBB`.
    public var canvasColor: String
    public var palette: [String]
    public var levels: ThemeLevels

    public init(canvasColor: String, palette: [String], levels: ThemeLevels) {
        self.canvasColor = canvasColor
        self.palette = palette
        self.levels = levels
    }
}

/// How branches are drawn (SPEC §7.4). `tapered` is Paper's default;
/// `taper` is the width fall-off from `startWidth` at the root down to
/// `endWidth` at the leaves.
public enum BranchLineStyle: String, Codable, Sendable, CaseIterable {
    case curved
    case tapered
    case straight
    case elbow
    case none
}

public struct ThemeBranchStyle: Codable, Sendable, Hashable {
    public var lineStyle: BranchLineStyle
    public var startWidth: Double
    public var endWidth: Double

    public init(lineStyle: BranchLineStyle, startWidth: Double, endWidth: Double) {
        self.lineStyle = lineStyle
        self.startWidth = startWidth
        self.endWidth = endWidth
    }
}

/// Placeholder for the cross-node connection style (F-REL-1; the
/// drawing slice consumes this).
public struct ThemeConnectionStyle: Codable, Sendable, Hashable {
    /// `#RRGGBB`.
    public var color: String
    public var width: Double
    public var dash: Bool
    public var arrowEnd: Bool

    public init(color: String, width: Double, dash: Bool, arrowEnd: Bool) {
        self.color = color
        self.width = width
        self.dash = dash
        self.arrowEnd = arrowEnd
    }
}

/// Placeholder for the boundary style (F-REL-3; the drawing slice
/// consumes this).
public struct ThemeBoundaryStyle: Codable, Sendable, Hashable {
    /// `#RRGGBB`.
    public var strokeColor: String
    public var fillColor: String
    public var cornerRadius: Double
    public var padding: Double

    public init(strokeColor: String, fillColor: String, cornerRadius: Double, padding: Double) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.cornerRadius = cornerRadius
        self.padding = padding
    }
}

/// A complete theme as pure data (F-STY-3/F-STY-4): identity, a light and
/// a dark scheme, branch/connection/boundary styles and the
/// rainbow-branches toggle (F-STY-8). Codable with the `.arbortheme`
/// JSON schema (SPEC §5.8 F-STY-5): one round trip through
/// `JSONEncoder`/`JSONDecoder` is the file format.
public struct Theme: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var light: ThemeScheme
    public var dark: ThemeScheme
    public var branch: ThemeBranchStyle
    /// F-STY-8: `true` — each level-1 branch takes the next palette color
    /// and descendants inherit it; `false` — every branch uses palette
    /// color 0.
    public var rainbowBranches: Bool
    public var connection: ThemeConnectionStyle
    public var boundary: ThemeBoundaryStyle

    public init(
        id: String,
        name: String,
        light: ThemeScheme,
        dark: ThemeScheme,
        branch: ThemeBranchStyle,
        rainbowBranches: Bool,
        connection: ThemeConnectionStyle,
        boundary: ThemeBoundaryStyle
    ) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
        self.branch = branch
        self.rainbowBranches = rainbowBranches
        self.connection = connection
        self.boundary = boundary
    }
}
