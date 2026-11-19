import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// F-STY-1: every node shape's anchor geometry (§7.4) and its raster
/// golden — each shape rendered through the shared `NodeRenderer` into
/// a small bitmap, asserted by ink coverage with generous tolerance
/// (shape identity, not pixel-identical snapshots, is the contract).
struct NodeShapeGoldenTests {
    // MARK: anchors

    @Test func outgoingAndIncomingAnchorsTouchEveryShapeAtItsEdge() throws {
        let frame = CGRect(x: 10, y: 10, width: 120, height: 48)
        for shape in NodeShape.allCases {
            let style = ResolvedNodeStyle(
                shape: shape, fillColor: nil, textColor: CGColor.black, font: FontSpec(size: 14))
            // Underline nodes anchor at the line (§7.4: children leave
            // from the underline's far end).
            if shape == .underline {
                let underlineStyle = ResolvedNodeStyle(
                    shape: shape, fillColor: nil, borderColor: CGColor.black,
                    textColor: CGColor.black, font: FontSpec(size: 14), underlineWidth: 2)
                let offset = underlineStyle.underlineWidth / 2
                #expect(
                    NodeRenderer.outgoingAnchor(style: underlineStyle, frame: frame, direction: .right)
                        == CGPoint(x: frame.maxX, y: frame.maxY - offset))
                #expect(
                    NodeRenderer.incomingAnchor(style: underlineStyle, frame: frame, direction: .right)
                        == CGPoint(x: frame.minX, y: frame.maxY - offset), "\(shape)")
                continue
            }
            // Every other shape's silhouette crosses the mid-height on
            // its outer edge: polygons put an edge or vertex there,
            // ellipse-family shapes their equator.
            #expect(
                NodeRenderer.outgoingAnchor(style: style, frame: frame, direction: .right)
                    == CGPoint(x: frame.maxX, y: frame.midY), "\(shape)")
            #expect(
                NodeRenderer.outgoingAnchor(style: style, frame: frame, direction: .left)
                    == CGPoint(x: frame.minX, y: frame.midY), "\(shape)")
            #expect(
                NodeRenderer.incomingAnchor(style: style, frame: frame, direction: .right)
                    == CGPoint(x: frame.minX, y: frame.midY), "\(shape)")
            #expect(
                NodeRenderer.incomingAnchor(style: style, frame: frame, direction: .left)
                    == CGPoint(x: frame.maxX, y: frame.midY), "\(shape)")
        }
    }

    @Test func underlineIncomingAnchorSitsOnTheLineAndTheLineSpansTheFrame() throws {
        var style = ResolvedNodeStyle(
            shape: .underline, fillColor: nil, borderColor: PaperTheme.color(fromHex: 0xE5484D),
            textColor: CGColor.black, font: FontSpec(size: 14), underlineWidth: 3)
        style.paddingWidth = 0
        style.paddingHeight = 0
        let frame = CGRect(x: 0, y: 0, width: 100, height: 20)
        let anchor = NodeRenderer.incomingAnchor(style: style, frame: frame, direction: .right)
        #expect(anchor == CGPoint(x: 0, y: 20 - 1.5))

        // Raster: the underline ink spans the full frame width at the
        // anchor's row (§7.4: the branch flows into the line).
        let measurer = TextMeasurer()
        let title = NodeTitle(text: "")
        let size = measurer.nodeTitleSize(title, font: style.font, maxWidth: nil)
        let context = try flippedBitmap(width: 110, height: 30)
        let nodeFrame = CGRect(
            x: 5, y: 5, width: 100, height: size.height + style.paddingHeight * 2)
        NodeRenderer.draw(style: style, title: title, measurer: measurer, in: context, frame: nodeFrame)
        let anchorRow = Int(nodeFrame.maxY - style.underlineWidth / 2)
        var spanned = 0
        for x in 5..<105 {
            if let sample = pixel(context, x: x, y: anchorRow), sample.alpha > 100 { spanned += 1 }
        }
        #expect(spanned > 90, "the underline must continue the branch across the full width")
    }

    // MARK: raster goldens (ink coverage per shape)

    @Test func everyShapeCoversItsExpectedInkFraction() throws {
        let frame = CGRect(x: 5, y: 5, width: 120, height: 48)
        let frameArea = frame.width * frame.height
        for shape in NodeShape.allCases {
            let style = ResolvedNodeStyle(
                shape: shape, fillColor: CGColor(gray: 0, alpha: 1), cornerRadius: 10,
                textColor: CGColor.black, font: FontSpec(size: 14))
            let context = try flippedBitmap(width: 130, height: 58)
            NodeRenderer.draw(
                style: style, title: NodeTitle(text: ""), measurer: TextMeasurer(),
                in: context, frame: frame)
            let ink = CGFloat(countInk(context))
            let coverage = ink / frameArea

            switch shape {
            case .underline, .none:
                #expect(ink == 0, "\(shape) draws no fill")
            case .rectangle, .roundedRect:
                #expect(coverage > 0.95, "\(shape)")
            case .pill:
                // A pill on a short frame is the rect minus four
                // quarter-circle corners ≈ 0.91.
                #expect(abs(coverage - 0.91) < 0.06, "\(shape) coverage \(coverage)")
            case .circle:
                // The ellipse: π/4 of the frame.
                #expect(abs(coverage - 0.785) < 0.1, "\(shape) coverage \(coverage)")
            case .cloud:
                #expect(coverage > 0.65, "cloud must cover most of the frame, got \(coverage)")
                #expect(coverage < 0.95, "cloud must stay inside its frame, got \(coverage)")
            case .square:
                #expect(abs(coverage - 0.4) < 0.1, "\(shape)")
            case .diamond:
                // Two triangles: exactly half the frame.
                #expect(abs(coverage - 0.5) < 0.08, "\(shape) coverage \(coverage)")
            case .hexagon:
                // 3√3/2 of the bounding ellipse's circle ≈ 0.65.
                #expect(abs(coverage - 0.65) < 0.08, "\(shape) coverage \(coverage)")
            case .octagon:
                // 2√2 of the circle ≈ 0.71 of the frame.
                #expect(abs(coverage - 0.71) < 0.08, "\(shape) coverage \(coverage)")
            }
        }
    }

    @Test func cloudOutlineIsBumpyNotAnEllipse() throws {
        // The cloud must differ from the old ellipse placeholder in
        // *shape*: an ellipse's top boundary is one smooth dome, the
        // cloud's has notches between its three top bumps.
        let frame = CGRect(x: 5, y: 5, width: 120, height: 48)
        let cloud = ResolvedNodeStyle(
            shape: .cloud, fillColor: CGColor(gray: 0, alpha: 1),
            textColor: CGColor.black, font: FontSpec(size: 14))
        let ellipse = ResolvedNodeStyle(
            shape: .circle, fillColor: CGColor(gray: 0, alpha: 1),
            textColor: CGColor.black, font: FontSpec(size: 14))
        #expect(try topBoundaryDips(cloud, frame: frame) >= 2, "the cloud needs notches between bumps")
        #expect(try topBoundaryDips(ellipse, frame: frame) == 0, "the ellipse is one smooth dome")
    }

    @Test func dashedBorderInkRunsShortOfTheSolidOne() throws {
        let frame = CGRect(x: 5, y: 5, width: 120, height: 48)
        func borderInk(dash: Bool) throws -> Int {
            var style = ResolvedNodeStyle(
                shape: .rectangle, fillColor: nil, borderColor: CGColor(gray: 0, alpha: 1),
                borderWidth: 3, borderDash: dash,
                textColor: CGColor.black, font: FontSpec(size: 14))
            style.cornerRadius = 0
            let context = try flippedBitmap(width: 130, height: 58)
            NodeRenderer.draw(
                style: style, title: NodeTitle(text: ""), measurer: TextMeasurer(),
                in: context, frame: frame)
            return countInk(context)
        }
        let solid = try borderInk(dash: false)
        let dashed = try borderInk(dash: true)
        #expect(solid > 500, "the solid border should leave visible ink")
        #expect(
            Double(dashed) < Double(solid) * 0.75,
            "the 4/3 dash pattern must break the border up (solid \(solid), dashed \(dashed))")
    }

    // MARK: text alignment

    @Test func textAlignmentPinsInkToItsEdge() throws {
        let measurer = TextMeasurer()
        for (alignment, expectedEdge) in [
            (ResolvedTextAlignment.leading, "leading"), (.trailing, "trailing"),
        ] {
            var style = ResolvedNodeStyle(
                shape: .rectangle, fillColor: nil, paddingWidth: 10, paddingHeight: 6,
                textColor: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                font: FontSpec(size: 14), textAlignment: alignment)
            style.shadows = []
            let title = NodeTitle(text: "Ink")
            let textSize = measurer.nodeTitleSize(title, font: style.font, maxWidth: 200)
            let frame = CGRect(
                x: 0, y: 0, width: 160, height: textSize.height + style.paddingHeight * 2)
            let context = try flippedBitmap(width: 170, height: 40)
            NodeRenderer.draw(style: style, title: title, measurer: measurer, in: context, frame: frame)

            let rows = 0..<Int(frame.height)
            var columns: Set<Int> = []
            for y in rows {
                for x in 0..<170 {
                    guard let sample = pixel(context, x: x, y: y) else { continue }
                    if sample.alpha > 150, sample.red > 200, sample.green < 80, sample.blue < 80 {
                        columns.insert(x)
                    }
                }
            }
            #expect(!columns.isEmpty, "no text ink for \(expectedEdge)")
            let minX = columns.min() ?? 0
            let maxX = columns.max() ?? 0
            if alignment == .leading {
                #expect(minX < 15, "leading text must start at the content edge (found \(minX))")
            } else {
                #expect(
                    maxX > Int(frame.maxX) - 15,
                    "trailing text must end at the content edge (found \(maxX))")
            }
        }
    }

    // MARK: helpers

    /// Notches in the shape's top boundary: interior columns where the
    /// first inked row sits ≥ 2 rows *below* both flanks (smoothed over
    /// ±2 columns). An ellipse has none; the cloud's bumps create them.
    private func topBoundaryDips(_ style: ResolvedNodeStyle, frame: CGRect) throws -> Int {
        let context = try flippedBitmap(width: 130, height: 58)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: ""), measurer: TextMeasurer(),
            in: context, frame: frame)
        var tops: [Int?] = []
        for x in 0..<130 {
            var top: Int?
            for y in 0..<58 where (pixel(context, x: x, y: y)?.alpha ?? 0) > 200 {
                top = y
                break
            }
            tops.append(top)
        }
        // Interior columns only (skip the silhouette's outer ends) and
        // smooth, so raster stair-stepping cannot fake a notch.
        let interior = 15..<115
        func smoothedTop(_ x: Int) -> Int? {
            let window = (x - 2)...(x + 2)
            let values = window.compactMap { tops[$0] }
            guard values.count == window.count else { return nil }
            return values.reduce(0, +) / values.count
        }
        var dips = 0
        for x in interior {
            guard x - 4 >= interior.lowerBound, x + 4 < interior.upperBound else { continue }
            guard let here = smoothedTop(x), let left = smoothedTop(x - 4), let right = smoothedTop(x + 4) else {
                continue
            }
            if here >= left + 2, here >= right + 2 {
                dips += 1
            }
        }
        return dips
    }

    private func inkFraction(_ style: ResolvedNodeStyle, frame: CGRect) throws -> Double {
        let context = try flippedBitmap(width: 130, height: 58)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: ""), measurer: TextMeasurer(),
            in: context, frame: frame)
        return Double(countInk(context)) / Double(frame.width * frame.height)
    }
}

/// Renders into a flipped (top-left origin, y-down) bitmap context — the
/// canvas convention `NodeRenderer` documents.
private func flippedBitmap(width: Int, height: Int) throws -> CGContext {
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

private func countInk(_ context: CGContext) -> Int {
    guard let data = context.data else { return 0 }
    let buffer = data.assumingMemoryBound(to: UInt8.self)
    var count = 0
    for index in stride(from: 0, to: context.bytesPerRow * context.height, by: 4)
    where buffer[index + 3] > 200 {
        count += 1
    }
    return count
}
