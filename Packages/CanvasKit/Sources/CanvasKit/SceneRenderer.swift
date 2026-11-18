import CoreGraphics
import Foundation
import MapRender

/// Renders a whole `CanvasScene` into any flipped (y-down) `CGContext`
/// through a camera: branches first (tapered per §7.4), then nodes.
/// The same path backs the on-screen canvas, export and Quick Look.
public enum SceneRenderer {
    public static func draw(
        scene: CanvasScene,
        camera: Camera,
        selection: Set<String> = [],
        selectionColor: CGColor,
        in context: CGContext,
        viewport: CGSize
    ) {
        context.saveGState()
        context.setFillColor(scene.canvasColor)
        context.fill(CGRect(origin: .zero, size: viewport))

        context.scaleBy(x: camera.scale, y: camera.scale)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)

        for branch in scene.branches {
            let path =
                branch.tapered
                ? MapRender.BranchPath.tapered(
                    from: branch.from, to: branch.to,
                    startWidth: branch.startWidth, endWidth: branch.endWidth,
                    axis: branch.axis)
                : MapRender.BranchPath.straight(from: branch.from, to: branch.to)
            context.setFillColor(branch.color)
            context.addPath(path)
            context.fillPath()
        }

        for node in scene.nodes.values {
            NodeRenderer.draw(
                style: node.style, title: node.title, measurer: sharedMeasurer,
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
