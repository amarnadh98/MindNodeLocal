import CoreGraphics
import CoreText
import Foundation
import MapCore
import Testing

@testable import MapRender

@Test func emptyTitleMeasuresZeroWidth() {
    let measurer = TextMeasurer()
    let size = measurer.nodeTitleSize(NodeTitle(text: ""), font: FontSpec(size: 16), maxWidth: nil)
    #expect(size.width == 0)
    #expect(size.height >= 16)
}

@Test func shortTitleIsSingleLine() {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 16)
    let size = measurer.nodeTitleSize(NodeTitle(text: "Hello"), font: font, maxWidth: nil)
    #expect(size.width > 10)
    #expect(size.width < 200)
    #expect(size.height >= font.size)
    #expect(size.height <= font.size * 2)
}

@Test func longTitleWrapsAtMaxWidth() {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 14)
    let text = String(repeating: "word ", count: 30)
    let single = measurer.nodeTitleSize(NodeTitle(text: text), font: font, maxWidth: nil)
    let wrapped = measurer.nodeTitleSize(NodeTitle(text: text), font: font, maxWidth: 100)

    #expect(single.width > 100)
    #expect(wrapped.width <= 101)
    #expect(wrapped.height > single.height * 1.9)
}

@Test func shortTitleDoesNotWrapUnderMaxWidth() {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 14)
    let single = measurer.nodeTitleSize(NodeTitle(text: "tiny"), font: font, maxWidth: nil)
    let capped = measurer.nodeTitleSize(NodeTitle(text: "tiny"), font: font, maxWidth: 300)
    #expect(single == capped)
}

@Test func measurementIsDeterministicAndCached() {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 16)
    let title = NodeTitle(text: "stable measurement")
    let first = measurer.nodeTitleSize(title, font: font, maxWidth: nil)
    let second = measurer.nodeTitleSize(title, font: font, maxWidth: nil)
    #expect(first == second)

    let text = String(repeating: "wrap me please ", count: 10)
    let wrappedFirst = measurer.nodeTitleSize(NodeTitle(text: text), font: font, maxWidth: 120)
    let wrappedSecond = measurer.nodeTitleSize(NodeTitle(text: text), font: font, maxWidth: 120)
    #expect(wrappedFirst == wrappedSecond)
}

@Test func runsApplyFontAttributes() throws {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 14)
    let title = NodeTitle(
        text: "bold italic code",
        runs: [
            Run(range: [0, 4], bold: true),
            Run(range: [5, 6], italic: true),
            Run(range: [12, 4], code: true),
        ])
    let attributed = measurer.attributed(title, font: font, color: CGColor.black, lineHeight: 1.25)

    func fontName(at location: Int) -> String? {
        guard
            let raw = CFAttributedStringGetAttribute(
                attributed, CFIndex(location), kCTFontAttributeName, nil)
        else { return nil }
        let ctFont = unsafeBitCast(raw, to: CTFont.self)
        return CTFontCopyName(ctFont, kCTFontFullNameKey) as String?
    }

    guard let boldName = fontName(at: 0),
        let italicName = fontName(at: 5),
        let codeName = fontName(at: 12)
    else {
        Issue.record("run font attribute missing")
        return
    }

    #expect(boldName != italicName)
    #expect(codeName.contains("Menlo"))
}

@Test func multilineTitleTalliesLines() {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 14)
    let single = measurer.nodeTitleSize(NodeTitle(text: "one two"), font: font, maxWidth: nil)
    let multi = measurer.nodeTitleSize(
        NodeTitle(text: "one\ntwo"), font: font, maxWidth: nil)
    #expect(multi.height > single.height * 1.4)
}

@Test func runColorParsesHex() throws {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 14)
    let title = NodeTitle(text: "red", runs: [Run(range: [0, 3], color: "#E5484D")])
    let attributed = measurer.attributed(title, font: font, color: CGColor.black, lineHeight: 1.25)
    guard
        let raw = CFAttributedStringGetAttribute(
            attributed, 0, kCTForegroundColorAttributeName, nil)
    else {
        Issue.record("run color attribute missing")
        return
    }
    let color = unsafeBitCast(raw, to: CGColor.self)
    #expect(PaperTheme.hex(of: color) == 0xE5484D)
}
