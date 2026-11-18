import CoreGraphics
import CoreText
import Foundation

/// A font request as pure data: no `CTFont` handles, so the spec crosses
/// concurrency boundaries freely.
public struct FontSpec: Sendable, Hashable {
    public let size: CGFloat
    /// Core Text weight constant (verified against the resolved font):
    /// 0.0 regular, 0.23 medium, 0.3 semibold, 0.4 bold.
    public let weight: CGFloat
    /// `nil` picks the system font family.
    public let family: String?
    public let italic: Bool
    public let monospace: Bool

    public init(
        size: CGFloat,
        weight: CGFloat = 0.0,
        family: String? = nil,
        italic: Bool = false,
        monospace: Bool = false
    ) {
        self.size = size
        self.weight = weight
        self.family = family
        self.italic = italic
        self.monospace = monospace
    }

    var ctFont: CTFont {
        if monospace {
            return CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        }
        if let family {
            return CTFontCreateWithName(family as CFString, size, nil)
        }
        let system =
            CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard weight != 0.0 else {
            return applyItalic(to: system)
        }
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight as NSNumber]
        let attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(system), attributes as CFDictionary)
        let weighted = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return applyItalic(to: weighted)
    }

    private func applyItalic(to font: CTFont) -> CTFont {
        guard italic else { return font }
        return CTFontCreateCopyWithSymbolicTraits(
            font, size, nil, .traitItalic, .traitItalic) ?? font
    }
}

/// Typography per theme level (SPEC §7.2, §7.5): root 20 pt semibold,
/// level 1 at 16 pt medium, level 2+ at 14 pt regular, 1.25 line height.
public struct ThemeTypography: Sendable, Hashable {
    public let root: FontSpec
    public let level1: FontSpec
    public let level2Plus: FontSpec
    public let lineHeight: CGFloat

    public init(
        root: FontSpec = FontSpec(size: 20, weight: 0.3),
        level1: FontSpec = FontSpec(size: 16, weight: 0.23),
        level2Plus: FontSpec = FontSpec(size: 14, weight: 0.0),
        lineHeight: CGFloat = 1.25
    ) {
        self.root = root
        self.level1 = level1
        self.level2Plus = level2Plus
        self.lineHeight = lineHeight
    }

    public func font(forLevel level: Int) -> FontSpec {
        switch level {
        case 0: root
        case 1: level1
        default: level2Plus
        }
    }
}
