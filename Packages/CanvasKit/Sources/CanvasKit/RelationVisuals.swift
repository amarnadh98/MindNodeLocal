import CoreGraphics
import Foundation
import MapCore
import MapRender

/// One relation overlay as the layer tree sees it: the scene value plus
/// its selection state, unified so connections, boundaries and summary
/// braces share one pooled layer type and one culling path.
enum RelationOverlay {
    case connection(SceneConnection, selected: Bool)
    case boundary(SceneBoundary)
    case summary(SceneSummary)

    var id: String {
        switch self {
        case .connection(let connection, _): connection.id
        case .boundary(let boundary): boundary.id
        case .summary(let summary): summary.id
        }
    }

    /// Conservative drawing bounds in model space.
    var bounds: CGRect {
        switch self {
        case .connection(let connection, _): connection.bounds
        case .boundary(let boundary): boundary.bounds
        case .summary(let summary): summary.bounds
        }
    }

    /// The layer z-order slot: boundaries paint under branches (-1),
    /// braces over branches but under nodes, connections over nodes.
    var zPosition: CGFloat {
        switch self {
        case .connection: 1.5
        case .boundary: -1
        case .summary: 0.5
        }
    }
}

/// Pure conversion from scene overlays to `MapRender` drawing visuals —
/// the bridge between `RelationGeometry`'s scene values and the shared
/// `RelationRenderer` drawing path (canvas rasters and export call the
/// same functions, SPEC §11's single-renderer rule).
enum RelationVisuals {
    /// The boundary visual (`RelationRenderer` needs no measurer for
    /// boundaries — the title center is pre-measured in the scene).
    static func boundaryVisual(_ boundary: SceneBoundary) -> BoundaryVisual {
        BoundaryVisual(
            id: boundary.id,
            outline: boundary.outline,
            bounds: boundary.bounds,
            fillColor: boundary.style.fill,
            strokeColor: boundary.style.stroke,
            lineWidth: boundary.style.lineWidth,
            dash: boundary.style.dash,
            title: boundary.title,
            titleCenter: boundary.titleCenter,
            titleColor: boundary.style.stroke,
            titleFont: RelationRenderer.boundaryTitleFont)
    }

    /// The summary brace visual.
    static func summaryVisual(_ summary: SceneSummary) -> SummaryVisual {
        SummaryVisual(
            id: summary.id, brace: summary.brace, bounds: summary.bounds,
            color: summary.color, lineWidth: summary.width)
    }

    /// The connection visual, with a selection halo when selected.
    static func connectionVisual(
        _ connection: SceneConnection, selected: Bool, halo: CGColor
    ) -> ConnectionVisual {
        visual(
            for: RelationOverlay.connection(connection, selected: selected),
            measurer: SceneRenderer.sharedMeasurer, halo: halo
        ).connectionValue
    }

    /// Builds the drawing visual for one overlay. `halo` is the
    /// selection color a selected connection renders under its stroke.
    static func visual(
        for overlay: RelationOverlay, measurer: TextMeasurer, halo: CGColor
    ) -> RelationDrawVisual {
        switch overlay {
        case .connection(let connection, let selected):
            let path = RelationPath.connectionPath(
                from: connection.from, to: connection.to, control: connection.control,
                straight: connection.straight)
            let arrowheads = connection.style.arrowheads
            let arrowStart: CGPath?
            let arrowEnd: CGPath?
            if connection.straight {
                let dx = connection.to.x - connection.from.x
                let dy = connection.to.y - connection.from.y
                let length = max(hypot(dx, dy), 0.001)
                let direction = CGPoint(x: dx / length, y: dy / length)
                arrowStart = RelationPath.arrowhead(
                    at: connection.from, direction: CGPoint(x: -direction.x, y: -direction.y),
                    width: connection.style.width)
                arrowEnd = RelationPath.arrowhead(
                    at: connection.to, direction: direction, width: connection.style.width)
            } else {
                let startTangent = RelationPath.tangent(
                    onConnection: connection.from, to: connection.to, control: connection.control,
                    straight: false, parameter: 0)
                let endTangent = RelationPath.tangent(
                    onConnection: connection.from, to: connection.to, control: connection.control,
                    straight: false, parameter: 1)
                arrowStart = RelationPath.arrowhead(
                    at: connection.from, direction: CGPoint(x: -startTangent.x, y: -startTangent.y),
                    width: connection.style.width)
                arrowEnd = RelationPath.arrowhead(
                    at: connection.to, direction: endTangent, width: connection.style.width)
            }
            return .connection(
                ConnectionVisual(
                    id: connection.id,
                    path: path,
                    arrowStart: arrowheads == .start || arrowheads == .both ? arrowStart : nil,
                    arrowEnd: arrowheads == .end || arrowheads == .both ? arrowEnd : nil,
                    bounds: connection.bounds,
                    color: connection.style.color,
                    lineWidth: connection.style.width,
                    dash: connection.style.dash,
                    label: connection.label,
                    labelCenter: connection.labelPosition,
                    labelColor: connection.style.color,
                    labelFont: RelationRenderer.connectionLabelFont,
                    selectionHalo: selected ? halo : nil))
        case .boundary(let boundary):
            return .boundary(
                BoundaryVisual(
                    id: boundary.id,
                    outline: boundary.outline,
                    bounds: boundary.bounds,
                    fillColor: boundary.style.fill,
                    strokeColor: boundary.style.stroke,
                    lineWidth: boundary.style.lineWidth,
                    dash: boundary.style.dash,
                    title: boundary.title,
                    titleCenter: boundary.titleCenter,
                    titleColor: boundary.style.stroke,
                    titleFont: RelationRenderer.boundaryTitleFont))
        case .summary(let summary):
            return .summary(
                SummaryVisual(
                    id: summary.id,
                    brace: summary.brace,
                    bounds: summary.bounds,
                    color: summary.color,
                    lineWidth: summary.width))
        }
    }
}

/// The `MapRender` visual an overlay rasterizes through (an enum-level
/// indirection so the pooled layer stores one value type).
enum RelationDrawVisual {
    case connection(ConnectionVisual)
    case boundary(BoundaryVisual)
    case summary(SummaryVisual)

    /// Draws into a flipped context translated to the overlay's bounds
    /// origin (the same contract `NodeRasterizer` gives node rasters).
    func draw(measurer: TextMeasurer, in context: CGContext) {
        switch self {
        case .connection(let visual):
            RelationRenderer.draw(connection: visual, measurer: measurer, in: context)
        case .boundary(let visual):
            RelationRenderer.draw(boundary: visual, measurer: measurer, in: context)
        case .summary(let visual):
            RelationRenderer.draw(summary: visual, in: context)
        }
    }

    /// The connection case's value (for `connectionVisual`'s bridge).
    var connectionValue: ConnectionVisual {
        guard case .connection(let visual) = self else {
            return ConnectionVisual(
                id: "", path: CGPath(rect: .zero, transform: nil), arrowStart: nil, arrowEnd: nil,
                bounds: .zero, color: CGColor(gray: 0, alpha: 1), lineWidth: 1, dash: false,
                label: nil, labelCenter: .zero, labelColor: CGColor(gray: 0, alpha: 1),
                labelFont: FontSpec(size: 12))
        }
        return visual
    }
}

/// Whether two overlay values raster to identical pixels at the same
/// scale: every pixel-relevant input compared without touching the
/// derived `CGPath`s (paths are pure functions of the compared
/// inputs), colors through the theme-color equality helper.
enum RelationRasterKey {
    static func sameOverlay(
        _ lhs: RelationOverlay, _ rhs: RelationOverlay, scaleEqual: Bool
    ) -> Bool {
        guard scaleEqual, lhs.id == rhs.id else { return false }
        switch (lhs, rhs) {
        case (
            .connection(let left, let leftSelected), .connection(let right, let rightSelected)
        ):
            return leftSelected == rightSelected
                && left.from == right.from && left.to == right.to
                && left.control == right.control && left.straight == right.straight
                && left.label == right.label && left.bounds == right.bounds
                && left.style.width == right.style.width && left.style.dash == right.style.dash
                && left.style.arrowheads == right.style.arrowheads
                && SceneDiffer.sameColor(left.style.color, right.style.color)
        case (.boundary(let left), .boundary(let right)):
            return left.title == right.title && left.bounds == right.bounds
                && left.memberIDs == right.memberIDs
                && left.style.lineWidth == right.style.lineWidth
                && left.style.dash == right.style.dash
                && left.style.cornerRadius == right.style.cornerRadius
                && left.style.padding == right.style.padding
                && left.style.organic == right.style.organic
                && SceneDiffer.sameColor(left.style.stroke, right.style.stroke)
                && SceneDiffer.sameColor(left.style.fill, right.style.fill)
        case (.summary(let left), .summary(let right)):
            return left.bounds == right.bounds && left.axis == right.axis
                && left.rangeUnion == right.rangeUnion && left.mirrored == right.mirrored
                && left.nodeID == right.nodeID && left.width == right.width
                && SceneDiffer.sameColor(left.color, right.color)
        default:
            return false
        }
    }
}
