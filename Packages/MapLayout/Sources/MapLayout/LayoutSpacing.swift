import CoreGraphics

/// Node frames produced by a layout pass, keyed by node ID (SPEC §7.3 spacing).
public typealias LayoutResult = [String: CGRect]

/// Layout spacing preset (SPEC §7.3). `narrow` is ×0.7, `wide` is ×1.4 of the default.
public struct LayoutSpacing: Sendable, Equatable {
    /// Horizontal gap between a parent and its children.
    public let levelGap: CGFloat
    /// Vertical gap between sibling nodes.
    public let siblingGap: CGFloat
    /// Gap between subtrees of different first-level branches.
    public let subtreeGap: CGFloat
    /// Gap between a root and its level-1 children.
    public let rootGap: CGFloat

    public init(
        levelGap: CGFloat = 56,
        siblingGap: CGFloat = 12,
        subtreeGap: CGFloat = 24,
        rootGap: CGFloat = 72
    ) {
        self.levelGap = levelGap
        self.siblingGap = siblingGap
        self.subtreeGap = subtreeGap
        self.rootGap = rootGap
    }

    /// ×0.7 of the default preset (SPEC §7.3).
    public static let narrow = LayoutSpacing(
        levelGap: 56 * 0.7,
        siblingGap: 12 * 0.7,
        subtreeGap: 24 * 0.7,
        rootGap: 72 * 0.7
    )

    /// The default preset (SPEC §7.3).
    public static let `default` = LayoutSpacing()

    /// ×1.4 of the default preset (SPEC §7.3).
    public static let wide = LayoutSpacing(
        levelGap: 56 * 1.4,
        siblingGap: 12 * 1.4,
        subtreeGap: 24 * 1.4,
        rootGap: 72 * 1.4
    )
}
