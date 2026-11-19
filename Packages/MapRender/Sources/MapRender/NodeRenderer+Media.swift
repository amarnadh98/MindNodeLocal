import CoreGraphics
import CoreText
import Foundation
import MapCore

/// The resolved, drawing-time media of one node (F-CNT-2/3/5): the
/// decoded image thumbnail, the raster glyphs for `sf:` markers and
/// the rendered LaTeX math. Not `Sendable` — it is built and consumed
/// on the rendering context's actor (canvas, export or Quick Look).
///
/// Everything here degrades gracefully: a missing image draws a
/// placeholder (the async decode will re-raster), a missing SF Symbol
/// glyph draws nothing but its slot, and missing math falls back to
/// the source text (F-CNT-5).
public struct NodeMedia {
    /// The node image's decoded thumbnail (F-CNT-2).
    public var image: CGImage?
    /// Raster glyphs for `sf:` marker tokens, keyed by token.
    public var markerImages: [String: CGImage]
    /// The rendered LaTeX glyph (F-CNT-5), drawn over the title row.
    public var math: MathGlyph?
    /// The host cache's revision this media was composed from: when
    /// an async decode replaces a raster behind the caches, the
    /// revision bumps and exactly the media-carrying nodes re-raster
    /// (0 when nothing is cached yet — the placeholder draws).
    public var revision: Int

    public init(
        image: CGImage? = nil, markerImages: [String: CGImage] = [:], math: MathGlyph? = nil,
        revision: Int = 0
    ) {
        self.image = image
        self.markerImages = markerImages
        self.math = math
        self.revision = revision
    }
}

/// One rendered math expression (F-CNT-5): its size (a layout input
/// the scene builder measured through the same cache) and a draw that
/// paints it upright into a rect of the node renderer's flipped
/// y-down context. SwiftMath's display list draws y-up, so the host's
/// closure owns the local flip.
public struct MathGlyph {
    public let size: CGSize
    public let draw: (_ context: CGContext, _ rect: CGRect) -> Void

    public init(size: CGSize, draw: @escaping (CGContext, CGRect) -> Void) {
        self.size = size
        self.draw = draw
    }
}

extension NodeRenderer {
    /// Draws the marker row (F-CNT-3): `sticker:` paths tinted with
    /// the theme color (vector, any scale), `emoji:` as Core Text
    /// glyphs, `sf:` from the host's raster cache.
    static func drawMarkerRow(
        _ markers: [MarkerBadge],
        in row: CGRect,
        color: CGColor,
        measurer: TextMeasurer,
        media: NodeMedia?,
        in context: CGContext
    ) {
        let size = NodeDecorationMetrics.markerSize
        let gap = NodeDecorationMetrics.markerGap
        var cursor = row.minX + gap
        for marker in markers {
            let slot = CGRect(x: cursor, y: row.minY, width: size, height: size)
            switch MarkerKind.parse(marker.token) {
            case .sticker(let id):
                if let sticker = Stickers.sticker(id: id) {
                    drawSticker(sticker, in: slot, color: color, in: context)
                }
            case .emoji(let char):
                let font = FontSpec(size: size * 0.85, weight: 0.1)
                let attributed = measurer.attributed(
                    NodeTitle(text: char), font: font, color: color, lineHeight: 1)
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let textSize = measurer.singleLineSize(NodeTitle(text: char), font: font, lineHeight: 1)
                context.saveGState()
                context.translateBy(x: slot.minX + (size - textSize.width) / 2, y: slot.maxY)
                context.scaleBy(x: 1, y: -1)
                let local = CGRect(x: 0, y: 0, width: size, height: size + 2)
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: 0, length: 0), CGPath(rect: local, transform: nil), nil)
                context.textMatrix = CGAffineTransform.identity
                context.saveGState()
                context.translateBy(x: 0, y: (size - textSize.height) / 2)
                CTFrameDraw(frame, context)
                context.restoreGState()
                context.restoreGState()
            case .sfSymbol:
                if let glyph = media?.markerImages[marker.token] {
                    context.saveGState()
                    context.clip(to: slot)
                    context.draw(glyph, in: slot)
                    context.restoreGState()
                }
            case nil:
                break
            }
            cursor += size + gap
        }
    }

    /// Draws the image block (F-CNT-2): the decoded thumbnail clipped
    /// to a rounded rect, or the placeholder while the async decode is
    /// still in flight (a light frame with a small photo glyph — an
    /// original path, never a copied asset).
    static func drawImageBlock(in rect: CGRect, media: NodeMedia?, in context: CGContext) {
        let radius = min(6, rect.width / 8, rect.height / 8)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()

        if let image = media?.image {
            context.draw(image, in: rect)
            context.restoreGState()
            return
        }

        // The placeholder: a light fill, a frame and a tiny glyph.
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.92, alpha: 1))
        context.fill(rect)
        context.setStrokeColor(CGColor(srgbRed: 0.72, green: 0.72, blue: 0.75, alpha: 1))
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        let glyph = CGMutablePath()
        let cx = rect.midX
        let cy = rect.midY
        let half = min(rect.width, rect.height) * 0.18
        // A mountain-and-sun photo mark.
        glyph.addEllipse(in: CGRect(x: cx - half * 1.4, y: cy - half * 0.9, width: half * 0.8, height: half * 0.8))
        glyph.move(to: CGPoint(x: cx - half * 1.8, y: cy + half))
        glyph.addLine(to: CGPoint(x: cx - half * 0.6, y: cy - half * 0.4))
        glyph.addLine(to: CGPoint(x: cx + half * 0.2, y: cy + half * 0.2))
        glyph.addLine(to: CGPoint(x: cx + half * 0.9, y: cy - half * 0.5))
        glyph.addLine(to: CGPoint(x: cx + half * 1.8, y: cy + half))
        glyph.closeSubpath()
        context.setFillColor(CGColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1))
        context.addPath(glyph)
        context.fillPath()
        context.restoreGState()
    }

    /// The attachment badge (F-CNT-7): a paperclip drawn as strokes.
    static func drawAttachmentBadge(in rect: CGRect, in context: CGContext) {
        let inset = rect.insetBy(dx: 2.6, dy: 2.2)
        context.setLineWidth(1.3)
        context.setLineCap(.round)
        // The clip's outer ellipse and inner line.
        context.strokeEllipse(in: inset)
        let midX = inset.midX
        context.move(to: CGPoint(x: midX, y: inset.minY + inset.height * 0.15))
        context.addLine(to: CGPoint(x: midX, y: inset.maxY - inset.height * 0.15))
        context.strokePath()
    }

    /// The source citation chip (F-CNT-8): an opening quote drawn as
    /// two strokes.
    static func drawSourceChip(in rect: CGRect, in context: CGContext) {
        let inset = rect.insetBy(dx: 2.4, dy: 4)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        for offset in [0.0, inset.width * 0.55] {
            let x = inset.minX + offset
            context.move(to: CGPoint(x: x, y: inset.maxY))
            context.addLine(to: CGPoint(x: x, y: inset.midY))
            context.addLine(to: CGPoint(x: x + inset.width * 0.35, y: inset.midY))
            context.strokePath()
        }
    }

    /// Draws a rendered math glyph centered in `titleRow` (F-CNT-5).
    /// `drawTitle` calls this instead of the Core Text frame when the
    /// node carries math and the host resolved a glyph.
    static func drawMathGlyph(_ glyph: MathGlyph, in titleRow: CGRect, in context: CGContext) {
        let width = min(glyph.size.width, titleRow.width)
        let scale = width / max(glyph.size.width, 1)
        let height = min(glyph.size.height * scale, titleRow.height)
        let rect = CGRect(
            x: titleRow.minX + max(0, (titleRow.width - width) / 2),
            y: titleRow.midY - height / 2,
            width: width, height: height)
        glyph.draw(context, rect)
    }

    /// Draws one sticker tinted with `color` into `rect` (F-CNT-3) —
    /// the picker's preview path too, so the grid shows exactly what
    /// the canvas draws.
    public static func drawSticker(
        _ sticker: Sticker, in rect: CGRect, color: CGColor, in context: CGContext
    ) {
        let unit: CGFloat = 24
        let scale = min(rect.width, rect.height) / unit
        let width = unit * scale
        let height = unit * scale
        let fit = CGRect(
            x: rect.minX + (rect.width - width) / 2, y: rect.minY + (rect.height - height) / 2,
            width: width, height: height)
        var transform = CGAffineTransform(
            translationX: fit.minX, y: fit.minY
        ).scaledBy(x: scale, y: scale)
        let scaled = sticker.path.copy(using: &transform) ?? sticker.path

        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(sticker.lineWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch sticker.mode {
        case .fill:
            context.addPath(scaled)
            context.fillPath()
        case .stroke:
            context.addPath(scaled)
            context.strokePath()
        case .fillStroke:
            context.addPath(scaled)
            context.fillPath()
            context.addPath(scaled)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Draws one sticker by id (the picker's convenience).
    public static func drawSticker(
        id: String, in rect: CGRect, color: CGColor, in context: CGContext
    ) -> Bool {
        guard let sticker = Stickers.sticker(id: id) else { return false }
        drawSticker(sticker, in: rect, color: color, in: context)
        return true
    }
}
