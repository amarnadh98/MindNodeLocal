import CoreGraphics
import CoreText
import Foundation
import MapCore

/// The single source of truth for node text sizes (SPEC §9): the canvas,
/// export and Quick Look all ask this measurer, so committed text never
/// changes size. Every size — single-line or wrapped — comes out of the
/// same CoreText layout call the drawer uses, and the cache keys on the
/// whole `NodeTitle` (text *and* runs), so styling changes never return
/// a stale measurement.
public final class TextMeasurer: @unchecked Sendable {
    public struct CacheKey: Hashable, Sendable {
        let title: NodeTitle
        let font: FontSpec
        let maxWidth: CGFloat?
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

    /// A title with no width constraint: one line, natural width — measured
    /// through the framesetter so the drawer lays out the identical line.
    public func singleLineSize(_ title: NodeTitle, font: FontSpec, lineHeight: CGFloat = 1.25) -> CGSize {
        guard !title.text.isEmpty else {
            let height =
                CGFloat(
                    CTFontGetAscent(font.ctFont) + CTFontGetDescent(font.ctFont)) * lineHeight
            return CGSize(width: 0, height: height.rounded(.up))
        }
        return frameSize(title, font: font, lineHeight: lineHeight, maxWidth: .greatestFiniteMagnitude)
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
        return frameSize(title, font: font, lineHeight: 1.25, maxWidth: maxWidth ?? .greatestFiniteMagnitude)
    }

    /// The framesetter layout both the measurer and the drawer agree on.
    func frameSize(
        _ title: NodeTitle, font: FontSpec, lineHeight: CGFloat, maxWidth: CGFloat
    ) -> CGSize {
        let attributed = attributed(title, font: font, color: CGColor.black, lineHeight: lineHeight)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let constraints = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let fits = CTFramesetterSuggestFrameSizeWithConstraints(
            setter,
            CFRange(location: 0, length: CFAttributedStringGetLength(attributed)),
            nil, constraints, nil)
        return CGSize(width: fits.width.rounded(.up), height: fits.height.rounded(.up))
    }

    /// Builds the Core Text string for a title: base font plus the
    /// allow-listed run attributes (bold, italic, code, underline, size,
    /// family, color — SPEC §8.3). Run traits compose into a single font
    /// per range. Strikethrough is data-only here: it has no pure CoreText
    /// attribute and draws with the canvas text-layer refinement.
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

            if let runFont = composedFont(base: font, run: run) {
                CFAttributedStringSetAttribute(mutable, range, kCTFontAttributeName, runFont.ctFont)
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

    /// Composes a run's font traits (bold weight, italic, code, size and
    /// family overrides) with the base font into one `FontSpec`.
    private func composedFont(base: FontSpec, run: Run) -> FontSpec? {
        guard
            run.bold == true || run.italic == true || run.code == true || run.size != nil
                || run.font != nil
        else { return nil }
        return FontSpec(
            size: run.size ?? base.size,
            weight: run.bold == true ? max(base.weight, 0.4) : base.weight,
            family: run.font ?? base.family,
            italic: base.italic || (run.italic == true),
            monospace: base.monospace || (run.code == true)
        )
    }

    /// Parses a `#RRGGBB` run color (SPEC §8.3).
    private static func color(fromHexString raw: String) -> CGColor? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return PaperTheme.color(fromHex: value)
    }
}
