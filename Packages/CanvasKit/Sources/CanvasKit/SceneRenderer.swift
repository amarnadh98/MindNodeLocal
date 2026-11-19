import AppKit
import CoreGraphics
import MapCore
import MapRender

/// Renders a whole `CanvasScene` into any flipped (y-down) `CGContext`
/// through a camera: branches first (tapered per §7.4), then nodes, then
/// selection rings. The same path backs the on-screen canvas, export and
/// Quick Look.
public enum SceneRenderer {
    /// Draws the scene into a flipped context. Nodes and branches outside
    /// the visible model-space rect are skipped, so draw cost follows the
    /// viewport, not the map size. While a node is being edited its title
    /// is suppressed (the editing overlay draws the live text instead —
    /// SPEC §11.4); the node's shape stays visible as an anchor.
    public static func draw(
        scene: CanvasScene,
        camera: Camera,
        selection: Set<String> = [],
        selectionColor: CGColor,
        editingNodeID: String? = nil,
        measurer: TextMeasurer = SceneRenderer.sharedMeasurer,
        in context: CGContext,
        viewport: CGSize
    ) {
        context.saveGState()
        context.setFillColor(scene.canvasColor)
        context.fill(CGRect(origin: .zero, size: viewport))

        context.scaleBy(x: camera.scale, y: camera.scale)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)

        let visible = camera.visibleRect(viewportSize: viewport)
        for branch in scene.branches {
            let bounds = CGRect(
                x: min(branch.from.x, branch.to.x),
                y: min(branch.from.y, branch.to.y),
                width: abs(branch.to.x - branch.from.x),
                height: abs(branch.to.y - branch.from.y)
            ).insetBy(
                dx: -max(branch.startWidth, branch.endWidth),
                dy: -max(branch.startWidth, branch.endWidth))
            guard visible.intersects(bounds) else { continue }
            // §7.4 line styles after the child's branch override
            // (ADR-0011), same switch as the layer tree's branch path.
            let path: CGPath
            switch branch.lineStyle {
            case .tapered:
                path = MapRender.BranchPath.tapered(
                    from: branch.from, to: branch.to,
                    startWidth: branch.startWidth, endWidth: branch.endWidth,
                    axis: branch.axis)
            case .curved:
                path = MapRender.BranchPath.cubic(from: branch.from, to: branch.to, axis: branch.axis)
            case .straight:
                path = MapRender.BranchPath.straight(from: branch.from, to: branch.to)
            case .elbow:
                path = MapRender.BranchPath.elbow(from: branch.from, to: branch.to, axis: branch.axis)
            case .none:
                continue
            }
            if branch.tapered {
                context.setFillColor(branch.color)
                context.addPath(path)
                context.fillPath()
            } else {
                context.setStrokeColor(branch.color)
                context.setLineWidth(max(branch.startWidth, branch.endWidth))
                context.setLineCap(.round)
                context.addPath(path)
                context.strokePath()
            }
        }

        for node in scene.nodes.values {
            guard visible.intersects(node.frame) else { continue }
            let title = node.id == editingNodeID ? NodeTitle(text: "", runs: []) : node.title
            NodeRenderer.draw(
                style: node.style, title: title, measurer: measurer,
                in: context, frame: node.frame)
        }

        for id in selection {
            guard let node = scene.nodes[id] else { continue }
            let ring = node.frame.insetBy(dx: -3, dy: -3)
            let radius: CGFloat = node.style.shape == .underline ? 4 : min(10, node.style.cornerRadius + 3)
            let path = CGPath(
                roundedRect: ring, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.setStrokeColor(selectionColor)
            context.setLineWidth(2.5 / camera.scale)
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The shared measurer backing every render path (SPEC §11).
    public static let sharedMeasurer = TextMeasurer()
}
