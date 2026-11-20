import Foundation

/// Per-node style overrides (F-STY-2, SPEC §8.2 `style` — only
/// overridden properties persist). Colors are `#RRGGBB` or the fill
/// keyword `"none"`; `alignment` and `branchLineStyle` are the raw
/// enum strings. New in formatVersion 4 (ADR-0028): `fontWeight`
/// (Core Text constant, 0 regular … 0.4 bold), `fontItalic` and
/// `minWidth` — all optional, so v3 files decode unchanged.
public struct NodeStylePatch: Codable, Sendable, Hashable {
    public var shape: NodeShape?
    public var fill: String?
    public var borderColor: String?
    public var borderWidth: Double?
    public var borderDash: Bool?
    public var cornerRadius: Double?
    public var padding: Double?
    public var shadow: ShadowStyle?
    public var fontName: String?
    public var fontSize: Double?
    public var fontWeight: Double?
    public var fontItalic: Bool?
    public var textColor: String?
    public var alignment: String?
    public var branchColor: String?
    public var branchWidth: Double?
    public var branchTaper: Double?
    public var branchLineStyle: String?
    public var minWidth: Double?
    public var maxWidth: Double?
    public var imagePlacement: ImagePlacement?

    public init(
        shape: NodeShape? = nil,
        fill: String? = nil,
        borderColor: String? = nil,
        borderWidth: Double? = nil,
        borderDash: Bool? = nil,
        cornerRadius: Double? = nil,
        padding: Double? = nil,
        shadow: ShadowStyle? = nil,
        fontName: String? = nil,
        fontSize: Double? = nil,
        fontWeight: Double? = nil,
        fontItalic: Bool? = nil,
        textColor: String? = nil,
        alignment: String? = nil,
        branchColor: String? = nil,
        branchWidth: Double? = nil,
        branchTaper: Double? = nil,
        branchLineStyle: String? = nil,
        minWidth: Double? = nil,
        maxWidth: Double? = nil,
        imagePlacement: ImagePlacement? = nil
    ) {
        self.shape = shape
        self.fill = fill
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.borderDash = borderDash
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.shadow = shadow
        self.fontName = fontName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontItalic = fontItalic
        self.textColor = textColor
        self.alignment = alignment
        self.branchColor = branchColor
        self.branchWidth = branchWidth
        self.branchTaper = branchTaper
        self.branchLineStyle = branchLineStyle
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.imagePlacement = imagePlacement
    }
}

/// One addressable field of a `NodeStylePatch` (F-STY-2/F-STY-3): the
/// inspector's "Reset to theme" per property and the `resetStyle`
/// command's key list are expressed in these, so a reset can clear a
/// single override without knowing the patch's value shapes.
public enum NodeStyleKey: String, Codable, Sendable, CaseIterable, Hashable {
    case shape
    case fill
    case borderColor
    case borderWidth
    case borderDash
    case cornerRadius
    case padding
    case shadow
    case fontName
    case fontSize
    case fontWeight
    case fontItalic
    case textColor
    case alignment
    case branchColor
    case branchWidth
    case branchTaper
    case branchLineStyle
    case minWidth
    case maxWidth
    case imagePlacement
}

extension NodeStylePatch {
    /// `true` when no field is set — an "empty" patch stores as `nil`
    /// on the node, keeping `map.json` free of `"style": {}` noise
    /// (SPEC §8.2: only overridden properties persist).
    public var isEmpty: Bool {
        NodeStyleKey.allCases.allSatisfy { !hasOverride($0) }
    }

    /// The keys whose changes can move the node's **measured size**
    /// (font, padding, width floors): the layout-dirty set of a
    /// `setStyle`/`resetStyle` is exactly these (SPEC §11.3); every
    /// other field (colors, borders, shapes, branch styling) only
    /// repaints.
    public static let sizeAffectingKeys: Set<NodeStyleKey> = [
        .padding, .fontName, .fontSize, .fontWeight, .fontItalic, .minWidth, .maxWidth,
    ]

    /// `true` when the patch carries a value for any size-affecting
    /// field, so applying it must re-measure the node.
    public var affectsMeasuredSize: Bool {
        !Self.sizeAffectingKeys.isDisjoint(with: overriddenKeys)
    }

    // One wide mirror of the patch's fields, by design (like the
    // command dispatchers).
    // swiftlint:disable cyclomatic_complexity
    /// `true` when this patch carries a value for `key`.
    public func hasOverride(_ key: NodeStyleKey) -> Bool {
        switch key {
        case .shape: shape != nil
        case .fill: fill != nil
        case .borderColor: borderColor != nil
        case .borderWidth: borderWidth != nil
        case .borderDash: borderDash != nil
        case .cornerRadius: cornerRadius != nil
        case .padding: padding != nil
        case .shadow: shadow != nil
        case .fontName: fontName != nil
        case .fontSize: fontSize != nil
        case .fontWeight: fontWeight != nil
        case .fontItalic: fontItalic != nil
        case .textColor: textColor != nil
        case .alignment: alignment != nil
        case .branchColor: branchColor != nil
        case .branchWidth: branchWidth != nil
        case .branchTaper: branchTaper != nil
        case .branchLineStyle: branchLineStyle != nil
        case .minWidth: minWidth != nil
        case .maxWidth: maxWidth != nil
        case .imagePlacement: imagePlacement != nil
        }
    }

    /// The keys this patch carries a value for, in `NodeStyleKey` order.
    public var overriddenKeys: [NodeStyleKey] {
        NodeStyleKey.allCases.filter { hasOverride($0) }
    }

    /// Clears `key` (F-STY-3 "Reset to theme" for one property).
    public mutating func clear(_ key: NodeStyleKey) {
        switch key {
        case .shape: shape = nil
        case .fill: fill = nil
        case .borderColor: borderColor = nil
        case .borderWidth: borderWidth = nil
        case .borderDash: borderDash = nil
        case .cornerRadius: cornerRadius = nil
        case .padding: padding = nil
        case .shadow: shadow = nil
        case .fontName: fontName = nil
        case .fontSize: fontSize = nil
        case .fontWeight: fontWeight = nil
        case .fontItalic: fontItalic = nil
        case .textColor: textColor = nil
        case .alignment: alignment = nil
        case .branchColor: branchColor = nil
        case .branchWidth: branchWidth = nil
        case .branchTaper: branchTaper = nil
        case .branchLineStyle: branchLineStyle = nil
        case .minWidth: minWidth = nil
        case .maxWidth: maxWidth = nil
        case .imagePlacement: imagePlacement = nil
        }
    }

    /// Merges `other` in: every field `other` sets overwrites the
    /// stored value, fields `other` leaves `nil` are untouched. This
    /// is the `setStyle(ids:patch:)` apply semantics (the inspector
    /// writes one property per interaction; the rest of the node's
    /// overrides must survive).
    public mutating func merge(_ other: NodeStylePatch) {
        if let value = other.shape { shape = value }
        if let value = other.fill { fill = value }
        if let value = other.borderColor { borderColor = value }
        if let value = other.borderWidth { borderWidth = value }
        if let value = other.borderDash { borderDash = value }
        if let value = other.cornerRadius { cornerRadius = value }
        if let value = other.padding { padding = value }
        if let value = other.shadow { shadow = value }
        if let value = other.fontName { fontName = value }
        if let value = other.fontSize { fontSize = value }
        if let value = other.fontWeight { fontWeight = value }
        if let value = other.fontItalic { fontItalic = value }
        if let value = other.textColor { textColor = value }
        if let value = other.alignment { alignment = value }
        if let value = other.branchColor { branchColor = value }
        if let value = other.branchWidth { branchWidth = value }
        if let value = other.branchTaper { branchTaper = value }
        if let value = other.branchLineStyle { branchLineStyle = value }
        if let value = other.minWidth { minWidth = value }
        if let value = other.maxWidth { maxWidth = value }
        if let value = other.imagePlacement { imagePlacement = value }
    }

    // swiftlint:enable cyclomatic_complexity
}
