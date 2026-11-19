import CoreGraphics
import Foundation
import MapCore
import MapLayout

/// Pure geometry for the cross-node relations (F-REL-1/2/3): connection
/// curves, boundary outlines and summary braces. Everything is a pure
/// function of points, so the canvas, the exporter and tests all share
/// one deterministic source of truth (SPEC §9's determinism rule).
///
/// Coordinate convention: model space, y growing down (the canvas and
/// `TreeLayout` frame space).
public enum RelationPath {
    /// The default connection bow (F-REL-1): 15% of the endpoint
    /// distance, perpendicular to the segment. A double-click on the
    /// midpoint handle returns to this.
    public static let defaultBowFraction: CGFloat = 0.15

    /// The default control point of a connection between two anchors:
    /// the segment midpoint offset perpendicular by the default bow.
    public static func defaultControl(from: CGPoint, to: CGPoint) -> CGPoint {
        let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        // The right-hand normal of the from→to direction: deterministic
        // (same endpoints, same bow) and never zero for distinct points.
        return CGPoint(
            x: midpoint.x - dy / length * length * defaultBowFraction,
            y: midpoint.y + dx / length * length * defaultBowFraction)
    }

    /// The control point a connection renders with: the default control
    /// plus the model's stored drag offset (`Connection.control`, SPEC
    /// §8.2 — the model stores the *offset*, never the absolute point,
    /// so the curve follows its endpoints through relayouts).
    public static func controlPoint(
        from: CGPoint, to: CGPoint, storedOffset: ModelOffset?
    ) -> CGPoint {
        let base = defaultControl(from: from, to: to)
        guard let offset = storedOffset else { return base }
        return CGPoint(x: base.x + offset.x, y: base.y + offset.y)
    }

    /// The cubic Bézier control pair for a curve through `control`:
    /// `c1 = from + 2/3·(control − from)`, `c2 = to + 2/3·(control − to)`,
    /// which puts the curve's t = 0.5 point exactly at the midpoint of
    /// the segment and the control — i.e. the midpoint *handle* the user
    /// drags lies on the curve.
    public static func bezierControls(
        from: CGPoint, to: CGPoint, control: CGPoint
    ) -> (c1: CGPoint, c2: CGPoint) {
        (
            c1: CGPoint(
                x: from.x + (control.x - from.x) * 2 / 3,
                y: from.y + (control.y - from.y) * 2 / 3),
            c2: CGPoint(
                x: to.x + (control.x - to.x) * 2 / 3,
                y: to.y + (control.y - to.y) * 2 / 3)
        )
    }

    /// The connection's stroke path: a straight segment, or the cubic
    /// through the control point (F-REL-1's curve/straight options).
    public static func connectionPath(
        from: CGPoint, to: CGPoint, control: CGPoint, straight: Bool
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        if straight {
            path.addLine(to: to)
        } else {
            let controls = bezierControls(from: from, to: to, control: control)
            path.addCurve(to: to, control1: controls.c1, control2: controls.c2)
        }
        return path
    }

    /// A point on the connection curve at parameter `parameter` (0…1).
    /// Straight connections interpolate linearly; curves evaluate the
    /// cubic.
    public static func point(
        onConnection from: CGPoint, to: CGPoint, control: CGPoint, straight: Bool, parameter: CGFloat
    ) -> CGPoint {
        let clamped = min(max(parameter, 0), 1)
        if straight {
            return CGPoint(
                x: from.x + (to.x - from.x) * clamped,
                y: from.y + (to.y - from.y) * clamped)
        }
        let controls = bezierControls(from: from, to: to, control: control)
        let inverse = 1 - clamped
        let weight0 = inverse * inverse * inverse
        let weight1 = 3 * inverse * inverse * clamped
        let weight2 = 3 * inverse * clamped * clamped
        let weight3 = clamped * clamped * clamped
        return CGPoint(
            x: weight0 * from.x + weight1 * controls.c1.x + weight2 * controls.c2.x + weight3 * to.x,
            y: weight0 * from.y + weight1 * controls.c1.y + weight2 * controls.c2.y + weight3 * to.y)
    }

    /// The unit tangent of the connection curve at parameter
    /// `parameter`, heading from `from` (0) toward `to` (1). Arrowheads
    /// orient by it.
    public static func tangent(
        onConnection from: CGPoint, to: CGPoint, control: CGPoint, straight: Bool, parameter: CGFloat
    ) -> CGPoint {
        if straight {
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(hypot(dx, dy), 0.001)
            return CGPoint(x: dx / length, y: dy / length)
        }
        let controls = bezierControls(from: from, to: to, control: control)
        let clamped = min(max(parameter, 0), 1)
        let inverse = 1 - clamped
        let dx =
            3 * inverse * inverse * (controls.c1.x - from.x)
            + 6 * inverse * clamped * (controls.c2.x - controls.c1.x)
            + 3 * clamped * clamped * (to.x - controls.c2.x)
        let dy =
            3 * inverse * inverse * (controls.c1.y - from.y)
            + 6 * inverse * clamped * (controls.c2.y - controls.c1.y)
            + 3 * clamped * clamped * (to.y - controls.c2.y)
        let length = max(hypot(dx, dy), 0.001)
        return CGPoint(x: dx / length, y: dy / length)
    }

    /// The connection's hit-testing polyline: the curve sampled at fixed
    /// parameter steps (a deterministic, precomputable approximation of
    /// the stroke for tolerance-based hit tests).
    public static func samples(
        from: CGPoint, to: CGPoint, control: CGPoint, straight: Bool, steps: Int = 24
    ) -> [CGPoint] {
        guard steps > 0 else { return [from, to] }
        return (0...steps).map { step in
            point(
                onConnection: from, to: to, control: control, straight: straight,
                parameter: CGFloat(step) / CGFloat(steps))
        }
    }

    /// One arrowhead: a filled triangle at `tip`, opening backward along
    /// `direction` (the unit tangent, heading *into* the tip).
    public static func arrowhead(
        at tip: CGPoint, direction: CGPoint, width: CGFloat
    ) -> CGPath {
        let length = max(width * 3 + 3, 6)
        let half = max(width * 1.25 + 1.5, 3)
        let back = CGPoint(x: tip.x - direction.x * length, y: tip.y - direction.y * length)
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: back.x + normal.x * half, y: back.y + normal.y * half))
        path.addLine(to: CGPoint(x: back.x - normal.x * half, y: back.y - normal.y * half))
        path.closeSubpath()
        return path
    }

    /// The stored control offset that puts a connection's *handle* (the
    /// curve's t = 0.5 point) at `handle` — the inversion of the curve
    /// math above: `handle = (segment midpoint + control) / 2`, so the
    /// control that passes the handle through it is
    /// `2·handle − midpoint` (SPEC §8.2: the model stores the offset
    /// from the default control, never the absolute point).
    public static func controlOffset(
        forHandle handle: CGPoint, from: CGPoint, to: CGPoint
    ) -> ModelOffset {
        let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let control = CGPoint(x: 2 * handle.x - midpoint.x, y: 2 * handle.y - midpoint.y)
        let base = defaultControl(from: from, to: to)
        return ModelOffset(x: control.x - base.x, y: control.y - base.y)
    }

    /// The control point whose curve passes its handle through
    /// `handle` (the un-offset half of `controlOffset`).
    public static func controlForHandle(
        _ handle: CGPoint, from: CGPoint, to: CGPoint
    ) -> CGPoint {
        let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        return CGPoint(x: 2 * handle.x - midpoint.x, y: 2 * handle.y - midpoint.y)
    }

    // MARK: boundaries (F-REL-2)

    /// The boundary outline around the member frames plus padding: a
    /// rounded rect over the combined frame (the default), or the
    /// "organic" smoothed hull of the padded frames. Pure and
    /// deterministic — same frames, same path — so it can be recomputed
    /// on every scene build and stays correct through incremental
    /// relayouts.
    public static func boundaryOutline(
        frames: [CGRect], padding: CGFloat, cornerRadius: CGFloat, organic: Bool
    ) -> CGPath {
        guard !frames.isEmpty else { return CGPath(rect: .zero, transform: nil) }
        if !organic {
            var combined = CGRect.null
            for frame in frames {
                combined = combined.union(frame)
            }
            let padded = combined.insetBy(dx: -padding, dy: -padding)
            return CGPath(
                roundedRect: padded,
                cornerWidth: max(cornerRadius, 0.01),
                cornerHeight: max(cornerRadius, 0.01),
                transform: nil)
        }
        var corners: [CGPoint] = []
        corners.reserveCapacity(frames.count * 4)
        for frame in frames {
            let padded = frame.insetBy(dx: -padding, dy: -padding)
            corners.append(CGPoint(x: padded.minX, y: padded.minY))
            corners.append(CGPoint(x: padded.maxX, y: padded.minY))
            corners.append(CGPoint(x: padded.maxX, y: padded.maxY))
            corners.append(CGPoint(x: padded.minX, y: padded.maxY))
        }
        return roundedHull(around: convexHull(of: corners), radius: cornerRadius)
    }

    /// Andrew's monotone chain convex hull, ordered clockwise in the
    /// y-down convention and starting at the lowest-leftmost point so
    /// the output is deterministic.
    public static func convexHull(of points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        var lower: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2,
                cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0
            {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0
            {
                upper.removeLast()
            }
            upper.append(point)
        }
        let hull = lower.dropLast() + upper.dropLast()
        return hull.isEmpty ? sorted : Array(hull)
    }

    /// A polygon with every corner rounded by quadratic curves of
    /// `radius` (clamped to half the shorter incident edge, so tiny
    /// hulls stay smooth). This is the "organic" boundary smoothing.
    public static func roundedHull(around hull: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard hull.count > 2 else {
            for (index, point) in hull.enumerated() {
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            if hull.count == 2 {
                path.closeSubpath()
            }
            return path
        }
        let count = hull.count
        for index in 0..<count {
            let previous = hull[(index + count - 1) % count]
            let vertex = hull[index]
            let next = hull[(index + 1) % count]
            let inLength = min(radius, hypot(vertex.x - previous.x, vertex.y - previous.y) / 2)
            let outLength = min(radius, hypot(next.x - vertex.x, next.y - vertex.y) / 2)
            let entry = moved(vertex, toward: previous, distance: inLength)
            let exit = moved(vertex, toward: next, distance: outLength)
            if index == 0 {
                path.move(to: entry)
            } else {
                path.addLine(to: entry)
            }
            // The quadratic's control is the corner itself: the curve
            // pulls toward the vertex, giving the smooth hull its bulge.
            path.addQuadCurve(to: exit, control: vertex)
        }
        path.closeSubpath()
        return path
    }

    private static func cross(
        _ origin: CGPoint, _ first: CGPoint, _ second: CGPoint
    ) -> CGFloat {
        (first.x - origin.x) * (second.y - origin.y)
            - (first.y - origin.y) * (second.x - origin.x)
    }

    /// `vertex` stepped `distance` toward `other` along their connecting
    /// line (the rounded-hull corner tangent points).
    private static func moved(
        _ vertex: CGPoint, toward other: CGPoint, distance: CGFloat
    ) -> CGPoint {
        let dx = other.x - vertex.x
        let dy = other.y - vertex.y
        let length = max(hypot(dx, dy), 0.001)
        return CGPoint(x: vertex.x + dx / length * distance, y: vertex.y + dy / length * distance)
    }

    // MARK: summary braces (F-REL-3)

    /// How far the brace sits from the range's edge.
    public static let braceInset: CGFloat = 12
    /// How far the brace's mid point reaches toward the summary node.
    public static let bracePoint: CGFloat = 10

    /// The brace connecting a sibling range to its summary node: to the
    /// right for horizontal layouts (left when `mirrored` — the balanced
    /// map's left side), below for vertical ones (above when mirrored,
    /// the org-up chart) — SPEC F-REL-3. `first` and `last` are the
    /// anchor points on the first and last range members (their
    /// midpoints along the brace axis); the brace hugs the range's
    /// combined edge between them and its mid point reaches toward the
    /// summary node.
    public static func summaryBrace(
        first: CGPoint, last: CGPoint, range: CGRect, axis: LayoutAxis, mirrored: Bool = false
    ) -> CGPath {
        let path = CGMutablePath()
        let sign: CGFloat = mirrored ? -1 : 1
        switch axis {
        case .horizontal:
            let x = (mirrored ? range.minX - braceInset : range.maxX + braceInset)
            let hook: CGFloat = 8 * sign
            let span = abs(last.y - first.y)
            let arm = min(12, span / 4)
            let midY = (first.y + last.y) / 2
            path.move(to: CGPoint(x: x - hook, y: first.y))
            path.addLine(to: CGPoint(x: x, y: first.y))
            path.addLine(to: CGPoint(x: x, y: first.y + arm))
            path.addQuadCurve(
                to: CGPoint(x: x + sign * bracePoint, y: midY), control: CGPoint(x: x, y: midY))
            path.addQuadCurve(
                to: CGPoint(x: x, y: last.y - arm), control: CGPoint(x: x, y: midY))
            path.addLine(to: CGPoint(x: x, y: last.y))
            path.addLine(to: CGPoint(x: x - hook, y: last.y))
        case .vertical:
            let y = (mirrored ? range.minY - braceInset : range.maxY + braceInset)
            let hook: CGFloat = 8 * sign
            let span = abs(last.x - first.x)
            let arm = min(12, span / 4)
            let midX = (first.x + last.x) / 2
            path.move(to: CGPoint(x: first.x, y: y - hook))
            path.addLine(to: CGPoint(x: first.x, y: y))
            path.addLine(to: CGPoint(x: first.x + arm, y: y))
            path.addQuadCurve(
                to: CGPoint(x: midX, y: y + sign * bracePoint), control: CGPoint(x: midX, y: y))
            path.addQuadCurve(to: CGPoint(x: last.x - arm, y: y), control: CGPoint(x: midX, y: y))
            path.addLine(to: CGPoint(x: last.x, y: y))
            path.addLine(to: CGPoint(x: last.x, y: y - hook))
        }
        return path
    }

    /// The brace's main-line coordinate (x for horizontal, y for
    /// vertical axes) — the anchor summary-node placement measures from
    /// (F-REL-3: the node sits just beyond the brace's mid point).
    public static func braceAnchor(range: CGRect, axis: LayoutAxis, mirrored: Bool) -> CGFloat {
        switch axis {
        case .horizontal:
            mirrored ? range.minX - braceInset : range.maxX + braceInset
        case .vertical:
            mirrored ? range.minY - braceInset : range.maxY + braceInset
        }
    }

    /// How far beyond the brace's mid point the summary node's near edge
    /// sits.
    public static let summaryNodeGap: CGFloat = 8

    /// The summary node's placement for a brace over `range` (F-REL-3,
    /// ADR-0026): aligned with the range's center along the brace axis,
    /// just beyond the brace's mid point. Pure — recomputed on every
    /// scene build so the summary follows layout automatically.
    public static func summaryNodeFrame(
        range: CGRect, axis: LayoutAxis, mirrored: Bool, size: CGSize
    ) -> CGRect {
        let anchor = braceAnchor(range: range, axis: axis, mirrored: mirrored)
        let offset = bracePoint + summaryNodeGap
        switch axis {
        case .horizontal:
            let x = mirrored ? anchor - offset - size.width : anchor + offset
            return CGRect(x: x, y: range.midY - size.height / 2, width: size.width, height: size.height)
        case .vertical:
            let y = mirrored ? anchor - offset - size.height : anchor + offset
            return CGRect(x: range.midX - size.width / 2, y: y, width: size.width, height: size.height)
        }
    }
}
