import CoreGraphics
import CoreText
import Foundation

/// A font request as pure data: no `CTFont` handles, so the spec crosses
/// concurrency boundaries freely.
public struct FontSpec: Sendable, Hashable {
    public let size: CGFloat
    /// Core Text weight constant: 0.0 regular, 0.3 medium, 0.4 semibold,
    /// 0.7 bold, and so on.
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
        let base: CTFont
        if monospace {
            base = CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        } else if let family {
            base = CTFontCreateWithName(family as CFString, size, nil)
        } else if weight == 0.0 {
            base =
                CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        } else {
            let attributes = [
                kCTFontSizeAttribute: size as NSNumber,
                kCTFontWeightTrait: weight as NSNumber,
            ]
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            base = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        if !italic {
            return base
        }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic) ?? base
    }

    func withBold(_ bold: Bool) -> FontSpec {
        guard bold else { return self }
        return FontSpec(
            size: size, weight: max(weight, 0.4), family: family, italic: italic, monospace: monospace)
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
        root: FontSpec = FontSpec(size: 20, weight: 0.4),
        level1: FontSpec = FontSpec(size: 16, weight: 0.3),
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
