import CanvasKit
import CoreGraphics
import Foundation
import MapCore
import MapRender

/// Emits one scene node as SVG: the shape element(s), the underline
/// stroke for underline nodes, then the title — as `<text>` with
/// per-line/per-run `<tspan>` styling, or as glyph outline paths in
/// outlines mode.
enum SVGNodeElement {
    static func emit(
        _ node: SceneNode, options: SVGExportOptions, measurer: TextMeasurer, into lines: inout [String]
    ) {
        var nodeLines: [String] = []
        shapeElement(node, into: &nodeLines)
        if options.textAsOutlines {
            glyphOutlines(node, measurer: measurer, into: &nodeLines)
        } else {
            textElement(node, measurer: measurer, into: &nodeLines)
        }
        guard !nodeLines.isEmpty else { return }
        lines.append("<g id=\"\(SVGSupport.escapeAttribute(node.id))\">")
        lines.append(contentsOf: nodeLines)
        lines.append("</g>")
    }

    // MARK: shapes

    private static func shapeElement(_ node: SceneNode, into lines: inout [String]) {
        let style = node.style
        let frame = node.frame
        switch style.shape {
        case .underline:
            let underlineY = frame.maxY - style.underlineWidth / 2
            let color = style.borderColor.map(SVGSupport.cssColor) ?? "none"
            lines.append(
                "<line x1=\"\(SVGSupport.number(frame.minX))\" y1=\"\(SVGSupport.number(underlineY))\" "
                    + "x2=\"\(SVGSupport.number(frame.maxX))\" y2=\"\(SVGSupport.number(underlineY))\" "
                    + "stroke=\"\(color)\" stroke-width=\"\(SVGSupport.number(style.underlineWidth))\"/>")
        case .none:
            break
        case .roundedRect:
            rectElement(frame, radius: min(style.cornerRadius, frame.height / 2), node: node, into: &lines)
        case .rectangle:
            rectElement(frame, radius: 0, node: node, into: &lines)
        case .pill:
            rectElement(frame, radius: frame.height / 2, node: node, into: &lines)
        case .circle, .cloud:
            lines.append(
                "<ellipse cx=\"\(SVGSupport.number(frame.midX))\" cy=\"\(SVGSupport.number(frame.midY))\" "
                    + "rx=\"\(SVGSupport.number(frame.width / 2))\" ry=\"\(SVGSupport.number(frame.height / 2))\""
                    + fillAndStroke(node) + "/>")
        case .square:
            let side = min(frame.width, frame.height)
            let square = CGRect(
                origin: CGPoint(x: frame.midX - side / 2, y: frame.midY - side / 2),
                size: CGSize(width: side, height: side))
            rectElement(square, radius: 0, node: node, into: &lines)
        case .diamond:
            polygonElement(frame, sides: 4, rotation: .pi / 2, node: node, into: &lines)
        case .hexagon:
            polygonElement(frame, sides: 6, rotation: .pi / 6, node: node, into: &lines)
        case .octagon:
            polygonElement(frame, sides: 8, rotation: .pi / 8, node: node, into: &lines)
        }
    }

    private static func rectElement(
        _ frame: CGRect, radius: CGFloat, node: SceneNode, into lines: inout [String]
    ) {
        let radiusAttr = radius > 0 ? " rx=\"\(SVGSupport.number(radius))\" ry=\"\(SVGSupport.number(radius))\"" : ""
        lines.append(
            "<rect x=\"\(SVGSupport.number(frame.minX))\" y=\"\(SVGSupport.number(frame.minY))\" "
                + "width=\"\(SVGSupport.number(frame.width))\" height=\"\(SVGSupport.number(frame.height))\""
                + radiusAttr + fillAndStroke(node) + "/>")
    }

    private static func polygonElement(
        _ frame: CGRect, sides: Int, rotation: CGFloat, node: SceneNode, into lines: inout [String]
    ) {
        lines.append(
            "<polygon points=\"\(SVGSupport.polygonPoints(frame: frame, sides: sides, rotation: rotation))\""
                + fillAndStroke(node) + "/>")
    }

    /// The fill/stroke attribute run every node shape carries (the
    /// Paper level-1 fill is a palette color at 16% — `rgba(...)`).
    private static func fillAndStroke(_ node: SceneNode) -> String {
        let style = node.style
        var attributes = ""
        if let fill = style.fillColor {
            attributes += " fill=\"\(SVGSupport.cssColor(fill))\""
        } else {
            attributes += " fill=\"none\""
        }
        if style.shape != .underline, let border = style.borderColor, style.borderWidth > 0 {
            attributes += " stroke=\"\(SVGSupport.cssColor(border))\""
            attributes += " stroke-width=\"\(SVGSupport.number(style.borderWidth))\""
        }
        return attributes
    }

    // MARK: text

    /// The text block rect, reproduced from `NodeRenderer.drawTitle`'s
    /// geometry (content rect, measured size, optical centering).
    private static func textRect(for node: SceneNode, measurer: TextMeasurer) -> CGRect {
        let content = NodeRenderer.contentRect(style: node.style, frame: node.frame)
        let textSize = measurer.nodeTitleSize(
            node.title, font: node.style.font, maxWidth: content.width)
        return CGRect(
            x: content.minX + max(0, (content.width - textSize.width) / 2),
            y: content.minY + max(0, (content.height - textSize.height) / 2),
            width: content.width,
            height: textSize.height + 2)
    }

    private static func textElement(
        _ node: SceneNode, measurer: TextMeasurer, into lines: inout [String]
    ) {
        let style = node.style
        let content = NodeRenderer.contentRect(style: style, frame: node.frame)
        let titleLines = measurer.titleLines(node.title, font: style.font, maxWidth: content.width)
        guard !titleLines.isEmpty else { return }
        let block = textRect(for: node, measurer: measurer)
        let source = node.title.text as NSString

        for line in titleLines {
            let baseline = block.minY + line.baselineFromTop
            let open =
                "<text x=\"\(SVGSupport.number(block.minX))\" y=\"\(SVGSupport.number(baseline))\""
                + " font-family=\"\(SVGSupport.fontFamily(style.font))\""
                + " font-size=\"\(SVGSupport.number(style.font.size))\""
                + " font-weight=\"\(SVGSupport.fontWeight(style.font.weight))\""
                + (style.font.italic ? " font-style=\"italic\"" : "")
                + " fill=\"\(SVGSupport.cssColor(style.textColor))\">"
            let fragments = styledFragments(line: line, in: node.title, source: source)
            if fragments.count == 1, fragments[0].run == nil {
                lines.append(open + SVGSupport.escapeText(fragments[0].text) + "</text>")
                continue
            }
            lines.append(open)
            for fragment in fragments {
                lines.append("  " + tspan(fragment, in: node))
            }
            lines.append("</text>")
        }
    }

    /// One line's text split into maximal same-run fragments (uncovered
    /// gaps carry `nil` runs and inherit the `<text>` base styling).
    private static func styledFragments(
        line: TitleLine, in title: NodeTitle, source: NSString
    ) -> [(text: String, run: Run?)] {
        let lineStart = line.utf16Range.location
        let lineEnd = lineStart + line.utf16Range.length
        var covering = [Int?](repeating: nil, count: line.utf16Range.length)
        for (runIndex, run) in title.runs.enumerated() {
            let runStart = max(0, run.range.first ?? 0)
            let runLength = run.range.count > 1 ? run.range[1] : 0
            let overlapStart = max(runStart, lineStart)
            let overlapEnd = min(runStart + runLength, lineEnd)
            guard overlapEnd > overlapStart else { continue }
            for index in overlapStart..<overlapEnd {
                covering[index - lineStart] = runIndex
            }
        }
        var fragments: [(text: String, run: Run?)] = []
        var index = lineStart
        while index < lineEnd {
            let style = covering[index - lineStart]
            var end = index + 1
            while end < lineEnd, covering[end - lineStart] == style { end += 1 }
            fragments.append(
                (
                    source.substring(with: NSRange(location: index, length: end - index)),
                    style.map { title.runs[$0] }
                ))
            index = end
        }
        return fragments
    }

    private static func tspan(_ fragment: (text: String, run: Run?), in node: SceneNode) -> String {
        var attributes = ""
        if let run = fragment.run {
            if run.bold == true { attributes += " font-weight=\"700\"" }
            if run.italic == true { attributes += " font-style=\"italic\"" }
            if run.code == true { attributes += " font-family=\"Menlo, monospace\"" }
            var decoration: [String] = []
            if run.underline == true { decoration.append("underline") }
            if run.strike == true { decoration.append("line-through") }
            if !decoration.isEmpty {
                attributes += " text-decoration=\"\(decoration.joined(separator: " "))\""
            }
            if let color = run.color { attributes += " fill=\"\(SVGSupport.escapeAttribute(color))\"" }
            if let size = run.size {
                attributes += " font-size=\"\(SVGSupport.number(CGFloat(size)))\""
            }
            if let font = run.font, !font.isEmpty {
                attributes += " font-family=\"\(SVGSupport.escapeAttribute(font))\""
            }
        }
        return "<tspan\(attributes)>\(SVGSupport.escapeText(fragment.text))</tspan>"
    }

    // MARK: outlines mode

    /// Text as glyph outline paths: each glyph's CoreText outline (y-up)
    /// flips into the scene's y-down space via `scale(1 -1)`.
    private static func glyphOutlines(
        _ node: SceneNode, measurer: TextMeasurer, into lines: inout [String]
    ) {
        let style = node.style
        let content = NodeRenderer.contentRect(style: style, frame: node.frame)
        let glyphLines = measurer.titleGlyphs(node.title, font: style.font, maxWidth: content.width)
        let block = textRect(for: node, measurer: measurer)
        let fill = " fill=\"\(SVGSupport.cssColor(style.textColor))\""
        for glyphLine in glyphLines {
            let baseline = block.minY + glyphLine.baselineFromTop
            for glyph in glyphLine.glyphs {
                let data = SVGSupport.pathData(glyph.outline)
                guard !data.isEmpty else { continue }
                let x = block.minX + glyph.offset.x
                let y = baseline - glyph.offset.y
                lines.append(
                    "<path transform=\"translate(\(SVGSupport.number(x)) \(SVGSupport.number(y))) "
                        + "scale(1 -1)\" d=\"\(data)\"\(fill)/>")
            }
        }
    }
}
