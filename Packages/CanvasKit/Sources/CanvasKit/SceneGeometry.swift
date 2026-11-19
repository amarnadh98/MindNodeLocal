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

/// Builds a `CanvasScene` from a `MapModel`: measures every visible node
/// once through the shared `TextMeasurer`, lays out each root's tree with
/// `TreeLayout` (stacking multiple roots), resolves Paper-theme styles
/// per level and branch index, and derives branch connectors with §7.2's
/// tapered widths. Folded subtrees are skipped (F-LAY-14).
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
        var nodes: [String: SceneNode] = [:]
        var branches: [SceneBranch] = []
        var cursorY: CGFloat = 0

        for rootID in model.roots {
            guard model.nodes[rootID] != nil else { continue }
            let structure = rootStructure(model, rootID: rootID)
            let layoutRoot = layoutTree(
                model: model, rootID: rootID, measurer: measurer, variant: variant,
                editingTitle: editingTitle)
            guard let layoutRoot else { continue }

            let frames = TreeLayout.layout(
                root: layoutRoot, structure: structure, spacing: spacing)
            // Flexible positioning (F-LAY-11): a node's manual offset moves
            // it and its descendants after auto layout (also how a
            // floating root lands where it was created, F-CAN-5).
            let offsets = accumulatedOffsets(model: model, rootID: rootID)
            let treeMinY = frames.values.map(\.minY).min() ?? (frames[rootID]?.minY ?? 0)
            let offsetY = cursorY - treeMinY
            let rootLevel1Index = levelOneIndices(model: model, rootID: rootID)

            var bottom = (frames[rootID]?.maxY ?? 0)
            for (id, frame) in frames {
                guard let node = model.nodes[id] else { continue }
                let info = ancestryInfo(model: model, id: id, rootID: rootID)
                let offset = offsets[id] ?? .zero
                let translated = frame.offsetBy(dx: offset.x, dy: offsetY + offset.y)
                let level1Index =
                    info.depth == 0
                    ? 0
                    : rootLevel1Index[info.level1AncestorID] ?? 0
                let title = id == editingTitle?.id ? editingTitle?.title : node.title
                nodes[id] = SceneNode(
                    id: id,
                    frame: translated,
                    style: PaperTheme.resolvedStyle(
                        level: info.depth, level1Index: level1Index, variant: variant),
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
                    model: model, rootID: rootID, nodes: &nodes, variant: variant))

            cursorY = bottom + rootStackGap
        }

        return CanvasScene(
            nodes: nodes,
            branches: branches,
            canvasColor: variant == .light
                ? PaperTheme.canvasLight : PaperTheme.canvasDark)
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
    /// the node grows while typing (F-EDT-8).
    static func layoutTree(
        model: MapModel,
        rootID: String,
        measurer: TextMeasurer,
        variant: ThemeVariant,
        editingTitle: (id: String, title: NodeTitle)? = nil
    ) -> LayoutNode? {
        func measuredSize(for node: Node, depth: Int) -> CGSize {
            let style: ResolvedNodeStyle = PaperTheme.resolvedStyle(
                level: depth, level1Index: 0, variant: variant)
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

        func buildNode(_ id: String, depth: Int) -> LayoutNode? {
            guard let node: Node = model.nodes[id] else { return nil }
            let size = measuredSize(for: node, depth: depth)
            var children: [LayoutNode] = []
            if !node.folded {
                for childID in node.children {
                    if let child = buildNode(childID, depth: depth + 1) {
                        children.append(child)
                    }
                }
            }
            return LayoutNode(id: id, size: size, side: side(of: node), children: children)
        }
        return buildNode(rootID, depth: 0)
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

    struct AncestryInfo {
        let depth: Int
        let level1AncestorID: String
    }

    /// Depth from the root and the level-1 ancestor that colors this
    /// node's branch. The chain walk is short (tree depth), so the array
    /// is cheap.
    static func ancestryInfo(model: MapModel, id: String, rootID: String) -> AncestryInfo {
        var chain: [String] = [id]
        var current = id
        while current != rootID {
            guard let parent = model.nodes[current]?.parent,
                parent != current, !chain.contains(parent)
            else { break }
            chain.append(parent)
            current = parent
        }
        let depth = chain.count - 1
        let level1 =
            chain.first { candidate in
                candidate != rootID && model.nodes[candidate]?.parent == rootID
            } ?? id
        return AncestryInfo(depth: depth, level1AncestorID: level1)
    }

    static func levelOneIndices(model: MapModel, rootID: String) -> [String: Int] {
        var indices: [String: Int] = [:]
        for (index, childID) in (model.nodes[rootID]?.children ?? []).enumerated() {
            indices[childID] = index
        }
        return indices
    }

    /// Branch connectors for one root's tree, in model space.
    static func connectors(
        model: MapModel,
        rootID: String,
        nodes: inout [String: SceneNode],
        variant: ThemeVariant
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
            let parentStyle = PaperTheme.resolvedStyle(
                level: parentInfo.level, level1Index: parentInfo.index, variant: variant)
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
                    parentLevel: parentInfo.level, childLevel: childScene.level)
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
                        color: PaperTheme.branchColor(
                            level1Index: childScene.level1Index, variant: variant),
                        tapered: true))
                walk(childID, parentInfo: (level: parentInfo.level + 1, index: childScene.level1Index))
            }
        }
        walk(rootID, parentInfo: (level: 0, index: 0))
        return result
    }

    /// Continuous taper from the root to the leaves (§7.2): a branch's
    /// start width is its parent node's width `w(level)`, and it tapers to
    /// `w(level + 1)` — no thickness jump at intermediate nodes.
    static func taperedWidths(parentLevel: Int, childLevel: Int) -> (start: CGFloat, end: CGFloat) {
        func levelWidth(_ level: Int) -> CGFloat {
            max(2, 6 - CGFloat(level))
        }
        return (start: levelWidth(parentLevel), end: levelWidth(childLevel))
    }
}
