import CanvasKit
import CoreGraphics
import Foundation
import MapCore

/// The subset of a scene an export renders: the filtered nodes and
/// branches, and the content bounds (margin included) every exporter
/// sizes its output from.
public struct ExportScene {
    /// The nodes to render, in model (document) order when built through
    /// `ExportGeometry.content(scene:model:content:margin:)`.
    public let nodes: [SceneNode]
    public let branches: [SceneBranch]
    /// Content bounds including the requested margin, never smaller than
    /// a point.
    public let bounds: CGRect
    /// The scene's canvas color, for background fills.
    public let canvasColor: CGColor

    public init(
        nodes: [SceneNode], branches: [SceneBranch], bounds: CGRect, canvasColor: CGColor
    ) {
        self.nodes = nodes
        self.branches = branches
        self.bounds = bounds
        self.canvasColor = canvasColor
    }
}

/// Filters a scene down to an `ExportContent` and computes the bounds
/// the exporters lay out against.
public enum ExportGeometry {
    public static let minimumSize = CGSize(width: 1, height: 1)

    /// The nodes of `content`, in document order (roots, then
    /// depth-first), with the branches that connect them, and the
    /// margin-padded bounds.
    public static func content(
        scene: CanvasScene, model: MapModel, content: ExportContent, margin: CGFloat
    ) -> ExportScene {
        let orderedIDs = orderedNodeIDs(model: model, content: content)
        var nodes: [SceneNode] = []
        nodes.reserveCapacity(orderedIDs.count)
        var bounds = CGRect.null
        for id in orderedIDs {
            guard let node = scene.nodes[id] else { continue }
            nodes.append(node)
            bounds = bounds.union(styledBounds(of: node))
        }
        var branches: [SceneBranch] = []
        let visible = Set(orderedIDs)
        for branch in scene.branches {
            guard visible.contains(branch.childID), visible.contains(branch.parentID) else {
                continue
            }
            branches.append(branch)
            let cap = max(branch.startWidth, branch.endWidth)
            let branchRect = CGRect(
                x: min(branch.from.x, branch.to.x), y: min(branch.from.y, branch.to.y),
                width: abs(branch.to.x - branch.from.x), height: abs(branch.to.y - branch.from.y)
            ).insetBy(dx: -cap, dy: -cap)
            bounds = bounds.union(branchRect)
        }

        if bounds.isNull || bounds.width < 0 || bounds.height < 0 {
            bounds = CGRect(origin: .zero, size: minimumSize)
        }
        bounds = bounds.insetBy(dx: -margin, dy: -margin).integral
        return ExportScene(nodes: nodes, branches: branches, bounds: bounds, canvasColor: scene.canvasColor)
    }

    /// Document-order ids for `content` (roots, then children
    /// depth-first), so every exporter emits deterministically. The walk
    /// traverses the whole tree even through nodes outside `content`
    /// (a subtree export starts mid-tree), collecting only visible ids.
    public static func orderedNodeIDs(model: MapModel, content: ExportContent) -> [String] {
        let visible = visibleNodeIDs(model: model, content: content)
        var ordered: [String] = []
        var seen = Set<String>()
        func visit(_ id: String) {
            guard let node = model.nodes[id], seen.insert(id).inserted else { return }
            if visible.contains(id) {
                ordered.append(id)
            }
            for child in node.children { visit(child) }
        }
        for root in model.roots { visit(root) }
        // Orphaned nodes nothing points at (already a validator offense)
        // still export, in a deterministic order.
        for id in model.nodes.keys.sorted() where visible.contains(id) && !seen.contains(id) {
            ordered.append(id)
        }
        return ordered
    }

    /// The ids an `ExportContent` covers: everything, or the closed
    /// subtrees of the selected ids (folding still prunes invisible nodes
    /// — the scene never contains them).
    public static func visibleNodeIDs(model: MapModel, content: ExportContent) -> Set<String> {
        switch content {
        case .wholeMap:
            return Set(model.nodes.keys)
        case .subtree(let roots):
            var result = Set<String>()
            for root in roots {
                walk(root, in: model, into: &result)
            }
            return result
        }
    }

    private static func walk(_ id: String, in model: MapModel, into result: inout Set<String>) {
        guard let node = model.nodes[id] else { return }
        result.insert(id)
        for child in node.children { walk(child, in: model, into: &result) }
    }

    /// A node frame plus half the thickest stroke that can touch it, so
    /// no connector or underline is clipped at the bounds edge.
    private static func styledBounds(of node: SceneNode) -> CGRect {
        let fuzz = max(node.style.borderWidth, node.style.underlineWidth) + 2
        return node.frame.insetBy(dx: -fuzz, dy: -fuzz)
    }
}
