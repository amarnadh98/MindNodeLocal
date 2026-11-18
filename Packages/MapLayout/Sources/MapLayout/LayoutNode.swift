import CoreGraphics
import Foundation

/// The pinned side of a root child in a balanced map (F-LAY-1).
public enum LayoutSide: String, Sendable {
    case left
    case right
}

/// The input tree for layout: identifiers, measured sizes, pinned sides and
/// child order. Sizes come from `TextMeasurer` in the calling layer.
public struct LayoutNode: Sendable {
    public var id: String
    public var size: CGSize
    public var side: LayoutSide?
    public var children: [LayoutNode]

    public init(id: String, size: CGSize, side: LayoutSide? = nil, children: [LayoutNode] = []) {
        self.id = id
        self.size = size
        self.side = side
        self.children = children
    }
}

/// The structures of SPEC §5.3 that this engine lays out. Raw values match
/// the `node.structure` strings stored in `map.json` (SPEC §8.2).
public enum LayoutStructure: String, Sendable {
    case mindmapBalanced = "mindmap.balanced"
    case mindmapRight = "mindmap.right"
    case mindmapLeft = "mindmap.left"
    case orgDown = "orgchart.down"
    case orgUp = "orgchart.up"
}

/// Layouts are in canvas space: the root's frame origin is `(0, 0)`, `x`
/// grows to the right and `y` grows downward.
public enum TreeLayout {
    public static func layout(
        root: LayoutNode,
        structure: LayoutStructure,
        spacing: LayoutSpacing = .default
    ) -> LayoutResult {
        switch structure {
        case .mindmapBalanced:
            BalancedLayout.layout(root: root, spacing: spacing)
        case .mindmapRight:
            MindmapLayout.layout(root: root, spacing: spacing, mirror: false)
        case .mindmapLeft:
            MindmapLayout.layout(root: root, spacing: spacing, mirror: true)
        case .orgDown:
            OrgLayout.layout(root: root, spacing: spacing, mirror: false)
        case .orgUp:
            OrgLayout.layout(root: root, spacing: spacing, mirror: true)
        }
    }
}

/// Contour band along one axis: content exists at coordinate values in
/// `[lo, hi)` and its boundary in the other axis is `value`.
struct Band {
    var lo: CGFloat
    var hi: CGFloat
    var value: CGFloat
}

/// A subtree placed in its own root-anchored coordinate frame.
struct Placed {
    var ids: [String]
    var top: [Band]
    var bottom: [Band]
    var extentMaxX: CGFloat
    var minY: CGFloat
    var maxY: CGFloat

    var height: CGFloat { maxY - minY }
}
