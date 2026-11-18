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

@Test func cacheIsSensitiveToRuns() {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 16)
    let plain = NodeTitle(text: "Hello wide world")
    let bolded = NodeTitle(
        text: "Hello wide world", runs: [Run(range: [0, 16], bold: true)])

    let plainSize = measurer.nodeTitleSize(plain, font: font, maxWidth: nil)
    let boldSize = measurer.nodeTitleSize(bolded, font: font, maxWidth: nil)
    #expect(boldSize != plainSize, "a bold run must not reuse the plain title's cached size")

    let plainAgain = measurer.nodeTitleSize(plain, font: font, maxWidth: nil)
    #expect(plainAgain == plainSize, "the plain entry must survive the bold lookup")
}

@Test func measuredFontsResolveToSFWeights() {
    let postScriptNames = [
        FontSpec(size: 20, weight: 0.0),
        FontSpec(size: 16, weight: 0.23),
        FontSpec(size: 20, weight: 0.3),
        FontSpec(size: 20, weight: 0.4),
    ].map { spec in
        CTFontCopyPostScriptName(spec.ctFont) as String? ?? ""
    }
    #expect(postScriptNames[0] == ".SFNS-Regular")
    #expect(postScriptNames[1] == ".SFNS-Medium")
    #expect(postScriptNames[2] == ".SFNS-Semibold")
    #expect(postScriptNames[3] == ".SFNS-Bold")
}

@Test func runTraitsComposeIntoOneFont() throws {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 14)
    let title = NodeTitle(
        text: "bold italic code",
        runs: [
            Run(range: [5, 6], bold: true, italic: true),
            Run(range: [12, 4], bold: true, italic: true, code: true),
        ])
    let attributed = measurer.attributed(title, font: font, color: CGColor.black, lineHeight: 1.25)

    func postScriptName(at location: Int) -> String? {
        guard
            let raw = CFAttributedStringGetAttribute(
                attributed, CFIndex(location), kCTFontAttributeName, nil)
        else { return nil }
        let runFont = unsafeBitCast(raw, to: CTFont.self)
        return CTFontCopyPostScriptName(runFont) as String?
    }

    let boldItalic = try #require(postScriptName(at: 5))
    #expect(boldItalic.contains("Bold"), "bold+italic must keep the bold trait: \(boldItalic)")
    #expect(boldItalic.contains("Italic"), "bold+italic must keep the italic trait: \(boldItalic)")

    let monoBoldItalic = try #require(postScriptName(at: 12))
    #expect(monoBoldItalic.hasPrefix("Menlo"), "code runs win the family: \(monoBoldItalic)")
}

@Test func sizeAndFamilyRunsAffectMeasurement() {
    let measurer = TextMeasurer()
    let font = FontSpec(size: 14)
    let plain = NodeTitle(text: "run styles")
    let enlarged = NodeTitle(
        text: "run styles", runs: [Run(range: [0, 10], size: 28)])

    let plainSize = measurer.nodeTitleSize(plain, font: font, maxWidth: nil)
    let enlargedSize = measurer.nodeTitleSize(enlarged, font: font, maxWidth: nil)
    #expect(enlargedSize.height > plainSize.height, "a 28 pt run must measure taller")
    #expect(enlargedSize.width > plainSize.width)
}
