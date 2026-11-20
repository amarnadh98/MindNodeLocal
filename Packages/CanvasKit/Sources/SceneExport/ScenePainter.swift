import CoreGraphics
import MapRender

/// Draws an `ExportScene` into any flipped (y-down) `CGContext`: optional
/// background, then branches and nodes through the SAME shared
/// `BranchPath` and `NodeRenderer` primitives the on-screen canvas uses
/// (SPEC §11: one `NodeRenderer` behind canvas, export and Quick Look).
/// The canvas's own `SceneRenderer` fills the background unconditionally
/// and paints selection rings, so exports keep this painter instead —
/// same primitives, export-shaped options.
public enum ScenePainter {
    /// Draws the whole export scene. The context must be flipped
    /// (`y` growing down, the canvas/`TreeLayout` convention). The
    /// scene's `bounds` origin is subtracted, so callers render into a
    /// (0,0)-based surface.
    public static func draw(
        _ export: ExportScene, measurer: TextMeasurer, in context: CGContext,
        background: CGColor?
    ) {
        context.saveGState()
        if let background {
            context.setFillColor(background)
            context.fill(
                CGRect(origin: .zero, size: CGSize(width: export.bounds.width, height: export.bounds.height)))
        }

        context.translateBy(x: -export.bounds.minX, y: -export.bounds.minY)

        for branch in export.branches {
            // The canvas draws tapered connectors as filled offset
            // polygons (`SceneRenderer`); the stroke styles follow the
            // same §7.4 switch, and `none` draws nothing.
            switch branch.lineStyle {
            case .none:
                continue
            case .tapered:
                let path = BranchPath.tapered(
                    from: branch.from, to: branch.to,
                    startWidth: branch.startWidth, endWidth: branch.endWidth,
                    axis: branch.axis)
                context.setFillColor(branch.color)
                context.addPath(path)
                context.fillPath()
            case .curved, .straight, .elbow:
                let path: CGPath
                switch branch.lineStyle {
                case .straight:
                    path = BranchPath.straight(from: branch.from, to: branch.to)
                case .elbow:
                    path = BranchPath.elbow(from: branch.from, to: branch.to, axis: branch.axis)
                default:
                    path = BranchPath.cubic(from: branch.from, to: branch.to, axis: branch.axis)
                }
                context.setStrokeColor(branch.color)
                context.setLineWidth(max(branch.startWidth, branch.endWidth))
                context.setLineCap(.round)
                context.addPath(path)
                context.strokePath()
            }
        }

        for node in export.nodes {
            NodeRenderer.draw(
                style: node.style, title: node.title, decorations: node.decorations,
                measurer: measurer, media: node.media, in: context, frame: node.frame)
        }
        context.restoreGState()
    }
}
