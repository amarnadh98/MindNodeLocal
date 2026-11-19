import CoreGraphics
import Foundation

/// The node surface the one-sided engine consumes: identifier, measured
/// size and children. `LayoutNode` (a materialized tree) conforms
/// directly; the incremental engine's on-demand nodes conform by fetching
/// from a source, so an incremental pass materializes only the chain it
/// recomputes (see `IncrementalLayout`).
protocol EngineNode {
    var id: String { get }
    var size: CGSize { get }
    var children: [Self] { get }
}

extension LayoutNode: EngineNode {}

/// Shared contour machinery for the one-sided structures. Children are
/// stacked along one axis; consecutive siblings are separated by walking
/// the accumulated outer contour against the new subtree's inner contour
/// (van der Ploeg-style band merge over struct arrays, no class graph).
enum Contours {
    static func shift(_ bands: [Band], dx: CGFloat, dy: CGFloat) -> [Band] {
        bands.map { Band(lo: $0.lo + dx, hi: $0.hi + dx, value: $0.value + dy) }
    }

    /// Merges two band sets, taking the outer boundary value (`take` = max
    /// for bottom contours, min for top contours) wherever bands overlap.
    /// Both inputs must be sorted and internally non-overlapping — an
    /// invariant this function maintains for its outputs. Linear two-pointer
    /// sweep, no sorting, no intermediate allocations.
    static func merge(
        _ leftBands: [Band], _ rightBands: [Band], take: (CGFloat, CGFloat) -> CGFloat
    ) -> [Band] {
        guard !leftBands.isEmpty else { return rightBands }
        guard !rightBands.isEmpty else { return leftBands }

        var result: [Band] = []
        var i = 0
        var j = 0
        var consumedA: CGFloat = -.infinity
        var consumedB: CGFloat = -.infinity

        func emit(_ lo: CGFloat, _ hi: CGFloat, _ value: CGFloat) {
            guard hi > lo else { return }
            if let last = result.last, last.hi == lo, last.value == value {
                result[result.count - 1].hi = hi
            } else {
                result.append(Band(lo: lo, hi: hi, value: value))
            }
        }

        while i < leftBands.count, j < rightBands.count {
            let bandA = leftBands[i]
            let bandB = rightBands[j]
            let aStart = max(bandA.lo, consumedA)
            let bStart = max(bandB.lo, consumedB)
            let aEnd = bandA.hi
            let bEnd = bandB.hi

            if aStart < bStart {
                emit(aStart, min(aEnd, bStart), bandA.value)
                consumedA = min(aEnd, bStart)
            } else if bStart < aStart {
                emit(bStart, min(bEnd, aStart), bandB.value)
                consumedB = min(bEnd, aStart)
            }

            let overlapLo = max(aStart, bStart)
            let overlapHi = min(aEnd, bEnd)
            if overlapHi > overlapLo {
                emit(overlapLo, overlapHi, take(bandA.value, bandB.value))
                consumedA = overlapHi
                consumedB = overlapHi
            }

            if aEnd <= consumedA {
                i += 1
                consumedA = -.infinity
            }
            if bEnd <= consumedB {
                j += 1
                consumedB = -.infinity
            }
        }

        while i < leftBands.count {
            emit(max(leftBands[i].lo, consumedA), leftBands[i].hi, leftBands[i].value)
            consumedA = -.infinity
            i += 1
        }
        while j < rightBands.count {
            emit(max(rightBands[j].lo, consumedB), rightBands[j].hi, rightBands[j].value)
            consumedB = -.infinity
            j += 1
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

/// The per-level child-stacking core shared by every structure and by the
/// incremental engine (SPEC §9): places `node`'s subtree with the node
/// itself at the origin, separating consecutive children by walking the
/// accumulated outer contour against each child's inner contour.
///
/// `resolve` supplies each child's `Placed` — the full path recurses
/// directly, the incremental path consults the layout cache first — so
/// both produce bit-identical frames: a reused entry carries exactly the
/// values the recursion would have computed for the same inputs. `vertical`
/// transposes node sizes on the way in (the org-chart transform), so the
/// same arithmetic serves up/down as right/left.
enum TidyTree {
    static func place<N: EngineNode>(
        _ node: N,
        spacing: LayoutSpacing,
        depth: Int,
        vertical: Bool,
        resolve: (N, Int) -> Placed?
    ) -> Placed {
        let size =
            vertical
            ? CGSize(width: node.size.height, height: node.size.width)
            : node.size
        let children = node.children

        var ids: [String] = [node.id]
        var frames: [CGRect] = [CGRect(origin: .zero, size: size)]

        let ownTop = [Band(lo: 0, hi: size.width, value: 0)]
        let ownBottom = [Band(lo: 0, hi: size.width, value: size.height)]

        guard !children.isEmpty else {
            return Placed(
                ids: ids,
                frames: frames,
                top: ownTop,
                bottom: ownBottom,
                extentMaxX: size.width,
                minY: 0,
                maxY: size.height,
                predictedHeight: size.height)
        }

        let gapToChildren = depth == 0 ? spacing.rootGap : spacing.levelGap
        let siblingGap = depth == 0 ? spacing.subtreeGap : spacing.siblingGap
        let childX = size.width + gapToChildren

        var accumulatedBottom: [Band] = []
        var childrenTop: [Band] = []
        var childrenBottom: [Band] = []
        var childExtentMaxX: CGFloat = 0
        var childMinY: CGFloat = 0
        var childMaxY: CGFloat = 0
        var cursor: CGFloat = 0
        var firstChildMid: CGFloat?
        var lastChildMid: CGFloat = 0
        var predictedStack: CGFloat = 0
        var resolvedChildren = 0

        for child in children {
            guard var childPlaced = resolve(child, depth + 1) else { continue }
            let candidateTop = Contours.shift(childPlaced.top, dx: childX, dy: cursor)
            let dy = Contours.separation(
                accumulated: accumulatedBottom, incoming: candidateTop, gap: siblingGap)
            let childY = cursor + dy

            for index in childPlaced.frames.indices {
                childPlaced.frames[index] =
                    childPlaced.frames[index].offsetBy(dx: childX, dy: childY)
            }
            ids += childPlaced.ids
            frames += childPlaced.frames

            let shiftedTop = Contours.shift(childPlaced.top, dx: childX, dy: childY)
            let shiftedBottom = Contours.shift(childPlaced.bottom, dx: childX, dy: childY)
            accumulatedBottom = Contours.merge(accumulatedBottom, shiftedBottom, take: max)
            childrenTop = Contours.merge(childrenTop, shiftedTop, take: min)
            childrenBottom = Contours.merge(childrenBottom, shiftedBottom, take: max)

            cursor = childY + childPlaced.maxY
            let mid = childY + (childPlaced.minY + childPlaced.maxY) / 2
            firstChildMid = firstChildMid ?? mid
            lastChildMid = mid
            childExtentMaxX = max(childExtentMaxX, childX + childPlaced.extentMaxX)
            childMinY = min(childMinY, childY + childPlaced.minY)
            childMaxY = max(childMaxY, childY + childPlaced.maxY)
            // `BalancedLayout.predictedHeight`'s stacked-height estimate,
            // accumulated from the children's own estimates.
            if resolvedChildren > 0 {
                predictedStack += spacing.siblingGap
            }
            predictedStack += childPlaced.predictedHeight
            resolvedChildren += 1
        }

        let stackCenter = ((firstChildMid ?? 0) + lastChildMid) / 2
        let centerShift = size.height / 2 - stackCenter
        if centerShift != 0 {
            // The node's own frame (index 0) never shifts — only its
            // descendants move to center the stack.
            for index in frames.indices.dropFirst() {
                frames[index] = frames[index].offsetBy(dx: 0, dy: centerShift)
            }
        }

        let finalTop = Contours.merge(
            ownTop, Contours.shift(childrenTop, dx: 0, dy: centerShift), take: min)
        let finalBottom = Contours.merge(
            ownBottom, Contours.shift(childrenBottom, dx: 0, dy: centerShift), take: max)

        return Placed(
            ids: ids,
            frames: frames,
            top: finalTop,
            bottom: finalBottom,
            extentMaxX: max(size.width, childExtentMaxX),
            minY: min(0, childMinY + centerShift),
            maxY: max(size.height, childMaxY + centerShift),
            predictedHeight: max(size.height, predictedStack))
    }
}
