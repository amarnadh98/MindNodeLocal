import CoreGraphics
import CoreText
import Foundation
import MapCore

/// One glyph of a laid-out title: its outline in a baseline-relative,
/// y-UP space (the space `CTFontCreatePathForGlyph` produces), plus the
/// translation that places it at the line's left edge and baseline.
/// Color-bitmap glyphs (emoji) have empty outlines — outlines-mode SVG
/// cannot carry them.
public struct TitleGlyph: @unchecked Sendable {
    public let outline: CGPath
    public let offset: CGPoint
}

/// One line of a title as positioned glyph outlines — the "text as
/// outlines" SVG option (SPEC §5.17), laid out by the same framesetter
/// that draws the node.
public struct TitleGlyphLine: @unchecked Sendable {
    /// Typographic line width.
    public let width: CGFloat
    /// Baseline y, measured down from the top of the text block.
    public let baselineFromTop: CGFloat
    public let glyphs: [TitleGlyph]
}

extension TextMeasurer {
    /// Glyph outlines for a title, laid out with the exact framesetter
    /// constraints `titleLines` and `NodeRenderer.drawTitle` use. Glyph
    /// outlines are y-up; the caller flips them into its y-down space.
    public func titleGlyphs(
        _ title: NodeTitle, font: FontSpec, maxWidth: CGFloat
    ) -> [TitleGlyphLine] {
        let lines = titleLines(title, font: font, maxWidth: maxWidth)
        guard !lines.isEmpty else { return [] }
        let textSize = nodeTitleSize(title, font: font, maxWidth: maxWidth)
        let attributed = attributed(title, font: font, color: CGColor.black, lineHeight: 1.25)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: maxWidth, height: textSize.height + 2), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        let coreLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        let count = coreLines.count
        guard count <= lines.count else { return [] }

        var result: [TitleGlyphLine] = []
        result.reserveCapacity(count)
        for (index, coreLine) in coreLines.enumerated() {
            guard index < lines.count else { break }
            let line = lines[index]
            var glyphs: [TitleGlyph] = []
            let runs = (CTLineGetGlyphRuns(coreLine) as? [CTRun]) ?? []
            for run in runs {
                let runRange = CTRunGetStringRange(run)
                guard runRange.length > 0 else { continue }
                let runFont = runFont(of: run, base: font)
                let runOffsetX = CGFloat(
                    CTLineGetOffsetForStringIndex(coreLine, runRange.location, nil))
                let glyphCount = CTRunGetGlyphCount(run)
                guard glyphCount > 0 else { continue }
                var runGlyphs = [CGGlyph](repeating: CGGlyph(), count: glyphCount)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &runGlyphs)
                var positions = [CGPoint](repeating: .zero, count: glyphCount)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for glyphIndex in 0..<glyphCount {
                    let glyph = runGlyphs[glyphIndex]
                    guard let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) else {
                        continue
                    }
                    glyphs.append(
                        TitleGlyph(
                            outline: outline,
                            offset: CGPoint(
                                x: runOffsetX + positions[glyphIndex].x,
                                y: positions[glyphIndex].y)))
                }
            }
            result.append(
                TitleGlyphLine(width: line.width, baselineFromTop: line.baselineFromTop, glyphs: glyphs))
        }
        return result
    }

    /// The font a glyph run carries (run attributes compose the base
    /// font's traits), falling back to the base. The CFDictionary value
    /// under `kCTFontAttributeName` is documented to be a `CTFont`;
    /// `unsafeBitCast` is the only way to type it here because Swift 6
    /// rejects conditional downcasts to CoreFoundation types.
    private func runFont(of run: CTRun, base: FontSpec) -> CTFont {
        let attributes = CTRunGetAttributes(run) as CFDictionary
        let raw = CFDictionaryGetValue(
            attributes, Unmanaged.passUnretained(kCTFontAttributeName).toOpaque())
        guard let raw else { return base.ctFont }
        return unsafeBitCast(raw, to: CTFont.self)
    }
}
