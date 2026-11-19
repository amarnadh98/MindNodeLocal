import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// Renders into a flipped (top-left origin, y-down) bitmap context — the
/// canvas convention `NodeRenderer` documents.
func flippedBitmap(width: Int, height: Int) throws -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    return context
}

private struct PixelSample {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

private func pixel(_ context: CGContext, x: Int, y: Int) -> PixelSample? {
    guard let data = context.data else { return nil }
    let buffer = data.assumingMemoryBound(to: UInt8.self)
    let offset = y * context.bytesPerRow + x * 4
    return PixelSample(
        red: buffer[offset], green: buffer[offset + 1],
        blue: buffer[offset + 2], alpha: buffer[offset + 3])
}

func countPixels(
    _ context: CGContext, matching predicate: (UInt8, UInt8, UInt8, UInt8) -> Bool
) -> Int {
    guard let data = context.data else { return 0 }
    let buffer = data.assumingMemoryBound(to: UInt8.self)
    var count = 0
    for index in stride(from: 0, to: context.bytesPerRow * context.height, by: 4) {
        let alpha = buffer[index + 3]
        guard alpha > 0 else { continue }
        if predicate(buffer[index], buffer[index + 1], buffer[index + 2], alpha) {
            count += 1
        }
    }
    return count
}

/// The flipped-y rows (0 = top) where ink matching the predicate appears.
private func inkRows(
    _ context: CGContext, width: Int, height: Int,
    matching predicate: (UInt8, UInt8, UInt8, UInt8) -> Bool
) -> [Int] {
    var rows: [Int] = []
    for y in 0..<height {
        var rowHasInk = false
        for x in 0..<width {
            guard let sample = pixel(context, x: x, y: y), sample.alpha > 0 else { continue }
            if predicate(sample.red, sample.green, sample.blue, sample.alpha) {
                rowHasInk = true
                break
            }
        }
        if rowHasInk {
            rows.append(y)
        }
    }
    return rows
}

private func isRedInk(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Bool {
    alpha > 200 && red > 150 && green < 100 && blue < 100
}

private func isTextInk(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Bool {
    alpha > 100 && red < 80 && green < 80 && blue < 80
}

struct NodeRendererTests {
    @Test func rootFillCoversTheFrame() throws {
        let style = PaperTheme.resolvedStyle(level: 0, level1Index: 0, variant: .light)
        let context = try flippedBitmap(width: 200, height: 120)
        let frame = CGRect(x: 10, y: 10, width: 120, height: 44)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: "Root"), measurer: TextMeasurer(),
            in: context, frame: frame)

        let filled = countPixels(context) { red, green, blue, _ in
            abs(Int(red) - 44) < 16 && abs(Int(green) - 44) < 16 && abs(Int(blue) - 46) < 16
        }
        #expect(filled > 4_000, "expected the root fill (0x2C2C2E) to cover most of the frame")
    }

    @Test func titlesDrawInsideTheContentRectForEveryLevelAndVariant() throws {
        let measurer = TextMeasurer()
        for variant in [ThemeVariant.light, .dark] {
            for level in 0...2 {
                var style = PaperTheme.resolvedStyle(level: level, level1Index: 0, variant: variant)
                style.textColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                style.shadows = []
                style.fillColor = nil
                style.borderColor = nil
                let title = NodeTitle(text: "Ink \(level)")
                let textSize = measurer.nodeTitleSize(
                    title, font: style.font, maxWidth: 150 - style.paddingWidth * 2)
                let context = try flippedBitmap(width: 200, height: 90)
                let frame = CGRect(
                    x: 10, y: 20,
                    width: textSize.width + style.paddingWidth * 2,
                    height: textSize.height + style.paddingHeight * 2)
                NodeRenderer.draw(style: style, title: title, measurer: measurer, in: context, frame: frame)

                let content = NodeRenderer.contentRect(style: style, frame: frame)
                let redPixels = countPixels(context, matching: isRedInk)
                #expect(redPixels > 10, "level \(level) \(variant) drew no text ink")

                let rows = inkRows(context, width: 200, height: 90, matching: isRedInk)
                #expect(
                    rows.allSatisfy { $0 >= Int(content.minY) - 1 && $0 <= Int(content.maxY) + 1 },
                    "level \(level) \(variant) text escaped the content rect: rows \(rows)")
            }
        }
    }

    @Test func rootTitleRendersAtMeasuredWeight() throws {
        let style = PaperTheme.resolvedStyle(level: 0, level1Index: 0, variant: .light)
        let measurer = TextMeasurer()
        let size = measurer.nodeTitleSize(NodeTitle(text: "Root"), font: style.font, maxWidth: nil)
        let context = try flippedBitmap(width: 200, height: 120)
        let frame = CGRect(
            x: 10, y: 10, width: size.width + style.paddingWidth * 2,
            height: size.height + style.paddingHeight * 2)
        NodeRenderer.draw(style: style, title: NodeTitle(text: "Root"), measurer: measurer, in: context, frame: frame)
        #expect(frame.width < 200 && frame.height < 120)

        let whiteInk = countPixels(context) { red, green, blue, alpha in
            alpha > 0 && red > 200 && green > 200 && blue > 200
        }
        #expect(whiteInk > 40, "root title produced no ink at its measured size")
    }

    @Test func underlineShapeDrawsNoFill() throws {
        let style = PaperTheme.resolvedStyle(level: 2, level1Index: 0, variant: .light)
        let context = try flippedBitmap(width: 200, height: 120)
        let frame = CGRect(x: 10, y: 40, width: 160, height: 24)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: "leaf"), measurer: TextMeasurer(),
            in: context, frame: frame)

        let inked = countPixels(context) { _, _, _, alpha in alpha > 0 }
        #expect(inked > 30, "expected text and underline ink")
    }

    @Test func underlineSitsBelowTheTextInk() throws {
        var style = PaperTheme.resolvedStyle(level: 2, level1Index: 3, variant: .light)
        style.textColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let underlineColor = style.borderColor
        let context = try flippedBitmap(width: 200, height: 80)
        let frame = CGRect(x: 10, y: 20, width: 160, height: 24)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: "title"), measurer: TextMeasurer(),
            in: context, frame: frame)

        let underlineHex = PaperTheme.hex(of: underlineColor ?? CGColor.black) ?? 0
        let underlineRed = UInt8((underlineHex >> 16) & 0xFF)
        let underlineGreen = UInt8((underlineHex >> 8) & 0xFF)
        let underlineBlue = UInt8(underlineHex & 0xFF)

        let textRows = inkRows(context, width: 200, height: 80, matching: isTextInk)
        let underlineRows = inkRows(context, width: 200, height: 80) { red, green, blue, _ in
            abs(Int(red) - Int(underlineRed)) < 20
                && abs(Int(green) - Int(underlineGreen)) < 20
                && abs(Int(blue) - Int(underlineBlue)) < 20
        }

        #expect(!textRows.isEmpty, "no text ink")
        #expect(!underlineRows.isEmpty, "no underline ink")
        #expect(
            (textRows.max() ?? -1) < (underlineRows.min() ?? .max),
            "underline must sit below the text ink in the flipped convention")
    }

    @Test func everyShapePathHasSensibleGeometry() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let base = ResolvedNodeStyle(
            shape: .roundedRect, fillColor: nil, textColor: CGColor.black, font: FontSpec(size: 14))
        for shape in NodeShape.allCases {
            let style = base.withShape(shape)
            let path = NodeRenderer.shapePath(style: style, frame: frame)
            let box = path.boundingBox
            switch shape {
            case .underline, .none:
                #expect(box.isEmpty)
            case .square:
                #expect(abs(box.width - 40) < 0.01)
                #expect(abs(box.height - 40) < 0.01)
            case .circle, .pill, .diamond, .hexagon, .octagon, .cloud:
                #expect(box.width > 80, "\(shape)")
                #expect(box.height > 30, "\(shape)")
            case .rectangle, .roundedRect:
                #expect(abs(box.width - 100) < 0.01)
                #expect(abs(box.height - 40) < 0.01)
            }
        }
    }

    @Test func outgoingAnchorsFollowDirection() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let base = ResolvedNodeStyle(
            shape: .roundedRect, fillColor: nil, textColor: CGColor.black, font: FontSpec(size: 14))
        #expect(NodeRenderer.outgoingAnchor(style: base, frame: frame, direction: .right) == CGPoint(x: 100, y: 20))
        #expect(NodeRenderer.outgoingAnchor(style: base, frame: frame, direction: .left) == CGPoint(x: 0, y: 20))
        #expect(NodeRenderer.outgoingAnchor(style: base, frame: frame, direction: .down) == CGPoint(x: 50, y: 40))
        #expect(NodeRenderer.incomingAnchor(style: base, frame: frame, direction: .right) == CGPoint(x: 0, y: 20))
        #expect(NodeRenderer.incomingAnchor(style: base, frame: frame, direction: .down) == CGPoint(x: 50, y: 0))

        var underline = base.withShape(.underline)
        underline.borderColor = PaperTheme.color(fromHex: 0xE5484D)
        underline.underlineWidth = 2
        #expect(
            NodeRenderer.outgoingAnchor(style: underline, frame: frame, direction: .right) == CGPoint(x: 100, y: 39))
        #expect(NodeRenderer.incomingAnchor(style: underline, frame: frame, direction: .right) == CGPoint(x: 0, y: 39))
    }

    @Test func contentRectRespectsPadding() throws {
        let style = ResolvedNodeStyle(
            shape: .roundedRect, fillColor: nil, paddingWidth: 16, paddingHeight: 10,
            textColor: CGColor.black, font: FontSpec(size: 16))
        let frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let content = NodeRenderer.contentRect(style: style, frame: frame)
        #expect(content == CGRect(x: 16, y: 10, width: 68, height: 20))
    }
}

extension ResolvedNodeStyle {
    fileprivate func withShape(_ shape: NodeShape) -> ResolvedNodeStyle {
        var copy = self
        copy.shape = shape
        return copy
    }
}
