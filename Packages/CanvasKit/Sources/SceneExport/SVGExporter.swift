import CanvasKit
import CoreGraphics
import Foundation
import MapCore
import MapRender

/// Hand-written SVG export (SPEC §5.17, P1): branches as paths, nodes
/// as shapes, text as `<text>` with proper XML escaping (optionally as
/// glyph outline paths). The scene's model space is already y-down —
/// SVG's convention too — so coordinates map 1:1.
///
/// Known limitation, recorded in the emitter's header comment on
/// purpose: node shadows are not carried over (no blur-filter
/// approximation of the two-layer raised shadow), and color-bitmap
/// glyphs (emoji) drop out of outlines mode.
public enum SVGExporter {
    public static func export(
        scene: CanvasScene,
        model: MapModel,
        content: ExportContent = .wholeMap,
        options: SVGExportOptions = SVGExportOptions(),
        measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) -> String {
        let export = ExportGeometry.content(
            scene: scene, model: model, content: content, margin: options.margin)

        var lines: [String] = []
        lines.reserveCapacity(16 + export.branches.count + export.nodes.count * 4)
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(SVGSupport.number(export.bounds.width))\" "
                + "height=\"\(SVGSupport.number(export.bounds.height))\" "
                + "viewBox=\"\(SVGSupport.number(export.bounds.minX)) \(SVGSupport.number(export.bounds.minY)) "
                + "\(SVGSupport.number(export.bounds.width)) \(SVGSupport.number(export.bounds.height))\">")

        if options.includeBackground {
            lines.append(
                "<rect x=\"\(SVGSupport.number(export.bounds.minX))\" "
                    + "y=\"\(SVGSupport.number(export.bounds.minY))\" "
                    + "width=\"\(SVGSupport.number(export.bounds.width))\" "
                    + "height=\"\(SVGSupport.number(export.bounds.height))\" "
                    + "fill=\"\(SVGSupport.cssColor(export.canvasColor))\"/>")
        }

        for branch in export.branches {
            lines.append(branchElement(branch))
        }
        for node in export.nodes {
            SVGNodeElement.emit(node, options: options, measurer: measurer, into: &lines)
        }
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One branch connector: tapered branches fill the sampled offset
    /// polygon (the canvas's own branch drawing); the stroke styles
    /// follow the same §7.4 switch; `none` emits nothing.
    private static func branchElement(_ branch: SceneBranch) -> String {
        switch branch.lineStyle {
        case .none:
            return ""
        case .tapered:
            let path = BranchPath.tapered(
                from: branch.from, to: branch.to,
                startWidth: branch.startWidth, endWidth: branch.endWidth,
                axis: branch.axis)
            return "<path d=\"\(SVGSupport.pathData(path))\" fill=\"\(SVGSupport.cssColor(branch.color))\"/>"
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
            let width = SVGSupport.number(max(branch.startWidth, branch.endWidth))
            return
                "<path d=\"\(SVGSupport.pathData(path))\" fill=\"none\" stroke=\"\(SVGSupport.cssColor(branch.color))\" stroke-width=\"\(width)\" stroke-linecap=\"round\"/>"
        }
    }
}
