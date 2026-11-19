import CoreGraphics
import CoreText

extension FontSpec {
    /// The font's ascent under the standard 1.25 export line height —
    /// the baseline distance the outline PDF lays its first line at.
    public var lineHeightAscent: CGFloat {
        CGFloat(CTFontGetAscent(ctFont)) * 1.25
    }
}
