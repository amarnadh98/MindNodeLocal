import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

struct NodeRendererTests {
    @Test func rootFillCoversTheFrame() throws {
        let style = PaperTheme.resolvedStyle(level: 0, level1Index: 0, variant: .light)
        let context = try bitmapContext(width: 200, height: 120)
        let frame = CGRect(x: 10, y: 10, width: 120, height: 44)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: "Root"), measurer: TextMeasurer(),
            in: context, frame: frame)

        let filled = countPixels(context) { red, green, blue in
            abs(Int(red) - 44) < 12 && abs(Int(green) - 44) < 12 && abs(Int(blue) - 46) < 12
        }
        #expect(filled > 4_000, "expected the root fill (0x2C2C2E) to cover most of the frame")
    }

    @Test func underlineShapeDrawsNoFill() throws {
        let style = PaperTheme.resolvedStyle(level: 2, level1Index: 0, variant: .light)
        let context = try bitmapContext(width: 200, height: 120)
        let frame = CGRect(x: 10, y: 40, width: 160, height: 24)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: "leaf"), measurer: TextMeasurer(),
            in: context, frame: frame)

        let inked = countPixels(context) { _, _, _ in true }
        #expect(inked > 30, "expected text and underline ink")
        let centerFill = countPixels(context) { red, _, _ in red < 100 }
        #expect(centerFill < inked, "level-2 nodes must not fill their whole frame")
    }

    @Test func everyShapePathHasSensibleGeometry() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let base = ResolvedNodeStyle(
            shape: .roundedRect, fillColor: nil, textColor: CGColor.black, font: FontSpec(size: 14))
        for shape in ShapeCases.allCases.map(\.shape) {
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

    @Test func branchAnchorFollowsShape() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let base = ResolvedNodeStyle(
            shape: .roundedRect, fillColor: nil, textColor: CGColor.black, font: FontSpec(size: 14))
        #expect(NodeRenderer.branchAnchor(style: base, frame: frame) == CGPoint(x: 100, y: 20))

        var underline = base.withShape(.underline)
        underline.borderColor = PaperTheme.color(fromHex: 0xE5484D)
        underline.underlineWidth = 2
        #expect(NodeRenderer.branchAnchor(style: underline, frame: frame) == CGPoint(x: 100, y: 39))
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

private enum ShapeCases: CaseIterable {
    case roundedRect, rectangle, pill, circle, square, diamond, hexagon, octagon, cloud, underline, none

    var shape: NodeShape {
        switch self {
        case .roundedRect: .roundedRect
        case .rectangle: .rectangle
        case .pill: .pill
        case .circle: .circle
        case .square: .square
        case .diamond: .diamond
        case .hexagon: .hexagon
        case .octagon: .octagon
        case .cloud: .cloud
        case .underline: .underline
        case .none: .none
        }
    }
}

private func bitmapContext(width: Int, height: Int) throws -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: space ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    return try #require(context)
}

private func countPixels(
    _ context: CGContext, matching predicate: (UInt8, UInt8, UInt8) -> Bool
) -> Int {
    guard let data = context.data else { return 0 }
    let width = context.width
    let height = context.height
    let bytesPerRow = context.bytesPerRow
    let buffer = data.assumingMemoryBound(to: UInt8.self)
    var count = 0
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            let alpha = buffer[offset + 3]
            guard alpha > 0 else { continue }
            let red = buffer[offset]
            let green = buffer[offset + 1]
            let blue = buffer[offset + 2]
            if predicate(red, green, blue) {
                count += 1
            }
        }
    }
    return count
}

extension ResolvedNodeStyle {
    fileprivate func withShape(_ shape: NodeShape) -> ResolvedNodeStyle {
        var copy = self
        copy.shape = shape
        return copy
    }
}
