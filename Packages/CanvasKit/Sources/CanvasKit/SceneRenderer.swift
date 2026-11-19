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
    /// SPEC §11.4); the node's shape stays visible as an anchor. The
    /// relation overlays (F-REL-1/2/3) draw through the same shared
    /// `RelationRenderer`: boundaries under the branches, braces and
    /// connections over the nodes.
    public static func draw(
        scene: CanvasScene,
        camera: Camera,
        selection: Set<String> = [],
        selectionColor: CGColor,
        editingNodeID: String? = nil,
        /// M6 (SPEC §10): reveal-state overlay — hidden nodes and
        /// branches are skipped, ghosted ones draw at their overlay
        /// opacity. Export and the slide PDF writer share it.
        revealOverlay: RevealOverlay? = nil,
        selectedConnections: Set<String> = [],

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
        for boundary in scene.boundaries where visible.intersects(boundary.bounds) {
            RelationRenderer.draw(
                boundary: RelationVisuals.boundaryVisual(boundary), measurer: measurer, in: context)
        }
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
            // M6 (SPEC §10): the branch dims with the weaker of its
            // ends; a hidden branch draws nothing.
            let alpha = revealOverlay?.branchOpacity(parentID: branch.parentID, childID: branch.childID) ?? 1
            guard alpha > 0.01 else { continue }
            let path =
                branch.tapered
                ? MapRender.BranchPath.tapered(
                    from: branch.from, to: branch.to,
                    startWidth: branch.startWidth, endWidth: branch.endWidth,
                    axis: branch.axis)
                : MapRender.BranchPath.straight(from: branch.from, to: branch.to)
            context.saveGState()
            context.setAlpha(alpha)
            context.setFillColor(branch.color)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        for node in scene.nodes.values {
            guard visible.intersects(node.frame) else { continue }
            let alpha = revealOverlay?.nodeOpacity(node.id) ?? 1
            guard alpha > 0.01 else { continue }
            let title = node.id == editingNodeID ? NodeTitle(text: "", runs: []) : node.title
            context.saveGState()
            context.setAlpha(alpha)
            NodeRenderer.draw(
                style: node.style, title: title, decorations: node.decorations,
                measurer: measurer, in: context, frame: node.frame)
            context.restoreGState()
        }

        for summary in scene.summaries where visible.intersects(summary.bounds) {
            RelationRenderer.draw(
                summary: RelationVisuals.summaryVisual(summary), in: context)
        }
        for connection in scene.connections where visible.intersects(connection.bounds) {
            RelationRenderer.draw(
                connection: RelationVisuals.connectionVisual(
                    connection,
                    selected: selectedConnections.contains(connection.id),
                    halo: selectionColor),
                measurer: measurer, in: context)
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
