import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender

/// One connection prepared for the canvas (F-REL-1): endpoints resolved
/// to node-edge anchors, the control point, the hit-testing polyline and
/// the resolved style (theme + per-connection overrides). Model space,
/// y down.
public struct SceneConnection {
    public let id: String
    public let fromID: String
    public let toID: String
    /// The anchor on the source node's edge.
    public let from: CGPoint
    /// The anchor on the target node's edge.
    public let to: CGPoint
    /// The resolved control point (default bow + stored offset).
    public let control: CGPoint
    /// True for the straight line style.
    public let straight: Bool
    public let label: String?
    /// The label/handle position on the curve (t = 0.5).
    public let labelPosition: CGPoint
    public let style: ResolvedConnectionStyle
    /// The curve sampled at fixed parameters — the hit-test polyline.
    public let samples: [CGPoint]
    /// Conservative drawing/hit bounds (label included).
    public let bounds: CGRect

    /// The midpoint handle's position (F-REL-1): the t = 0.5 curve point.
    public var handlePosition: CGPoint { labelPosition }
}

/// One boundary prepared for the canvas (F-REL-2): the outline around
/// the visible member frames (members *and their descendants* — a
/// boundary groups whole subtrees), recomputed from the scene frames on
/// every build so it follows layout automatically.
public struct SceneBoundary {
    public let id: String
    public let title: String?
    /// The visible member ids (folded members are absent from the
    /// scene; a boundary with no visible member renders nothing).
    public let memberIDs: [String]
    public let style: ResolvedBoundaryStyle
    public let outline: CGPath
    public let bounds: CGRect
    /// The label's center — the outline's top-left "tab" position.
    public let titleCenter: CGPoint
}

/// One summary prepared for the canvas (F-REL-3): the brace between the
/// range members and the (real, laid-out) summary node. The summary
/// node itself is an ordinary `SceneNode`; this carries only the brace.
/// `rangeUnion`/`mirrored` restate the brace's inputs so layer-tree
/// raster comparisons stay exact without comparing `CGPath`s.
public struct SceneSummary {
    public let id: String
    public let parentID: String
    public let rangeIDs: [String]
    public let nodeID: String
    public let brace: CGPath
    public let bounds: CGRect
    public let axis: LayoutAxis
    /// The union of the range members' frames — the brace hugs its edge.
    public let rangeUnion: CGRect
    /// True when the brace (and its summary node) sit left/above.
    public let mirrored: Bool
    /// The brace's stroke: the theme's connection color at the theme's
    /// connection width.
    public let color: CGColor
    public let width: CGFloat
}

/// Builds the relation overlays of a scene (F-REL-1/2/3) from the model
/// and the scene's laid-out node frames. Pure and deterministic: the
/// same model + frames give the same overlays, so the overlays are
/// recomputed on every scene build (cheap — a few hundred small
/// allocations for a 500-connection map) and stay identical on the
/// full-rebuild and any future incremental path (both end at the same
/// frames; overlays derive from frames only).
public enum RelationGeometry {
    /// The hit tolerance for connections, in model points.
    public static let hitTolerance: CGFloat = 6
    /// The grab radius of the midpoint handle, in model points.
    public static let handleRadius: CGFloat = 8

    /// Builds every overlay of the scene. `rootAxes` maps each root id
    /// to its structure axis (summary braces go right for horizontal
    /// layouts, below for org charts).
    public static func build(
        model: MapModel,
        theme: Theme,
        variant: ThemeVariant,
        nodes: [String: SceneNode],
        rootAxes: [String: LayoutAxis],
        rootOf: [String: String],
        measurer: TextMeasurer
    ) -> (connections: [SceneConnection], boundaries: [SceneBoundary], summaries: [SceneSummary]) {
        var connections: [SceneConnection] = []
        for connection in model.connections ?? [] {
            guard let fromNode = nodes[connection.from], let toNode = nodes[connection.to] else {
                continue
            }
            connections.append(
                makeConnection(
                    connection, theme: theme, variant: variant,
                    fromNode: fromNode, toNode: toNode, measurer: measurer))
        }

        var boundaries: [SceneBoundary] = []
        for boundary in model.boundaries ?? [] {
            // A boundary groups whole subtrees: the outline wraps the
            // members and every descendant that is currently visible
            // (folded descendants are simply absent from the scene).
            var frames: [CGRect] = []
            var memberIDs: [String] = []
            var stack = boundary.nodes
            var visited = Set<String>()
            while let id = stack.popLast() {
                guard visited.insert(id).inserted, let node = nodes[id] else { continue }
                memberIDs.append(id)
                frames.append(node.frame)
                stack.append(contentsOf: model.nodes[id]?.children ?? [])
            }
            guard !frames.isEmpty else { continue }
            let style = theme.resolvedBoundaryStyle(variant: variant, overrides: boundary.style)
            let outline = RelationPath.boundaryOutline(
                frames: frames, padding: style.padding, cornerRadius: style.cornerRadius,
                organic: style.organic)
            let outlineBounds = outline.boundingBoxOfPath
            var titleCenter = outlineBounds.origin
            if let title = boundary.title, !title.isEmpty {
                let titleSize = measurer.nodeTitleSize(
                    NodeTitle(text: title), font: RelationRenderer.boundaryTitleFont, maxWidth: 400)
                titleCenter = CGPoint(
                    x: outlineBounds.minX + style.padding + titleSize.width / 2,
                    y: outlineBounds.minY + style.padding + titleSize.height / 2)
            }
            boundaries.append(
                SceneBoundary(
                    id: boundary.id,
                    title: boundary.title,
                    memberIDs: memberIDs.sorted(),
                    style: style,
                    outline: outline,
                    bounds: outlineBounds,
                    titleCenter: titleCenter))
        }

        var summaries: [SceneSummary] = []
        for summary in model.summaries ?? [] {
            // The brace needs the whole range and the summary node
            // visible; a folded-away range member hides the brace.
            guard let node = nodes[summary.node], let parent = nodes[summary.parent] else { continue }
            var rangeFrames: [CGRect] = []
            var anchors: [CGPoint] = []
            for rangeID in summary.range {
                guard let rangeNode = nodes[rangeID] else { continue }
                rangeFrames.append(rangeNode.frame)
                anchors.append(
                    CGPoint(x: rangeNode.frame.midX, y: rangeNode.frame.midY))
            }
            guard rangeFrames.count == summary.range.count, !rangeFrames.isEmpty else { continue }
            let range = rangeFrames.reduce(CGRect.null) { $0.union($1) }
            let axis = rootAxis(of: summary.parent, rootAxes: rootAxes, rootOf: rootOf)
            let mirrored = Self.mirrored(range: range, parent: parent.frame, axis: axis)
            let brace = RelationPath.summaryBrace(
                first: anchors[0], last: anchors[anchors.count - 1], range: range,
                axis: axis, mirrored: mirrored)
            let stroke = theme.resolvedConnectionStyle(variant: variant)
            summaries.append(
                SceneSummary(
                    id: summary.id,
                    parentID: summary.parent,
                    rangeIDs: summary.range,
                    nodeID: summary.node,
                    brace: brace,
                    bounds: brace.boundingBoxOfPath.union(node.frame),
                    axis: axis,
                    rangeUnion: range,
                    mirrored: mirrored,
                    color: stroke.color,
                    width: stroke.width))
        }

        return (connections: connections, boundaries: boundaries, summaries: summaries)
    }

    /// The layout axis of the root owning `id`, horizontal by default.
    private static func rootAxis(
        of id: String, rootAxes: [String: LayoutAxis], rootOf: [String: String]
    ) -> LayoutAxis {
        guard let root = rootOf[id] else { return .horizontal }
        return rootAxes[root] ?? .horizontal
    }

    /// Which side of the parent a brace (and its summary node) lives on:
    /// right/below, or mirrored when the range sits left/above the
    /// parent (the balanced map's left side, the org-up chart).
    static func mirrored(range: CGRect, parent: CGRect, axis: LayoutAxis) -> Bool {
        switch axis {
        case .horizontal:
            range.midX < parent.midX
        case .vertical:
            range.midY < parent.midY
        }
    }

    /// Assembles one connection: edge anchors facing each other, the
    /// resolved control point, the sampled hit polyline, the label
    /// position and conservative bounds.
    static func makeConnection(
        _ connection: Connection,
        theme: Theme,
        variant: ThemeVariant,
        fromNode: SceneNode,
        toNode: SceneNode,
        measurer: TextMeasurer
    ) -> SceneConnection {
        let style = theme.resolvedConnectionStyle(variant: variant, overrides: connection.style)
        let fromFrame = fromNode.frame
        let toFrame = toNode.frame
        // Anchors face each other along the dominant axis — the same
        // anchor convention branches use (underline shapes anchor at
        // the underline's end).
        let dx = toFrame.midX - fromFrame.midX
        let dy = toFrame.midY - fromFrame.midY
        let direction: BranchDirection
        let incoming: BranchDirection
        if abs(dx) >= abs(dy) {
            let rightward = dx >= 0
            direction = rightward ? .right : .left
            incoming = direction
        } else {
            let downward = dy >= 0
            direction = downward ? .down : .up
            incoming = direction
        }
        let from = NodeRenderer.outgoingAnchor(
            style: fromNode.style, frame: fromFrame, direction: direction)
        let to = NodeRenderer.incomingAnchor(
            style: toNode.style, frame: toFrame, direction: incoming)
        let control = RelationPath.controlPoint(from: from, to: to, storedOffset: connection.control)
        let straight = style.lineStyle == .straight
        let labelPosition = RelationPath.point(
            onConnection: from, to: to, control: control, straight: straight, parameter: 0.5)
        let samples = RelationPath.samples(from: from, to: to, control: control, straight: straight)

        var bounds = CGRect.null
        for sample in samples {
            bounds = bounds.union(CGRect(origin: sample, size: CGSize(width: 0.01, height: 0.01)))
        }
        let margin = style.width * 4 + 8
        bounds = bounds.insetBy(dx: -margin, dy: -margin)
        if let label = connection.label, !label.isEmpty {
            let labelSize = measurer.nodeTitleSize(
                NodeTitle(text: label), font: RelationRenderer.connectionLabelFont, maxWidth: 400)
            bounds = bounds.union(
                CGRect(
                    origin: CGPoint(
                        x: labelPosition.x - labelSize.width / 2,
                        y: labelPosition.y - labelSize.height / 2),
                    size: labelSize))
        }
        return SceneConnection(
            id: connection.id,
            fromID: connection.from,
            toID: connection.to,
            from: from,
            to: to,
            control: control,
            straight: straight,
            label: connection.label,
            labelPosition: labelPosition,
            style: style,
            samples: samples,
            bounds: bounds)
    }

    // MARK: hit-testing (pure — the view and the tests share it)

    /// The connection whose stroke passes within `tolerance` of
    /// `point`, nearest first. The sampled polyline makes this O(n)
    /// per connection with a bounds prefilter.
    public static func connectionID(
        at point: CGPoint, tolerance: CGFloat, in connections: [SceneConnection]
    ) -> String? {
        var best: (id: String, distance: CGFloat)?
        for connection in connections {
            let padded = connection.bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard padded.contains(point) else { continue }
            let distance = distance(from: point, toPolyline: connection.samples)
            if distance <= tolerance, distance < (best?.distance ?? tolerance + 1) {
                best = (connection.id, distance)
            }
        }
        return best?.id
    }

    /// The connection whose midpoint handle sits within
    /// `handleRadius` of `point`, if any (F-REL-1's draggable handle).
    public static func connectionWithHandle(
        at point: CGPoint, radius: CGFloat, in connections: [SceneConnection]
    ) -> String? {
        var best: (id: String, distance: CGFloat)?
        for connection in connections {
            let distance = hypot(
                connection.handlePosition.x - point.x, connection.handlePosition.y - point.y)
            if distance <= radius, distance < (best?.distance ?? radius + 1) {
                best = (connection.id, distance)
            }
        }
        return best?.id
    }

    /// The smallest distance from `point` to the sampled polyline.
    public static func distance(from point: CGPoint, toPolyline samples: [CGPoint]) -> CGFloat {
        guard samples.count > 1 else {
            guard let only = samples.first else { return .greatestFiniteMagnitude }
            return hypot(only.x - point.x, only.y - point.y)
        }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 1..<samples.count {
            let distance = distance(from: point, toSegment: (samples[index - 1], samples[index]))
            if distance < best {
                best = distance
            }
        }
        return best
    }

    /// Point-to-segment distance.
    public static func distance(from point: CGPoint, toSegment segment: (CGPoint, CGPoint)) -> CGFloat {
        let start = segment.0
        let end = segment.1
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared <= 0.000_001 {
            return hypot(start.x - point.x, start.y - point.y)
        }
        let clamp = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        let projected = CGPoint(x: start.x + dx * clamp, y: start.y + dy * clamp)
        return hypot(projected.x - point.x, projected.y - point.y)
    }

    /// The stored control offset that puts a connection's handle at
    /// `handlePoint` (the model stores the offset from the default
    /// control, SPEC §8.2) — the exact inversion of the curve math, so
    /// a dragged handle lands where the cursor dropped.
    public static func controlOffset(
        for connection: SceneConnection, handlePoint: CGPoint
    ) -> ModelOffset {
        RelationPath.controlOffset(
            forHandle: handlePoint, from: connection.from, to: connection.to)
    }
}
