import CoreGraphics
import CoreText
import Foundation
import MapCore

/// One laid-out line of a node title, in the coordinate space the
/// `NodeRenderer.drawTitle` framesetter produces: `baselineFromTop` is
/// measured **down** from the top of the measured text block, so SVG
/// (and any y-down emitter) can place lines exactly where the canvas
/// draws them.
public struct TitleLine: Sendable {
    /// The line's substring of the title text.
    public let text: String
    /// The line's typographic width.
    public let width: CGFloat
    /// Baseline y, measured down from the top of the text block.
    public let baselineFromTop: CGFloat
    /// The line's range in the title's UTF-16 indices (the same space
    /// `Run.range` uses), for splitting run styling across wrapped lines.
    public let utf16Range: NSRange
}

extension TextMeasurer {
    /// Decomposes a title into the same lines `NodeRenderer.drawTitle`
    /// renders: identical framesetter, identical path height (measured
    /// size + 2 pt), identical paragraph style. The x of every line is
    /// the text block's left edge; `drawTitle` centers the *block*, not
    /// the lines, and the caller reproduces that offset with
    /// `nodeTitleSize`.
    public func titleLines(_ title: NodeTitle, font: FontSpec, maxWidth: CGFloat) -> [TitleLine] {
        guard !title.text.isEmpty else { return [] }
        let textSize = nodeTitleSize(title, font: font, maxWidth: maxWidth)
        guard textSize.width > 0, textSize.height > 0 else { return [] }

        let attributed = attributed(title, font: font, color: CGColor.black, lineHeight: 1.25)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // The exact path shape `drawTitle` lays out into.
        let pathHeight = textSize.height + 2
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: maxWidth, height: pathHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)

        // `CTFrameGetLineCount` is not imported into Swift on this SDK
        // (unannotated C), so the count comes from the lines array.
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        guard !lines.isEmpty else { return [] }
        let count = lines.count
        var origins = [CGPoint](repeating: .zero, count: count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: count), &origins)

        let source = title.text as NSString
        var result: [TitleLine] = []
        result.reserveCapacity(count)
        for (index, line) in lines.enumerated() {
            // CoreText reports line origins y-up from the path's bottom;
            // `drawTitle`'s local flip maps that to a y-down baseline
            // measured from the block's top.
            let baselineFromTop = pathHeight - origins[index].y
            let stringRange = CTLineGetStringRange(line)
            guard stringRange.length > 0 else { continue }
            let range = NSRange(location: stringRange.location, length: stringRange.length)
            let text = source.substring(with: range)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            result.append(
                TitleLine(
                    text: text, width: width, baselineFromTop: baselineFromTop, utf16Range: range))
        }
        return result
    }
}
