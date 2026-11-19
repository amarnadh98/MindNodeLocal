import CanvasKit
import CoreGraphics
import Foundation
import ImageIO
import MapCore
import MapRender
import UniformTypeIdentifiers

/// Emits a node's media (F-CNT-2/3/5) as SVG: the image block and SF
/// Symbol markers as embedded PNG data URIs (rasters by nature; encoded
/// through `CGImageDestination` — ImageIO, no AppKit, ADR-0012), the
/// Arbor stickers as true vector `<path>` elements tinted with the
/// node's decoration color, emoji markers as text, and the rendered
/// math glyph as a data URI (SwiftMath rasters through the same
/// shared path the canvas uses).
enum SVGMediaElement {
    static func emit(
        _ node: SceneNode, into lines: inout [String]
    ) {
        guard let decorations = node.decorations, let layout = decorationLayout(node) else { return }
        var mediaLines: [String] = []
        emitImage(decorations, layout: layout, media: node.media, into: &mediaLines)
        emitMarkers(decorations, node: node, layout: layout, into: &mediaLines)
        emitMath(node, layout: layout, media: node.media, into: &mediaLines)
        guard !mediaLines.isEmpty else { return }
        lines.append(contentsOf: mediaLines)
    }

    private static func decorationLayout(_ node: SceneNode) -> NodeDecorationLayout? {
        guard let decorations = node.decorations, !decorations.isEmpty else { return nil }
        return NodeRenderer.decorationLayout(
            style: node.style, decorations: decorations, frame: node.frame)
    }

    // MARK: pieces

    private static func emitImage(
        _ decorations: NodeDecorations, layout: NodeDecorationLayout, media: NodeMedia?,
        into lines: inout [String]
    ) {
        guard let rect = layout.imageRect else { return }
        if let image = media?.image, let uri = pngDataURI(image) {
            lines.append(
                "<image x=\"\(SVGSupport.number(rect.minX))\" y=\"\(SVGSupport.number(rect.minY))\" "
                    + "width=\"\(SVGSupport.number(rect.width))\" height=\"\(SVGSupport.number(rect.height))\" "
                    + "preserveAspectRatio=\"xMidYMid slice\" href=\"\(uri)\"/>")
        } else {
            // The placeholder frame (the renderer's undecoded state).
            let radius = min(6, rect.width / 8, rect.height / 8)
            lines.append(
                "<rect x=\"\(SVGSupport.number(rect.minX))\" y=\"\(SVGSupport.number(rect.minY))\" "
                    + "width=\"\(SVGSupport.number(rect.width))\" height=\"\(SVGSupport.number(rect.height))\""
                    + " rx=\"\(SVGSupport.number(radius))\" ry=\"\(SVGSupport.number(radius))\""
                    + " fill=\"#e5e5eb\" stroke=\"#b8b8bf\" stroke-width=\"1\"/>")
        }
    }

    private static func emitMarkers(
        _ decorations: NodeDecorations, node: SceneNode, layout: NodeDecorationLayout,
        into lines: inout [String]
    ) {
        guard let row = layout.markerRowRect, !decorations.markers.isEmpty else { return }
        let color = SVGSupport.cssColor(node.style.borderColor ?? node.style.textColor)
        let size = NodeDecorationMetrics.markerSize
        let gap = NodeDecorationMetrics.markerGap
        for (index, marker) in decorations.markers.enumerated() {
            let slot = CGRect(
                x: row.minX + gap + CGFloat(index) * (size + gap), y: row.minY,
                width: size, height: size)
            switch MarkerKind.parse(marker.token) {
            case .sticker(let id):
                guard let sticker = Stickers.sticker(id: id) else { continue }
                lines.append(stickerElement(sticker, in: slot, color: color))
            case .emoji(let char):
                lines.append(
                    "<text x=\"\(SVGSupport.number(slot.minX))\" y=\"\(SVGSupport.number(slot.maxY - size * 0.18))\""
                        + " font-size=\"\(SVGSupport.number(size * 0.85))\" fill=\"\(color)\">"
                        + SVGSupport.escapeText(char) + "</text>")
            case .sfSymbol:
                // The tinted raster the host resolved (F-CNT-3's
                // AppKit-only glyphs), embedded as PNG.
                if let glyph = node.media?.markerImages[marker.token],
                    let uri = pngDataURI(glyph)
                {
                    lines.append(
                        "<image x=\"\(SVGSupport.number(slot.minX))\" y=\"\(SVGSupport.number(slot.minY))\" "
                            + "width=\"\(SVGSupport.number(size))\" height=\"\(SVGSupport.number(size))\" "
                            + "href=\"\(uri)\"/>")
                }
            case nil:
                continue
            }
        }
    }

    private static func emitMath(
        _ node: SceneNode, layout: NodeDecorationLayout, media: NodeMedia?, into lines: inout [String]
    ) {
        guard node.decorations?.math == true, let glyph = media?.math else { return }
        // The glyph's draw rect, reproduced from
        // `NodeRenderer.drawMathGlyph`.
        let width = min(glyph.size.width, layout.titleRow.width)
        let scale = width / max(glyph.size.width, 1)
        let height = min(glyph.size.height * scale, layout.titleRow.height)
        let rect = CGRect(
            x: layout.titleRow.minX + max(0, (layout.titleRow.width - width) / 2),
            y: layout.titleRow.midY - height / 2,
            width: width, height: height)
        // Raster through the same drawing closure the node renderer
        // uses (SwiftMath), then embed.
        guard
            let raster = rasterMath(glyph: glyph, rect: rect),
            let uri = pngDataURI(raster)
        else { return }
        lines.append(
            "<image x=\"\(SVGSupport.number(rect.minX))\" y=\"\(SVGSupport.number(rect.minY))\" "
                + "width=\"\(SVGSupport.number(rect.width))\" height=\"\(SVGSupport.number(rect.height))\" "
                + "href=\"\(uri)\"/>")
    }

    // MARK: helpers

    /// One sticker as a vector `<path>`: the unit box scaled into the
    /// slot, filled/stroked per the sticker's mode.
    private static func stickerElement(_ sticker: Sticker, in slot: CGRect, color: String) -> String {
        let unit: CGFloat = 24
        let scale = min(slot.width, slot.height) / unit
        let width = unit * scale
        let height = unit * scale
        let fit = CGRect(
            x: slot.minX + (slot.width - width) / 2, y: slot.minY + (slot.height - height) / 2,
            width: width, height: height)
        var transform = CGAffineTransform(translationX: fit.minX, y: fit.minY)
            .scaledBy(x: scale, y: scale)
        let scaled = sticker.path.copy(using: &transform) ?? sticker.path
        let data = SVGSupport.pathData(scaled)
        let paint: String
        switch sticker.mode {
        case .fill:
            paint = " fill=\"\(color)\""
        case .stroke:
            paint = " fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(SVGSupport.number(sticker.lineWidth * scale))\""
        case .fillStroke:
            paint = " fill=\"\(color)\" stroke=\"\(color)\" stroke-width=\"\(SVGSupport.number(sticker.lineWidth * scale))\""
        }
        return "<path d=\"\(data)\"\(paint)/>"
    }

    /// Rasters the glyph's draw closure into a CGImage sized for the
    /// target rect (2× for crispness), flipped into the renderer's
    /// y-down convention.
    private static func rasterMath(glyph: MathGlyph, rect: CGRect) -> CGImage? {
        let scale: CGFloat = 2
        let width = max(1, Int((rect.width * scale).rounded()))
        let height = max(1, Int((rect.height * scale).rounded()))
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        // The renderer's flipped convention around the target rect.
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        glyph.draw(context, rect)
        return context.makeImage()
    }

    /// PNG bytes as a `data:` URI, or nil when the encode fails.
    private static func pngDataURI(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !data.isEmpty else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}
