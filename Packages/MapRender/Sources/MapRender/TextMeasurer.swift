import CoreGraphics
import CoreText
import Foundation
import MapCore

/// The single source of truth for node text sizes (SPEC §9): the canvas,
/// export and Quick Look all ask this measurer, so committed text never
/// changes size. Measurement results are cached under a lock; the cache
/// holds only value data, and `CTFont` instances are created per call.
public final class TextMeasurer: @unchecked Sendable {
    public struct CacheKey: Hashable, Sendable {
        let text: String
        let font: FontSpec
        let maxWidth: CGFloat?

        init(title: NodeTitle, font: FontSpec, maxWidth: CGFloat?) {
            self.text = title.text
            self.font = font
            self.maxWidth = maxWidth
        }
    }

    private var cache: [CacheKey: CGSize] = [:]
    private let lock = NSLock()
    private let cacheLimit = 8_192

    public init() {}

    public func nodeTitleSize(_ title: NodeTitle, font: FontSpec, maxWidth: CGFloat?) -> CGSize {
        let key = CacheKey(title: title, font: font, maxWidth: maxWidth)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let measured = measure(title, font: font, maxWidth: maxWidth)
        lock.lock()
        if cache.count >= cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = measured
        lock.unlock()
        return measured
    }

    /// A title with no width constraint: one line, natural width.
    public func singleLineSize(_ title: NodeTitle, font: FontSpec, lineHeight: CGFloat = 1.25) -> CGSize {
        let line = CTLineCreateWithAttributedString(
            attributed(title, font: font, color: CGColor.black, lineHeight: lineHeight))
        let height = CGFloat(CTFontGetAscent(font.ctFont) + CTFontGetDescent(font.ctFont)) * lineHeight
        guard !title.text.isEmpty else {
            return CGSize(width: 0, height: height.rounded(.up))
        }
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }

    private func measure(_ title: NodeTitle, font: FontSpec, maxWidth: CGFloat?) -> CGSize {
        guard !title.text.isEmpty else {
            return singleLineSize(title, font: font)
        }
        let single = singleLineSize(title, font: font)
        let needsWrap = title.text.contains("\n") || (maxWidth.map { $0 < single.width } ?? false)
        guard needsWrap else {
            return single
        }
        let attributed = attributed(title, font: font, color: CGColor.black, lineHeight: 1.25)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let constraints = CGSize(
            width: maxWidth ?? .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude)
        let fits = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: CFAttributedStringGetLength(attributed)), nil, constraints, nil)
        return CGSize(width: fits.width.rounded(.up), height: fits.height.rounded(.up))
    }

    /// Builds the Core Text string for a title: base font plus the
    /// allow-listed run attributes (bold, italic, code, underline, strike,
    /// color — SPEC §8.3). Pure CoreText; no AppKit types.
    public func attributed(
        _ title: NodeTitle, font: FontSpec, color: CGColor, lineHeight: CGFloat
    ) -> CFAttributedString {
        var multiple = lineHeight
        let lineSpacing = withUnsafePointer(to: &multiple) { pointer in
            CTParagraphStyleSetting(
                spec: .lineHeightMultiple,
                valueSize: MemoryLayout<CGFloat>.size,
                value: pointer
            )
        }
        let paragraph = CTParagraphStyleCreate([lineSpacing], 1)
        let baseAttributes: [CFString: Any] = [
            kCTFontAttributeName: font.ctFont,
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        let empty = CFAttributedStringCreate(nil, "" as CFString, baseAttributes as CFDictionary)
        let source = CFAttributedStringCreate(
            nil, title.text as CFString, baseAttributes as CFDictionary)
        guard let mutable = CFAttributedStringCreateMutableCopy(nil, 0, source ?? empty) else {
            return empty ?? CFAttributedStringCreate(nil, "" as CFString, nil)!
        }

        for run in title.runs {
            let totalLength = CFAttributedStringGetLength(mutable)
            let start = max(0, min(run.range.first ?? 0, totalLength))
            let runLength = max(0, min(run.range.count > 1 ? run.range[1] : 0, totalLength - start))
            guard runLength > 0 else { continue }
            let range = CFRange(location: start, length: runLength)

            if run.bold == true {
                CFAttributedStringSetAttribute(
                    mutable, range, kCTFontAttributeName, font.withBold(true).ctFont)
            }
            if run.italic == true {
                let italicFont = CTFontCreateCopyWithSymbolicTraits(
                    font.ctFont, font.size, nil, .traitItalic, .traitItalic)
                CFAttributedStringSetAttribute(mutable, range, kCTFontAttributeName, italicFont)
            }
            if run.code == true {
                let mono = FontSpec(size: font.size, monospace: true)
                CFAttributedStringSetAttribute(mutable, range, kCTFontAttributeName, mono.ctFont)
            }
            if run.underline == true {
                CFAttributedStringSetAttribute(
                    mutable, range, kCTUnderlineStyleAttributeName, CTUnderlineStyle.single.rawValue as NSNumber)
            }
            if let hex = run.color, let runColor = Self.color(fromHexString: hex) {
                CFAttributedStringSetAttribute(
                    mutable, range, kCTForegroundColorAttributeName, runColor)
            }
        }
        return mutable
    }

    /// Parses a `#RRGGBB` run color (SPEC §8.3). Strikethrough has no pure
    /// CoreText attribute; it is drawn with the text-layer refinement.
    private static func color(fromHexString raw: String) -> CGColor? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return PaperTheme.color(fromHex: value)
    }
}
