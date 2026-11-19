import CoreGraphics
import Foundation

/// One-sided horizontal mind map (right, or mirrored for left).
enum MindmapLayout {
    static func layout(
        root: LayoutNode, spacing: LayoutSpacing, mirror: Bool
    ) -> LayoutResult {
        let placed = placeTree(root, spacing: spacing, depth: 0)
        return assemble(placed, mirror: mirror)
    }

    /// Full-path recursion: children are placed directly.
    static func placeTree(_ node: LayoutNode, spacing: LayoutSpacing, depth: Int) -> Placed {
        TidyTree.place(
            node, spacing: spacing, depth: depth, vertical: false,
            resolve: { placeTree($0, spacing: spacing, depth: $1) })
    }

    /// Top-level transform shared by the full and incremental paths: the
    /// frames dictionary, mirrored around the root for the left structure.
    static func assemble(_ placed: Placed, mirror: Bool) -> LayoutResult {
        var frames = LayoutResult(minimumCapacity: placed.ids.count)
        for (index, id) in placed.ids.enumerated() {
            frames[id] = placed.frames[index]
        }
        if mirror {
            // The root's own width (its frame sits at the origin).
            let rootWidth = placed.frames[0].width
            for (id, frame) in frames {
                frames[id] = CGRect(
                    x: rootWidth - frame.minX - frame.width,
                    y: frame.minY,
                    width: frame.width,
                    height: frame.height)
            }
        }
        return frames
    }
}

/// Vertical org chart (down, or mirrored for up), obtained by transposing
/// the mind-map engine: node sizes swap on the way in, frames swap on the
/// way out.
enum OrgLayout {
    static func layout(root: LayoutNode, spacing: LayoutSpacing, mirror: Bool) -> LayoutResult {
        let placed = placeTree(root, spacing: spacing, depth: 0)
        return assemble(placed, mirror: mirror)
    }

    /// Full-path recursion with the vertical transpose applied inline —
    /// the same values the materialized transposed tree used to carry.
    static func placeTree(_ node: LayoutNode, spacing: LayoutSpacing, depth: Int) -> Placed {
        TidyTree.place(
            node, spacing: spacing, depth: depth, vertical: true,
            resolve: { placeTree($0, spacing: spacing, depth: $1) })
    }

    /// Top-level transform shared by the full and incremental paths:
    /// frame transposition plus the up-mirror.
    static func assemble(_ placed: Placed, mirror: Bool) -> LayoutResult {
        var frames = MindmapLayout.assemble(placed, mirror: false)
        // The root's raw height: its placed frame carries the working
        // (transposed) size, so width there is height here.
        let rootHeight = placed.frames[0].width
        for (id, frame) in frames {
            let swapped = CGRect(
                x: frame.minY, y: frame.minX, width: frame.height, height: frame.width)
            frames[id] =
                mirror
                ? CGRect(
                    x: swapped.minX, y: rootHeight - swapped.minY - swapped.height,
                    width: swapped.width, height: swapped.height)
                : swapped
        }
        return frames
    }
}

/// Balanced mind map (F-LAY-1): root children are partitioned left/right by
/// pinned side first, then greedily by subtree height, preserving order; the
/// two sides are laid out as one-sided mind maps and centered on the root.
enum BalancedLayout {
    static func layout(root: LayoutNode, spacing: LayoutSpacing) -> LayoutResult {
        var frames: LayoutResult = [root.id: CGRect(origin: .zero, size: root.size)]
        let rootWidth = root.size.width

        var leftPinned: [LayoutNode] = []
        var rightPinned: [LayoutNode] = []
        var free: [LayoutNode] = []
        for child in root.children {
            switch child.side {
            case .left: leftPinned.append(child)
            case .right: rightPinned.append(child)
            case nil: free.append(child)
            }
        }

        var leftTotal = extentTotal(leftPinned, spacing: spacing)
        var rightTotal = extentTotal(rightPinned, spacing: spacing)
        var leftFree: [LayoutNode] = []
        var rightFree: [LayoutNode] = []
        for child in free {
            let height = predictedHeight(child, spacing: spacing)
            if leftTotal <= rightTotal {
                leftTotal += height + spacing.subtreeGap
                leftFree.append(child)
            } else {
                rightTotal += height + spacing.subtreeGap
                rightFree.append(child)
            }
        }

        let leftChildren = leftPinned + leftFree
        let rightChildren = rightPinned + rightFree
        let rootMidY = root.size.height / 2

        if !rightChildren.isEmpty {
            let subtree = LayoutNode(id: root.id, size: root.size, children: rightChildren)
            let side = MindmapLayout.placeTree(subtree, spacing: spacing, depth: 0)
            placeSide(side, rootID: root.id, rootWidth: rootWidth, rootMidY: rootMidY, mirror: false, into: &frames)
        }
        if !leftChildren.isEmpty {
            let subtree = LayoutNode(id: root.id, size: root.size, children: leftChildren)
            let side = MindmapLayout.placeTree(subtree, spacing: spacing, depth: 0)
            placeSide(side, rootID: root.id, rootWidth: rootWidth, rootMidY: rootMidY, mirror: true, into: &frames)
        }
        return frames
    }

    /// One side's placed frames, centered on the root and (left) mirrored —
    /// shared by the full and incremental paths.
    static func placeSide(
        _ placed: Placed,
        rootID: String,
        rootWidth: CGFloat,
        rootMidY: CGFloat,
        mirror: Bool,
        into frames: inout LayoutResult
    ) {
        let (sideFrames, mid) = excludingRoot(placed, rootID: rootID)
        let dy = rootMidY - mid
        if mirror {
            for (id, frame) in sideFrames {
                frames[id] = CGRect(
                    x: rootWidth - frame.minX - frame.width,
                    y: frame.minY + dy,
                    width: frame.width,
                    height: frame.height)
            }
        } else {
            for (id, frame) in sideFrames {
                frames[id] = frame.offsetBy(dx: 0, dy: dy)
            }
        }
    }

    private static func excludingRoot(
        _ placed: Placed, rootID: String
    ) -> (frames: LayoutResult, midY: CGFloat) {
        var frames: LayoutResult = [:]
        frames[rootID] = nil
        var minY = 0 as CGFloat
        var maxY = 0 as CGFloat
        var hasContent = false
        for (index, id) in placed.ids.enumerated() where id != rootID {
            let frame = placed.frames[index]
            frames[id] = frame
            if hasContent {
                minY = min(minY, frame.minY)
                maxY = max(maxY, frame.maxY)
            } else {
                minY = frame.minY
                maxY = frame.maxY
                hasContent = true
            }
        }
        return (frames, hasContent ? (minY + maxY) / 2 : 0)
    }

    private static func extentTotal(_ nodes: [LayoutNode], spacing: LayoutSpacing) -> CGFloat {
        var total: CGFloat = 0
        for (index, node) in nodes.enumerated() {
            total += predictedHeight(node, spacing: spacing)
            if index < nodes.count - 1 {
                total += spacing.subtreeGap
            }
        }
        return total
    }

    /// Predicts the stacked height of a subtree without laying it out
    /// (sizes + gaps only; contour interleave is ignored, which is fine for
    /// partition balancing).
    private static func predictedHeight(_ node: LayoutNode, spacing: LayoutSpacing) -> CGFloat {
        guard !node.children.isEmpty else { return node.size.height }
        var total: CGFloat = 0
        for (index, child) in node.children.enumerated() {
            total += predictedHeight(child, spacing: spacing)
            if index < node.children.count - 1 {
                total += spacing.siblingGap
            }
        }
        return max(node.size.height, total)
    }
}
