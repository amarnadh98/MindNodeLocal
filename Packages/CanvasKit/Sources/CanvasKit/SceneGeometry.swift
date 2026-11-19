import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender

/// One node prepared for rendering: its laid-out frame, resolved style and
/// title. Not `Sendable` (`CGColor`); a scene lives with the view/store
/// that built it.
public struct SceneNode {
    public let id: String
    public let frame: CGRect
    public let style: ResolvedNodeStyle
    public let title: NodeTitle
    public let level: Int
    public let level1Index: Int
    /// The node's width mode/value, so the editing overlay can wrap at the
    /// width the measurer used (F-EDT-8).
    public var width: NodeWidth? = nil
}

/// One branch connector: parent outgoing anchor to child incoming anchor.
public struct SceneBranch {
    public let parentID: String
    public let childID: String
    public let from: CGPoint
    public let to: CGPoint
    public let direction: BranchDirection
    public let axis: LayoutAxis
    public let startWidth: CGFloat
    public let endWidth: CGFloat
    public let color: CGColor
    public let tapered: Bool
}

/// A whole map prepared for rendering: laid out in model space (y grows
/// down, matching the canvas and `TreeLayout` conventions).
public struct CanvasScene {
    public let nodes: [String: SceneNode]
    public let branches: [SceneBranch]
    public let canvasColor: CGColor

    public var bounds: CGRect {
        var result: CGRect = .null
        for node in nodes.values {
            result = result.union(node.frame)
        }
        return result
    }
}

/// Per-build memoization. A scene rebuild resolves every node's style
/// again; styles and branch colors are level-indexed (few dozen
/// distinct values for thousands of nodes), so resolving them once per
/// build keeps the keystroke → relayout path inside its §11.8 budget.
final class BuildCaches {
    struct StyleKey: Hashable {
        let level: Int
        let level1Index: Int
    }

    let theme: Theme
    private let variant: ThemeVariant
    private var styles: [StyleKey: ResolvedNodeStyle] = [:]
    private var branchColors: [Int: CGColor] = [:]

    init(theme: Theme, variant: ThemeVariant) {
        self.theme = theme
        self.variant = variant
    }

    func style(level: Int, level1Index: Int) -> ResolvedNodeStyle {
        let key = StyleKey(level: level, level1Index: level1Index)
        if let cached = styles[key] {
            return cached
        }
        let resolved = theme.resolvedStyle(level: level, level1Index: level1Index, variant: variant)
        styles[key] = resolved
        return resolved
    }

    func branchColor(level1Index: Int) -> CGColor {
        if let cached = branchColors[level1Index] {
            return cached
        }
        let resolved = theme.branchColor(level1Index: level1Index, variant: variant)
        branchColors[level1Index] = resolved
        return resolved
    }
}

/// Builds a `CanvasScene` from a `MapModel`: measures every visible node
/// once through the shared `TextMeasurer`, lays out each root's tree with
/// `TreeLayout` (stacking multiple roots), resolves the document's theme
/// (F-STY-3: theme → level style → branch color from the level-1
/// ancestor's stored palette index) per level and branch, and derives
/// branch connectors with the theme's branch widths. Folded subtrees are
/// skipped (F-LAY-14).
public enum SceneGeometry {
    /// Gap between the stacked root trees of a multi-root document.
    public static let rootStackGap: CGFloat = 120

    public static func build(
        model: MapModel,
        variant: ThemeVariant,
        measurer: TextMeasurer,
        spacing: LayoutSpacing = .default,
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> CanvasScene {
        // F-STY-3/F-STY-4: styles resolve from the document's theme
        // selection (default Paper) at the current appearance variant.
        let theme = BuiltInThemes.theme(id: model.theme?.id ?? BuiltInThemes.defaultID)
        var nodes: [String: SceneNode] = [:]
        var branches: [SceneBranch] = []
        var cursorY: CGFloat = 0
        let caches = BuildCaches(theme: theme, variant: variant)

        for rootID in model.roots {
            guard model.nodes[rootID] != nil else { continue }
            let structure = rootStructure(model, rootID: rootID)
            // Depth and level-1 ancestry are recorded by the same walk
            // that measures and prunes (they used to be a per-node chain
            // walk — O(depth²) per node on a 5k rebuild).
            var ancestry: [String: AncestryInfo] = [:]
            let layoutRoot = layoutTree(
                model: model, rootID: rootID, measurer: measurer,
                caches: caches, ancestry: &ancestry, editingTitle: editingTitle)
            guard let layoutRoot else { continue }

            let frames = TreeLayout.layout(
                root: layoutRoot, structure: structure, spacing: spacing)
            // Flexible positioning (F-LAY-11): a node's manual offset moves
            // it and its descendants after auto layout (also how a
            // floating root lands where it was created, F-CAN-5).
            let offsets = accumulatedOffsets(model: model, rootID: rootID)
            let treeMinY = frames.values.map(\.minY).min() ?? (frames[rootID]?.minY ?? 0)
            let offsetY = cursorY - treeMinY
            let rootLevel1Index = levelOneIndices(model: model, rootID: rootID, theme: theme)

            var bottom = (frames[rootID]?.maxY ?? 0)
            for (id, frame) in frames {
                guard let node = model.nodes[id] else { continue }
                let info = ancestry[id] ?? AncestryInfo(depth: 0, level1AncestorID: id)
                let offset = offsets[id] ?? .zero
                let translated = frame.offsetBy(dx: offset.x, dy: offsetY + offset.y)
                let level1Index =
                    info.depth == 0 ? 0 : rootLevel1Index[info.level1AncestorID] ?? 0
                let title = id == editingTitle?.id ? editingTitle?.title : node.title
                nodes[id] = SceneNode(
                    id: id,
                    frame: translated,
                    style: caches.theme.applyingOverrides(
                        node.style, to: caches.style(level: info.depth, level1Index: level1Index)),
                    title: title ?? node.title,
                    level: info.depth,
                    level1Index: level1Index,
                    width: node.width)
                if translated.maxY > bottom {
                    bottom = translated.maxY
                }
            }

            branches.append(
                contentsOf: connectors(
                    model: model, rootID: rootID, nodes: &nodes,
                    caches: caches))

            cursorY = bottom + rootStackGap
        }

        return CanvasScene(
            nodes: nodes,
            branches: branches,
            canvasColor: theme.canvasColor(for: variant))
    }

    /// The structure of a root's tree: the root's own override, else the
    /// document default (SPEC §5.3: structure is inherited until
    /// overridden; the canvas default is the balanced mind map).
    static func rootStructure(_ model: MapModel, rootID: String) -> LayoutStructure {
        guard let raw = model.nodes[rootID]?.structure,
            let structure = LayoutStructure(rawValue: raw)
        else {
            return .mindmapBalanced
        }
        return structure
    }

    /// Builds the layout tree for one root: measured node sizes, folded
    /// subtrees pruned. The editing node measures its live draft title so
    /// the node grows while typing (F-EDT-8). The same walk records each
    /// node's depth and level-1 ancestor.
    static func layoutTree(
        model: MapModel,
        rootID: String,
        measurer: TextMeasurer,
        caches: BuildCaches,
        ancestry: inout [String: AncestryInfo],
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> LayoutNode? {
        func measuredSize(for node: Node, depth: Int) -> CGSize {
            let style = caches.style(level: depth, level1Index: 0)
            let maxWidth: CGFloat?
            if node.width?.mode == .fixed, let fixed = node.width?.value {
                maxWidth = fixed
            } else {
                maxWidth = style.maxWidth
            }
            let title = node.id == editingTitle?.id ? editingTitle?.title : node.title
            let textSize: CGSize = measurer.nodeTitleSize(
                title ?? node.title, font: style.font, maxWidth: maxWidth)
            let width: CGFloat = textSize.width + style.paddingWidth * 2
            let height: CGFloat = textSize.height + style.paddingHeight * 2
            return CGSize(width: width, height: height)
        }

        func buildNode(_ id: String, depth: Int, level1: String) -> LayoutNode? {
            guard let node: Node = model.nodes[id] else { return nil }
            ancestry[id] = AncestryInfo(
                depth: depth,
                // The level-1 ancestor of a root (depth 0) and of a
                // first-level node is the node itself.
                level1AncestorID: depth <= 1 ? id : level1)
            let size = measuredSize(for: node, depth: depth)
            var children: [LayoutNode] = []
            if !node.folded {
                let childLevel1 = depth == 0 ? id : (depth == 1 ? id : level1)
                for childID in node.children {
                    if let child = buildNode(childID, depth: depth + 1, level1: childLevel1) {
                        children.append(child)
                    }
                }
            }
            return LayoutNode(id: id, size: size, side: side(of: node), children: children)
        }
        return buildNode(rootID, depth: 0, level1: rootID)
    }

    /// A node's manual offset, plus the accumulated offsets of its
    /// ancestors — the translation applied after auto layout (SPEC §9:
    /// "offset is added after auto layout; descendants move with it").
    static func accumulatedOffsets(model: MapModel, rootID: String) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]

        func walk(_ id: String, inherited: CGPoint) {
            var own = inherited
            if let offset = model.nodes[id]?.offset {
                own = CGPoint(x: own.x + offset.x, y: own.y + offset.y)
            }
            result[id] = own
            for childID in model.nodes[id]?.children ?? [] {
                walk(childID, inherited: own)
            }
        }
        walk(rootID, inherited: .zero)
        return result
    }

    private static func side(of node: Node) -> LayoutSide? {
        guard let sidePin = node.side else { return nil }
        return sidePin == .left ? .left : .right
    }

    /// Depth from the root and the level-1 ancestor that colors this
    /// node's branch — recorded by the same recursion that measures
    /// (`layoutTree`), so a rebuild never walks ancestor chains again.
    struct AncestryInfo {
        let depth: Int
        let level1AncestorID: String
    }

    /// The palette index each of `rootID`'s children colors its branch
    /// with (ADR-0009): the stored persistent index, falling back to
    /// the child's position when none is stored; the theme's
    /// rainbow-branches toggle (F-STY-8) collapses it to 0 when off.
    static func levelOneIndices(model: MapModel, rootID: String, theme: Theme) -> [String: Int] {
        var indices: [String: Int] = [:]
        for (position, childID) in (model.nodes[rootID]?.children ?? []).enumerated() {
            let stored = model.nodes[childID]?.paletteIndex ?? position
            indices[childID] = theme.effectivePaletteIndex(stored)
        }
        return indices
    }

    /// Branch connectors for one root's tree, in model space.
    static func connectors(
        model: MapModel,
        rootID: String,
        nodes: inout [String: SceneNode],
        caches: BuildCaches
    ) -> [SceneBranch] {
        var result: [SceneBranch] = []
        let structure = rootStructure(model, rootID: rootID)
        let (axis, directions): (LayoutAxis, (BranchDirection, BranchDirection)) = {
            switch structure {
            case .mindmapBalanced, .mindmapRight:
                (.horizontal, (.right, .left))
            case .mindmapLeft:
                (.horizontal, (.left, .right))
            case .orgDown:
                (.vertical, (.down, .down))
            case .orgUp:
                (.vertical, (.up, .up))
            }
        }()

        func walk(_ id: String, parentInfo: (level: Int, index: Int)) {
            guard let node = model.nodes[id] else { return }
            let children = node.folded ? [] : node.children
            let parentStyle = caches.theme.applyingOverrides(
                node.style, to: caches.style(level: parentInfo.level, level1Index: parentInfo.index))
            for childID in children {
                guard let childScene = nodes[childID] else { continue }
                let direction: BranchDirection
                switch structure {
                case .mindmapBalanced:
                    direction =
                        childScene.frame.midX >= (nodes[id]?.frame.midX ?? 0)
                        ? directions.0 : directions.1
                default:
                    direction = directions.0
                }
                let from = NodeRenderer.outgoingAnchor(
                    style: parentStyle, frame: nodes[id]?.frame ?? .zero, direction: direction)
                let childStyle = childScene.style
                let to = NodeRenderer.incomingAnchor(
                    style: childStyle, frame: childScene.frame, direction: direction)
                let widths = taperedWidths(
                    theme: caches.theme, parentLevel: parentInfo.level, childLevel: childScene.level)
                result.append(
                    SceneBranch(
                        parentID: id,
                        childID: childID,
                        from: from,
                        to: to,
                        direction: direction,
                        axis: axis,
                        startWidth: widths.start,
                        endWidth: widths.end,
                        color: caches.branchColor(level1Index: childScene.level1Index),
                        tapered: caches.theme.branch.lineStyle == .tapered))
                walk(childID, parentInfo: (level: parentInfo.level + 1, index: childScene.level1Index))
            }
        }
        walk(rootID, parentInfo: (level: 0, index: 0))
        return result
    }

    /// Continuous taper from the root to the leaves (§7.2): a branch's
    /// start width is its parent node's width `w(level)`, and it tapers to
    /// `w(level + 1)` — no thickness jump at intermediate nodes. The width
    /// fall-off is theme data (Paper: 6 pt at the root down to 2 pt).
    static func taperedWidths(
        theme: Theme, parentLevel: Int, childLevel: Int
    ) -> (start: CGFloat, end: CGFloat) {
        (start: theme.branchWidth(level: parentLevel), end: theme.branchWidth(level: childLevel))
    }
}
