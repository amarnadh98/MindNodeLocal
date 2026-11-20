import AppKit
import CoreGraphics
import MapRender
import SwiftMath

/// The app's rendered-math cache (F-CNT-5, ADR-0027): LaTeX → a
/// `MathGlyph` the scene builder measures and `NodeRenderer` draws,
/// plus `NSImage`s for the note preview. Cache keyed by (latex, font
/// size, tint) — a scene build pays a dictionary lookup, never a
/// re-typeset.
///
/// A parse error returns nil, and the node renders the LaTeX source
/// text (F-CNT-5's fallback). Main-actor: SwiftMath's fonts and the
/// scene builder both live there, and the first render of an
/// expression is the only real cost.
@MainActor
enum MathImageCache {
    private struct Key: Hashable {
        let latex: String
        let fontSize: CGFloat
        let tintHex: String
    }

    private static var glyphs: [Key: MathGlyph] = [:]
    private static var images: [Key: NSImage] = [:]

    /// The tint as a cache key (theme colors are the few level values).
    private static func hex(of color: CGColor) -> String {
        guard let components = color.components?.map({ Double($0) }), color.numberOfComponents >= 3
        else { return "gray" }
        return components.prefix(3).map { String(format: "%02x", Int($0 * 255)) }.joined()
    }

    /// Renders `latex` at `font`'s size in `tint`, or nil on a parse
    /// error. Cached; the glyph draws upright anywhere in a flipped
    /// y-down context (it flips locally).
    static func glyph(latex: String, font: FontSpec, tint: CGColor) -> MathGlyph? {
        let key = Key(latex: latex, fontSize: font.size, tintHex: hex(of: tint))
        if let cached = glyphs[key] {
            return cached
        }
        let mathImage = MTMathImage(
            latex: latex, fontSize: fontSize(for: font),
            textColor: NSColor(cgColor: tint) ?? .labelColor)
        let (error, image) = mathImage.asImage()
        guard error == nil, let image else {
            return nil
        }
        guard let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let glyphSize = image.size
        let glyph = MathGlyph(size: glyphSize) { context, rect in
            // The renderer hands us a y-down rect; CG draws y-up.
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(raster, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        glyphs[key] = glyph
        return glyph
    }

    /// The note preview's math (F-CNT-1's `$$…$$` blocks): an NSImage
    /// sized for the popover's column.
    static func image(latex: String, fontSize: CGFloat, color: NSColor) -> NSImage? {
        let key = Key(latex: latex, fontSize: fontSize, tintHex: hex(of: color.cgColor))
        if let cached = images[key] {
            return cached
        }
        let mathImage = MTMathImage(latex: latex, fontSize: fontSize, textColor: color)
        let (error, image) = mathImage.asImage()
        guard error == nil, let image else {
            return nil
        }
        images[key] = image
        return image
    }

    /// The math font size for a node's title font (TeMS slightly
    /// larger reads better inside node boxes).
    private static func fontSize(for font: FontSpec) -> CGFloat {
        max(11, font.size * 1.1)
    }
}

/// The note preview's math segmentation (F-CNT-1/5): splits note
/// markdown into text runs and math (`$$…$$` blocks, `$…$` inline) —
/// the preview renders the math segments through `MathImageCache`.
enum NoteMathParser {
    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    static func segments(of note: String) -> [Segment] {
        var segments: [Segment] = []
        var remainder = Substring(note[...])
        while let block = remainder.range(of: "$$") {
            if let end = remainder[block.upperBound...].range(of: "$$") {
                appendText(&segments, remainder[..<block.lowerBound])
                segments.append(
                    .math(
                        String(remainder[block.upperBound..<end.lowerBound]).trimmingCharacters(
                            in: .whitespacesAndNewlines)))
                remainder = remainder[end.upperBound...]
                continue
            }
            break
        }
        appendText(&segments, remainder)
        return segments
    }

    private static func appendText(_ segments: inout [Segment], _ text: Substring) {
        guard !text.isEmpty else { return }
        segments.append(.text(String(text)))
    }
}
