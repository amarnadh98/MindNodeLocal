import CoreGraphics

/// Branch connector geometry (SPEC §7.4). All functions take model-space
/// points and return paths centered on the anchor-to-anchor line.
public enum BranchPath {
    /// The default curved branch: a cubic Bézier with control points on the
    /// horizontal through `from` and `to` (vertical layouts use the same
    /// formula with the axes swapped, via `axis`).
    public static func cubic(
        from: CGPoint, to: CGPoint, axis: LayoutAxis = .horizontal
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        if axis == .horizontal {
            let dx = to.x - from.x
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + dx * 0.5, y: from.y),
                control2: CGPoint(x: to.x - dx * 0.5, y: to.y))
        } else {
            let dy = to.y - from.y
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x, y: from.y + dy * 0.5),
                control2: CGPoint(x: to.x, y: to.y - dy * 0.5))
        }
        return path
    }

    public static func straight(from: CGPoint, to: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }

    /// Elbow connector with rounded corners (F-LAY-15): leaves `from`
    /// along the layout axis, turns twice, and enters `to` along the axis.
    public static func elbow(
        from: CGPoint, to: CGPoint, axis: LayoutAxis = .horizontal, cornerRadius: CGFloat = 8
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        let radius = max(0, min(cornerRadius, abs(to.x - from.x) / 2, abs(to.y - from.y) / 2))
        if axis == .horizontal {
            let midX = from.x + (to.x - from.x) * 0.5
            path.addArc(
                tangent1End: CGPoint(x: midX, y: from.y),
                tangent2End: CGPoint(x: midX, y: to.y), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: midX, y: to.y),
                tangent2End: to, radius: radius)
        } else {
            let midY = from.y + (to.y - from.y) * 0.5
            path.addArc(
                tangent1End: CGPoint(x: from.x, y: midY),
                tangent2End: CGPoint(x: to.x, y: midY), radius: radius)
            path.addArc(
                tangent1End: CGPoint(x: to.x, y: midY),
                tangent2End: to, radius: radius)
        }
        return path
    }

    /// Tapered branch as a closed polygon: the centerline cubic is sampled
    /// at 16 points, offset by ±half the (linearly interpolated) width
    /// along its normals, closed with round caps (SPEC §7.4).
    public static func tapered(
        from: CGPoint, to: CGPoint, startWidth: CGFloat, endWidth: CGFloat,
        axis: LayoutAxis = .horizontal
    ) -> CGPath {
        let samples = 16
        var centerline: [CGPoint] = []
        centerline.reserveCapacity(samples)
        for step in 0..<samples {
            let fraction = CGFloat(step) / CGFloat(samples - 1)
            centerline.append(cubicPoint(from: from, to: to, t: fraction, axis: axis))
        }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(samples)
        right.reserveCapacity(samples)
        for (index, point) in centerline.enumerated() {
            let fraction = CGFloat(index) / CGFloat(samples - 1)
            let halfWidth = (startWidth + (endWidth - startWidth) * fraction) / 2
            let next = centerline[min(index + 1, samples - 1)]
            let previous = centerline[max(index - 1, 0)]
            let direction = CGPoint(
                x: next.x - previous.x, y: next.y - previous.y)
            let length = max(hypot(direction.x, direction.y), 0.0001)
            let normal = CGPoint(x: -direction.y / length, y: direction.x / length)
            left.append(
                CGPoint(x: point.x + normal.x * halfWidth, y: point.y + normal.y * halfWidth))
            right.append(
                CGPoint(x: point.x - normal.x * halfWidth, y: point.y - normal.y * halfWidth))
        }

        // Flat ends, each tucked a hair into its node: a round cap pokes
        // through an outlined node's border as a bulb, where a flat end
        // meets the node edge flush (the border or fill hides the tuck).
        tuck(&left, &right)
        let path = CGMutablePath()
        guard let firstLeft = left.first else { return path }
        path.move(to: firstLeft)
        for point in left.dropFirst() {
            path.addLine(to: point)
        }
        for point in right.reversed() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    /// How far a flat branch end runs into its node.
    static let endTuck: CGFloat = 0.75

    /// Pushes both end edges of the offset polylines outward along the
    /// branch's tangent at that end.
    private static func tuck(_ left: inout [CGPoint], _ right: inout [CGPoint]) {
        guard left.count > 1, right.count > 1 else { return }
        func push(_ points: inout [CGPoint], index: Int, toward other: Int) {
            let end = points[index]
            let inner = points[other]
            let length = max(hypot(end.x - inner.x, end.y - inner.y), 0.0001)
            points[index] = CGPoint(
                x: end.x + (end.x - inner.x) / length * endTuck,
                y: end.y + (end.y - inner.y) / length * endTuck)
        }
        push(&left, index: 0, toward: 1)
        push(&right, index: 0, toward: 1)
        push(&left, index: left.count - 1, toward: left.count - 2)
        push(&right, index: right.count - 1, toward: right.count - 2)
    }

    private static func cubicPoint(
        from: CGPoint, to: CGPoint, t fraction: CGFloat, axis: LayoutAxis
    ) -> CGPoint {
        if axis == .horizontal {
            let dx = to.x - from.x
            return bezier(
                from,
                CGPoint(x: from.x + dx * 0.5, y: from.y),
                CGPoint(x: to.x - dx * 0.5, y: to.y),
                to,
                fraction)
        }
        let dy = to.y - from.y
        return bezier(
            from,
            CGPoint(x: from.x, y: from.y + dy * 0.5),
            CGPoint(x: to.x, y: to.y - dy * 0.5),
            to,
            fraction)
    }

    private static func bezier(
        _ start: CGPoint, _ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint,
        _ fraction: CGFloat
    ) -> CGPoint {
        let inverse = 1 - fraction
        let startWeight = inverse * inverse * inverse
        let control1Weight = 3 * inverse * inverse * fraction
        let control2Weight = 3 * inverse * fraction * fraction
        let endWeight = fraction * fraction * fraction
        return CGPoint(
            x: startWeight * start.x + control1Weight * control1.x
                + control2Weight * control2.x + endWeight * end.x,
            y: startWeight * start.y + control1Weight * control1.y
                + control2Weight * control2.y + endWeight * end.y)
    }
}

/// The layout axis a branch follows (SPEC §7.4: vertical layouts use the
/// same formula with the axes swapped).
public enum LayoutAxis: Sendable, Hashable {
    case horizontal
    case vertical
}
