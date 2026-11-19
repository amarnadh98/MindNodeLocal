import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// Relation drawing tests (F-REL-1/2/3): the shared path builders and
/// the pure `RelationRenderer` drawing pass (canvas rasters, SceneRenderer
/// and every exporter call the same functions), plus the theme's
/// connection/boundary placeholders wired into resolution (§7.2).
struct RelationRenderTests {
    // MARK: connection geometry

    @Test func defaultControlIsADeterministicPerpendicularBow() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 100, y: 0)
        let control = RelationPath.defaultControl(from: from, to: to)
        #expect(control == RelationPath.defaultControl(from: from, to: to))
        // Perpendicular: 15% of the 100 pt segment, straight down the
        // right-hand normal of a left→right segment.
        #expect(abs(control.x - 50) < 0.001)
        #expect(abs(control.y - 15) < 0.001)

        // The stored offset displaces the default (SPEC §8.2).
        let moved = RelationPath.controlPoint(
            from: from, to: to, storedOffset: ModelOffset(x: 10, y: -5))
        #expect(moved == CGPoint(x: 60, y: 10))

        // The handle/offset inversion round-trips through the curve's
        // t = 0.5 point: handle = (midpoint + control) / 2.
        let handle = CGPoint(x: 20, y: -20)
        let offset = RelationPath.controlOffset(forHandle: handle, from: from, to: to)
        let restored = RelationPath.controlPoint(from: from, to: to, storedOffset: offset)
        let curveMidpoint = RelationPath.point(
            onConnection: from, to: to, control: restored, straight: false, parameter: 0.5)
        #expect(abs(curveMidpoint.x - handle.x) < 0.01)
        #expect(abs(curveMidpoint.y - handle.y) < 0.01)
    }

    @Test func curveMidpointSitsBetweenSegmentMidpointAndControl() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 0, y: 100)
        let control = CGPoint(x: 40, y: 50)
        let midpoint = RelationPath.point(
            onConnection: from, to: to, control: control, straight: false, parameter: 0.5)
        // (midpoint of the segment + control) / 2 = (20, 50).
        #expect(abs(midpoint.x - 20) < 0.01)
        #expect(abs(midpoint.y - 50) < 0.01)
        // Endpoints are exact.
        let start = RelationPath.point(
            onConnection: from, to: to, control: control, straight: false, parameter: 0)
        let end = RelationPath.point(
            onConnection: from, to: to, control: control, straight: false, parameter: 1)
        #expect(start == from)
        #expect(end == to)
        // The straight style ignores the control.
        let straight = RelationPath.point(
            onConnection: from, to: to, control: control, straight: true, parameter: 0.25)
        #expect(straight == CGPoint(x: 0, y: 25))
    }

    @Test func samplesCoverTheCurveEndsIncluded() {
        let from = CGPoint(x: -10, y: 5)
        let to = CGPoint(x: 90, y: 45)
        let control = RelationPath.defaultControl(from: from, to: to)
        let samples = RelationPath.samples(
            from: from, to: to, control: control, straight: false, steps: 24)
        #expect(samples.count == 25)
        #expect(samples.first == from)
        #expect(samples.last == to)
        // Monotone parameter steps: the curve bows, so consecutive
        // samples are distinct points.
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test func arrowheadsPointIntoTheirTips() {
        let tip = CGPoint(x: 50, y: 50)
        let head = RelationPath.arrowhead(at: tip, direction: CGPoint(x: 1, y: 0), width: 1.5)
        let box = head.boundingBoxOfPath
        // The tip is the rightmost point; the base opens leftward.
        #expect(abs(box.maxX - tip.x) < 0.01)
        #expect(box.minY < tip.y && box.maxY > tip.y)
        #expect(box.width >= 6)
    }

    // MARK: boundaries

    @Test func roundedOutlineIsThePaddedCombinedFrame() {
        let frames = [
            CGRect(x: 0, y: 0, width: 50, height: 20),
            CGRect(x: 100, y: 40, width: 50, height: 20),
        ]
        let outline = RelationPath.boundaryOutline(
            frames: frames, padding: 14, cornerRadius: 16, organic: false)
        let combined = frames[0].union(frames[1]).insetBy(dx: -14, dy: -14)
        #expect(outline.boundingBoxOfPath == combined)
    }

    // MARK: summary braces

    @Test func braceHugsTheRangeAndReachesTowardTheNode() {
        let first = CGPoint(x: 0, y: 0)
        let last = CGPoint(x: 0, y: 100)
        let range = CGRect(x: -10, y: 0, width: 100, height: 100)
        let brace = RelationPath.summaryBrace(
            first: first, last: last, range: range, axis: .horizontal)
        let box = brace.boundingBoxOfPath
        // To the right of the range, reaching out by the point size.
        #expect(abs(box.minX - (range.maxX + RelationPath.braceInset - 8)) < 0.01)
        #expect(abs(box.maxX - (range.maxX + RelationPath.braceInset + RelationPath.bracePoint)) < 0.01)
        #expect(box.minY <= 0 && box.maxY >= 100)

        // The mirrored brace sits left of the range.
        let mirrored = RelationPath.summaryBrace(
            first: first, last: last, range: range, axis: .horizontal, mirrored: true)
        let mirroredBox = mirrored.boundingBoxOfPath
        #expect(abs(mirroredBox.maxX - (range.minX - RelationPath.braceInset + 8)) < 0.01)
        #expect(mirroredBox.maxX < box.minX)

        // The summary node's frame sits just beyond the brace's point.
        let nodeFrame = RelationPath.summaryNodeFrame(
            range: range, axis: .horizontal, mirrored: false, size: CGSize(width: 60, height: 24))
        #expect(nodeFrame.minX > box.maxX)
        #expect(abs(nodeFrame.midY - range.midY) < 0.01)
        let mirroredFrame = RelationPath.summaryNodeFrame(
            range: range, axis: .horizontal, mirrored: true, size: CGSize(width: 60, height: 24))
        #expect(mirroredFrame.maxX < mirroredBox.minX)
    }

    // MARK: theme resolution (§7.2 defaults, F-REL style placeholders)

    @Test func paperConnectionStyleMatchesTheDesignTokens() {
        let theme = BuiltInThemes.theme(id: "paper")
        for variant in [ThemeVariant.light, .dark] {
            let style = theme.resolvedConnectionStyle(variant: variant)
            // §7.2: 1.5 pt, dashed, arrow at the end, curve default.
            #expect(abs(style.width - 1.5) < 0.001)
            #expect(style.dash)
            #expect(style.arrowheads == .end)
            #expect(style.lineStyle == .curve)
            // The neutral gray, per variant as the theme defines it.
            let hex = PaperTheme.hex(of: style.color)
            #expect(hex == 0x8E8E93)
        }

        // Per-connection overrides fold over the theme defaults.
        let overridden = theme.resolvedConnectionStyle(
            variant: .light,
            overrides: ConnectionStyle(
                color: "#0090FF", width: 3, dash: false, arrowheads: .both,
                lineStyle: .straight))
        #expect(PaperTheme.hex(of: overridden.color) == 0x0090FF)
        #expect(overridden.width == 3)
        #expect(!overridden.dash)
        #expect(overridden.arrowheads == .both)
        #expect(overridden.lineStyle == .straight)
    }

    @Test func paperBoundaryStyleMatchesTheDesignTokens() {
        let theme = BuiltInThemes.theme(id: "paper")
        let style = theme.resolvedBoundaryStyle(variant: .light)
        // §7.2: 1 pt stroke at 60%, tinted fill, radius 16, padding 14;
        // F-REL-2's default outline is the rounded one.
        #expect(abs(style.lineWidth - 1) < 0.001)
        #expect(abs(style.stroke.alpha - 0.6) < 0.001)
        #expect(abs(style.fill.alpha - 0.10) < 0.001)
        #expect(style.cornerRadius == 16)
        #expect(style.padding == 14)
        #expect(!style.organic)
        #expect(!style.dash)

        // The reused ConnectionStyle's lineStyle selects the organic
        // outline (F-REL-2).
        let organic = theme.resolvedBoundaryStyle(
            variant: .dark, overrides: ConnectionStyle(dash: true, lineStyle: .curve))
        #expect(organic.organic)
        #expect(organic.dash)
    }

    // MARK: the pure drawing pass

    @Test func relationRendererPaintsNonEmptyPixels() throws {
        let context = try #require(makeContext(width: 200, height: 120))
        let from = CGPoint(x: 10, y: 10)
        let to = CGPoint(x: 180, y: 100)
        let control = RelationPath.defaultControl(from: from, to: to)
        let path = RelationPath.connectionPath(from: from, to: to, control: control, straight: false)
        let visual = ConnectionVisual(
            id: "conn", path: path,
            arrowStart: RelationPath.arrowhead(
                at: from, direction: CGPoint(x: -0.8, y: 0.6), width: 1.5),
            arrowEnd: RelationPath.arrowhead(
                at: to, direction: CGPoint(x: 0.8, y: -0.6), width: 1.5),
            bounds: CGRect(x: 0, y: 0, width: 200, height: 120),
            color: CGColor(srgbRed: 0.5, green: 0.5, blue: 0.55, alpha: 1),
            lineWidth: 1.5, dash: true, label: "because",
            labelCenter: RelationPath.point(
                onConnection: from, to: to, control: control, straight: false, parameter: 0.5),
            labelColor: CGColor(gray: 0, alpha: 1),
            labelFont: RelationRenderer.connectionLabelFont)
        RelationRenderer.draw(
            connection: visual, measurer: TextMeasurer(), in: context)
        #expect(nonEmptyPixels(context) > 50)

        let boundary = BoundaryVisual(
            id: "bd",
            outline: RelationPath.boundaryOutline(
                frames: [CGRect(x: 8, y: 8, width: 80, height: 20)],
                padding: 10, cornerRadius: 12, organic: false),
            bounds: CGRect(x: 0, y: 0, width: 120, height: 60),
            fillColor: CGColor(srgbRed: 0.1, green: 0.5, blue: 0.6, alpha: 0.1),
            strokeColor: CGColor(srgbRed: 0.5, green: 0.5, blue: 0.55, alpha: 0.6),
            lineWidth: 1, dash: false, title: "Group",
            titleCenter: CGPoint(x: 30, y: 14),
            titleColor: CGColor(gray: 0, alpha: 1),
            titleFont: RelationRenderer.boundaryTitleFont)
        RelationRenderer.draw(boundary: boundary, measurer: TextMeasurer(), in: context)
        #expect(nonEmptyPixels(context) > 200)

        let brace = RelationPath.summaryBrace(
            first: CGPoint(x: 8, y: 20), last: CGPoint(x: 8, y: 90),
            range: CGRect(x: 0, y: 10, width: 60, height: 90), axis: .horizontal)
        let summaryVisual = SummaryVisual(
            id: "sm", brace: brace,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 120),
            color: CGColor(gray: 0.55, alpha: 1), lineWidth: 1.5)
        RelationRenderer.draw(summary: summaryVisual, in: context)
        #expect(nonEmptyPixels(context) > 250)
    }

    // MARK: helpers

    private func makeContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private func nonEmptyPixels(_ context: CGContext) -> Int {
        guard let image = context.makeImage(),
            let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return 0 }
        let count = CFDataGetLength(data)
        var painted = 0
        for index in stride(from: 0, to: count, by: 4) {
            if bytes[index] != 0 || bytes[index + 1] != 0 || bytes[index + 2] != 0 {
                painted += 1
            }
        }
        return painted
    }
}
