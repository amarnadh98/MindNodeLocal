import CoreGraphics
import Foundation

/// Shared contour machinery for the one-sided structures. Children are
/// stacked along one axis; consecutive siblings are separated by walking the
/// accumulated outer contour against the new subtree's inner contour
/// (van der Ploeg-style band merge over struct arrays, no class graph).
enum Contours {
    static func shift(_ bands: [Band], dx: CGFloat, dy: CGFloat) -> [Band] {
        bands.map { Band(lo: $0.lo + dx, hi: $0.hi + dx, value: $0.value + dy) }
    }

    /// Merges two band sets, taking the outer boundary value (`take` = max
    /// for bottom contours, min for top contours) wherever bands overlap.
    /// Event sweep over all band edges; linear in the input size.
    static func merge(
        _ first: [Band], _ second: [Band], take: (CGFloat, CGFloat) -> CGFloat
    ) -> [Band] {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }

        struct Event: Comparable {
            let at: CGFloat
            let isEnd: Bool
            let value: CGFloat

            static func < (lhs: Event, rhs: Event) -> Bool {
                if lhs.at != rhs.at { return lhs.at < rhs.at }
                if lhs.isEnd != rhs.isEnd { return lhs.isEnd }
                return lhs.value < rhs.value
            }
        }

        var events: [Event] = []
        events.reserveCapacity((first.count + second.count) * 2)
        for band in first {
            events.append(Event(at: band.lo, isEnd: false, value: band.value))
            events.append(Event(at: band.hi, isEnd: true, value: band.value))
        }
        for band in second {
            events.append(Event(at: band.lo, isEnd: false, value: band.value))
            events.append(Event(at: band.hi, isEnd: true, value: band.value))
        }
        events.sort()

        var active: [(value: CGFloat, count: Int)] = []
        var result: [Band] = []
        var segmentStart: CGFloat?
        var segmentValue: CGFloat?

        func outerValue() -> CGFloat? {
            var value: CGFloat?
            for entry in active {
                value = value.map { take($0, entry.value) } ?? entry.value
            }
            return value
        }

        func add(_ value: CGFloat) {
            for index in active.indices where active[index].value == value {
                active[index].count += 1
                return
            }
            active.append((value, 1))
        }

        func remove(_ value: CGFloat) {
            for index in active.indices where active[index].value == value {
                let remaining = active[index].count - 1
                if remaining > 0 {
                    active[index].count = remaining
                } else {
                    active.remove(at: index)
                }
                return
            }
        }

        for event in events {
            if let start = segmentStart, event.at > start, let value = segmentValue {
                if let last = result.last, last.hi == start, last.value == value {
                    result[result.count - 1].hi = event.at
                } else {
                    result.append(Band(lo: start, hi: event.at, value: value))
                }
            }
            if event.isEnd {
                remove(event.value)
            } else {
                add(event.value)
            }
            segmentStart = event.at
            segmentValue = outerValue()
        }
        return result
    }

    /// Minimal extra distance so that `incoming` (already positioned) clears
    /// `accumulated` everywhere their bands overlap.
    static func separation(
        accumulated: [Band], incoming: [Band], gap: CGFloat
    ) -> CGFloat {
        var required: CGFloat = 0
        var i = 0
        var j = 0
        while i < accumulated.count, j < incoming.count {
            let acc = accumulated[i]
            let inc = incoming[j]
            let lo = max(acc.lo, inc.lo)
            let hi = min(acc.hi, inc.hi)
            if lo < hi {
                required = max(required, acc.value + gap - inc.value)
            }
            if acc.hi < inc.hi {
                i += 1
            } else if acc.hi > inc.hi {
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return max(0, required)
    }
}

/// One-sided horizontal mind map (right, or mirrored for left).
enum MindmapLayout {
    static func layout(
        root: LayoutNode, spacing: LayoutSpacing, mirror: Bool
    ) -> LayoutResult {
        var frames: LayoutResult = [:]
        _ = place(root, spacing: spacing, depth: 0, frames: &frames)
        if mirror {
            let rootWidth = root.size.width
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

    /// Places `node`'s subtree with the node itself at the origin. Frames are
    /// written relative to that origin; the caller translates them.
    private static func place(
        _ node: LayoutNode, spacing: LayoutSpacing, depth: Int, frames: inout LayoutResult
    ) -> Placed {
        frames[node.id] = CGRect(origin: .zero, size: node.size)

        let ownTop = [Band(lo: 0, hi: node.size.width, value: 0)]
        let ownBottom = [Band(lo: 0, hi: node.size.width, value: node.size.height)]

        guard !node.children.isEmpty else {
            return Placed(
                ids: [node.id], top: ownTop, bottom: ownBottom,
                extentMaxX: node.size.width, minY: 0, maxY: node.size.height)
        }

        let gapToChildren = depth == 0 ? spacing.rootGap : spacing.levelGap
        let siblingGap = depth == 0 ? spacing.subtreeGap : spacing.siblingGap
        let childX = node.size.width + gapToChildren

        var accumulatedBottom: [Band] = []
        var childrenTop: [Band] = []
        var childrenBottom: [Band] = []
        var childIDs: [String] = []
        var childExtentMaxX: CGFloat = 0
        var childMinY: CGFloat = 0
        var childMaxY: CGFloat = 0
        var cursor: CGFloat = 0
        var firstChildMid: CGFloat?
        var lastChildMid: CGFloat = 0

        for child in node.children {
            let childPlaced = place(child, spacing: spacing, depth: depth + 1, frames: &frames)
            let candidateTop = Contours.shift(childPlaced.top, dx: childX, dy: cursor)
            let dy = Contours.separation(
                accumulated: accumulatedBottom, incoming: candidateTop, gap: siblingGap)
            let childY = cursor + dy

            for id in childPlaced.ids {
                if let frame = frames[id] {
                    frames[id] = frame.offsetBy(dx: childX, dy: childY)
                }
            }

            let shiftedTop = Contours.shift(childPlaced.top, dx: childX, dy: childY)
            let shiftedBottom = Contours.shift(childPlaced.bottom, dx: childX, dy: childY)
            accumulatedBottom = Contours.merge(accumulatedBottom, shiftedBottom, take: max)
            childrenTop = Contours.merge(childrenTop, shiftedTop, take: min)
            childrenBottom = Contours.merge(childrenBottom, shiftedBottom, take: max)

            cursor = childY + childPlaced.maxY
            accumulatedBottom = accumulatedBottom.filter { $0.value > cursor - siblingGap }
            let mid = childY + (childPlaced.minY + childPlaced.maxY) / 2
            firstChildMid = firstChildMid ?? mid
            lastChildMid = mid
            childExtentMaxX = max(childExtentMaxX, childX + childPlaced.extentMaxX)
            childMinY = min(childMinY, childY + childPlaced.minY)
            childMaxY = max(childMaxY, childY + childPlaced.maxY)
            childIDs += childPlaced.ids
        }

        let stackCenter = ((firstChildMid ?? 0) + lastChildMid) / 2
        let centerShift = node.size.height / 2 - stackCenter
        if centerShift != 0 {
            for id in childIDs {
                if let frame = frames[id] {
                    frames[id] = frame.offsetBy(dx: 0, dy: centerShift)
                }
            }
        }

        let finalTop = Contours.merge(
            ownTop, Contours.shift(childrenTop, dx: 0, dy: centerShift), take: min)
        let finalBottom = Contours.merge(
            ownBottom, Contours.shift(childrenBottom, dx: 0, dy: centerShift), take: max)

        return Placed(
            ids: [node.id] + childIDs,
            top: finalTop,
            bottom: finalBottom,
            extentMaxX: max(node.size.width, childExtentMaxX),
            minY: min(0, childMinY + centerShift),
            maxY: max(node.size.height, childMaxY + centerShift))
    }
}

/// Vertical org chart (down, or mirrored for up), obtained by transposing the
/// mind-map engine: children stack horizontally, subtrees separate along x.
enum OrgLayout {
    static func layout(root: LayoutNode, spacing: LayoutSpacing, mirror: Bool) -> LayoutResult {
        let transposed = transpose(root)
        let horizontal = MindmapLayout.layout(root: transposed, spacing: spacing, mirror: false)
        let rootHeight = root.size.height
        var frames: LayoutResult = [:]
        for (id, frame) in horizontal {
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

    private static func transpose(_ node: LayoutNode) -> LayoutNode {
        LayoutNode(
            id: node.id,
            size: CGSize(width: node.size.height, height: node.size.width),
            side: node.side,
            children: node.children.map(transpose))
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
            let side = MindmapLayout.layout(root: subtree, spacing: spacing, mirror: false)
            let (sideFrames, mid) = excludingRoot(side, rootID: root.id)
            let dy = rootMidY - mid
            for (id, frame) in sideFrames {
                frames[id] = frame.offsetBy(dx: 0, dy: dy)
            }
        }
        if !leftChildren.isEmpty {
            let subtree = LayoutNode(id: root.id, size: root.size, children: leftChildren)
            let side = MindmapLayout.layout(root: subtree, spacing: spacing, mirror: false)
            let (sideFrames, mid) = excludingRoot(side, rootID: root.id)
            let dy = rootMidY - mid
            for (id, frame) in sideFrames {
                frames[id] = CGRect(
                    x: rootWidth - frame.minX - frame.width,
                    y: frame.minY + dy,
                    width: frame.width,
                    height: frame.height)
            }
        }
        return frames
    }

    private static func excludingRoot(
        _ subtree: LayoutResult, rootID: String
    ) -> (frames: LayoutResult, midY: CGFloat) {
        var frames = subtree
        frames[rootID] = nil
        var minY = 0 as CGFloat
        var maxY = 0 as CGFloat
        var hasContent = false
        for frame in frames.values {
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
