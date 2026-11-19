import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import MapRender

/// Node decorations (SPEC §7, M3): the leading task checkbox / progress
/// ring, the trailing note/link badges, the tag pill row under the
/// title, and the completed task's dimmed strikethrough — all measured
/// so scene layout sizes include them, and drawn through the same
/// `NodeRenderer` the canvas and export share.
struct NodeDecorationTests {
    private let measurer = TextMeasurer()

    private func levelStyle() -> ResolvedNodeStyle {
        var style = PaperTheme.resolvedStyle(level: 1, level1Index: 0, variant: .light)
        style.fillColor = nil
        style.borderColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        return style
    }

    private func textSize(of title: String, style: ResolvedNodeStyle) -> CGSize {
        measurer.nodeTitleSize(NodeTitle(text: title), font: style.font, maxWidth: 150)
    }

    private func frame(
        style: ResolvedNodeStyle, textSize: CGSize, decorations: NodeDecorations?
    ) -> CGRect {
        let content = NodeRenderer.contentSize(textSize: textSize, style: style, decorations: decorations)
        return CGRect(
            x: 10, y: 10,
            width: content.width + style.paddingWidth * 2,
            height: content.height + style.paddingHeight * 2)
    }

    private func draw(
        style: ResolvedNodeStyle, title: String, decorations: NodeDecorations?, width: Int, height: Int
    ) throws -> CGContext {
        let context = try flippedBitmap(width: width, height: height)
        NodeRenderer.draw(
            style: style, title: NodeTitle(text: title), decorations: decorations,
            measurer: measurer, in: context,
            frame: frame(style: style, textSize: textSize(of: title, style: style), decorations: decorations))
        return context
    }

    private func isBlueInk(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> Bool {
        alpha > 150 && blue > 120 && red < 100 && green < 100
    }

    // MARK: measurement

    @Test func contentSizeGrowsWithEachDecoration() {
        let style = levelStyle()
        let textSize = CGSize(width: 100, height: 20)
        let plain = NodeRenderer.contentSize(textSize: textSize, style: style, decorations: nil)
        #expect(plain == textSize, "no decorations keeps the raw text size")

        let task = NodeRenderer.contentSize(
            textSize: textSize, style: style,
            decorations: NodeDecorations(task: .checkbox(done: false)))
        #expect(task.width > textSize.width)
        #expect(task.height >= max(textSize.height, NodeDecorationMetrics.checkboxSize))

        let badges = NodeRenderer.contentSize(
            textSize: textSize, style: style,
            decorations: NodeDecorations(hasNote: true, linkURL: "https://a.b"))
        #expect(badges.width > task.width - NodeDecorationMetrics.leadingWidth(nil))

        let pills = NodeRenderer.contentSize(
            textSize: textSize, style: style,
            decorations: NodeDecorations(tags: [TagPill(name: "exam", colorHex: "#E5484D")]))
        #expect(pills.height > textSize.height, "the pill row grows the content height")
        #expect(pills.width == textSize.width, "pills grow height, not width")
    }

    @Test func decorationLayoutPlacesLeadingAndBadgesAroundTheTitle() {
        let style = levelStyle()
        let decorations = NodeDecorations(
            task: .checkbox(done: false), hasNote: true,
            linkURL: "x-arbor://open", tags: [TagPill(name: "a", colorHex: "#E5484D")])
        let frame = CGRect(x: 0, y: 0, width: 220, height: 60)
        let layout = NodeRenderer.decorationLayout(style: style, decorations: decorations, frame: frame)
        let content = NodeRenderer.contentRect(style: style, frame: frame)

        #expect(layout.leadingRect?.midX == content.minX + NodeDecorationMetrics.checkboxSize / 2)
        #expect(layout.titleRow.minX == content.minX + NodeDecorationMetrics.leadingWidth(decorations))
        #expect(layout.titleRow.maxX <= content.maxX - NodeDecorationMetrics.trailingWidth(decorations) + 0.5)
        #expect(layout.titleRow.maxY == content.maxY - NodeDecorationMetrics.tagRowHeight(decorations))
        #expect(layout.linkBadgeRect!.maxX == content.maxX)
        #expect(layout.noteBadgeRect!.maxX < layout.linkBadgeRect!.minX)
        #expect(layout.tagRowRect!.maxY == content.maxY)
        // Without decorations the layout is the plain content rect.
        let plain = NodeRenderer.decorationLayout(style: style, decorations: nil, frame: frame)
        #expect(plain.titleRow == content)
        #expect(plain.leadingRect == nil)
    }

    // MARK: drawing goldens (tolerant pixel counts)

    @Test func checkboxAndDoneStrikeDraw() throws {
        let style = levelStyle()
        let openDecorations = NodeDecorations(task: .checkbox(done: false))
        let doneDecorations = NodeDecorations(task: .checkbox(done: true))

        let open = try draw(style: style, title: "Open", decorations: openDecorations, width: 200, height: 90)
        let done = try draw(style: style, title: "Open", decorations: doneDecorations, width: 200, height: 90)

        let ink = { (context: CGContext) -> Int in
            countPixels(context) { red, green, blue, alpha in
                isBlueInk(red: red, green: green, blue: blue, alpha: alpha)
            }
        }
        let openInk = ink(open)
        #expect(openInk > 0, "the open checkbox outline drew")

        // The done checkbox adds the checkmark AND the strikethrough
        // over the (dimmed) title — strictly more ink.
        #expect(ink(done) > openInk + 10, "a done task adds check + strike ink")

        // The leading column is where the checkbox lives: its rect
        // carries ink on the open draw too.
        let layout = NodeRenderer.decorationLayout(
            style: style, decorations: openDecorations,
            frame: frame(style: style, textSize: textSize(of: "Open", style: style), decorations: openDecorations))
        guard let data = open.data, let leading = layout.leadingRect else {
            Issue.record("missing leading rect or context data")
            return
        }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        var leadingInk = 0
        for y in Int(leading.minY)...Int(leading.maxY) {
            for x in Int(leading.minX)...Int(leading.maxX) {
                if buffer[y * open.bytesPerRow + x * 4 + 3] > 150 {
                    leadingInk += 1
                }
            }
        }
        #expect(leadingInk > 10, "the checkbox column carries ink")
    }

    @Test func progressRingFillsWithTheRatio() throws {
        let style = levelStyle()
        let empty = try draw(
            style: style, title: "Plan", decorations: .init(task: .progress(completed: 0, total: 4)), width: 200,
            height: 90)
        let half = try draw(
            style: style, title: "Plan", decorations: .init(task: .progress(completed: 2, total: 4)), width: 200,
            height: 90)
        let full = try draw(
            style: style, title: "Plan", decorations: .init(task: .progress(completed: 4, total: 4)), width: 200,
            height: 90)

        let ringInk = { (context: CGContext) -> Int in
            countPixels(context) { red, green, blue, alpha in
                isBlueInk(red: red, green: green, blue: blue, alpha: alpha)
            }
        }
        let emptyCount = ringInk(empty)
        #expect(emptyCount > 0, "the ring outline drew")
        #expect(ringInk(half) > emptyCount + 20, "a half-filled ring has more ink")
        #expect(ringInk(full) > ringInk(half) + 20, "a full ring has the most")
    }

    @Test func badgesDrawInTheirColumns() throws {
        let style = levelStyle()
        let none = try draw(style: style, title: "Link", decorations: nil, width: 200, height: 90)
        let both = try draw(
            style: style, title: "Link", decorations: .init(hasNote: true, linkURL: "https://x.y"), width: 200,
            height: 90)
        let ink = { (context: CGContext) -> Int in
            countPixels(context) { red, green, blue, alpha in
                isBlueInk(red: red, green: green, blue: blue, alpha: alpha)
            }
        }
        #expect(ink(both) > ink(none) + 20, "the note and link badges added ink")

        // And the badges sit in the trailing column: their rect overlaps
        // the drawn ink.
        let context = both
        let decorations = NodeDecorations(hasNote: true, linkURL: "https://x.y")
        let frame = self.frame(style: style, textSize: textSize(of: "Link", style: style), decorations: decorations)
        let layout = NodeRenderer.decorationLayout(style: style, decorations: decorations, frame: frame)
        var foundBadgeInk = false
        if let data = context.data {
            let buffer = data.assumingMemoryBound(to: UInt8.self)
            for rect in [layout.noteBadgeRect, layout.linkBadgeRect] {
                guard let rect else { continue }
                for y in Int(rect.minY)...Int(rect.maxY) where y >= 0 && y < 90 {
                    for x in Int(rect.minX)...Int(rect.maxX) where x >= 0 && x < 200 {
                        let offset = y * context.bytesPerRow + x * 4
                        if buffer[offset + 3] > 150 {
                            foundBadgeInk = true
                        }
                    }
                }
            }
        }
        #expect(foundBadgeInk, "badge columns carry drawn ink")
    }

    @Test func tagPillsDrawColoredUnderTheTitle() throws {
        let style = levelStyle()
        let decorations = NodeDecorations(tags: [TagPill(name: "exam", colorHex: "#E5484D")])
        let context = try draw(style: style, title: "Revise", decorations: decorations, width: 200, height: 90)

        // The pill's fill (a red close to #E5484D) appears somewhere.
        let redPill = countPixels(context) { red, green, blue, alpha in
            alpha > 200 && red > 170 && green < 120 && blue < 120
        }
        #expect(redPill > 40, "the red tag pill fill drew")

        // And it sits below the title row, inside the pill row's rect.
        let layout = NodeRenderer.decorationLayout(
            style: style, decorations: decorations,
            frame: frame(style: style, textSize: textSize(of: "Revise", style: style), decorations: decorations))
        guard let data = context.data, let row = layout.tagRowRect else {
            Issue.record("missing pill row or context data")
            return
        }
        let buffer = data.assumingMemoryBound(to: UInt8.self)
        var pillInk = 0
        for y in Int(row.minY)...Int(row.maxY) {
            for x in Int(row.minX)...Int(row.maxX) {
                let offset = y * context.bytesPerRow + x * 4
                if buffer[offset + 3] > 200, buffer[offset] > 170, buffer[offset + 1] < 120 {
                    pillInk += 1
                }
            }
        }
        #expect(pillInk > 40, "the pill ink is inside the pill row (under the title)")
    }

    @Test func relativeLuminanceSortsLightFromDark() {
        #expect(NodeRenderer.relativeLuminance("#FFFFFF") > 0.9)
        #expect(NodeRenderer.relativeLuminance("#000000") < 0.1)
        #expect(NodeRenderer.relativeLuminance("#E5484D") > 0.1 && NodeRenderer.relativeLuminance("#E5484D") < 0.5)
    }

    // MARK: raster key integration

    @Test func decorationsChangeTheRasterKeyInput() {
        // The raster key (CanvasKit) hashes the whole decoration value;
        // MapRender's part of that contract is stable equality.
        var base = NodeDecorations(task: .checkbox(done: false), hasNote: false, linkURL: nil, tags: [])
        var variant = base
        #expect(base == variant)
        variant.task = .checkbox(done: true)
        #expect(base != variant)
        variant.task = nil
        variant.tags = [TagPill(name: "x", colorHex: "#FFFFFF")]
        #expect(base != variant)
    }
}
