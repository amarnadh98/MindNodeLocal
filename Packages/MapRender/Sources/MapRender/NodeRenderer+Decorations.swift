import CoreGraphics
import CoreText
import Foundation
import MapCore

/// One colored tag pill rendered under a node's title (F-TAG-1): the
/// name plus its hex color, resolved from the document's tag table at
/// scene-build time so the renderer never touches the model.
public struct TagPill: Sendable, Hashable {
    public let name: String
    public let colorHex: String

    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }
}

/// The task mark a node carries (F-TSK-1/2): a checkbox when the node
/// is itself a leaf task (done = checked), a progress ring when its
/// subtree holds task descendants.
public enum TaskMark: Sendable, Hashable {
    case checkbox(done: Bool)
    case progress(completed: Int, total: Int)

    public var isDoneCheckbox: Bool {
        if case .checkbox(done: true) = self { return true }
        return false
    }
}

/// One marker token drawn before the title (F-CNT-3): `sf:<name>`,
/// `emoji:<char>` or `sticker:<id>` (SPEC §8.2). The token is the
/// hash identity — the resolved glyph for a token is produced by one
/// host cache, so equal tokens always mean equal pixels.
public struct MarkerBadge: Sendable, Hashable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

/// A node's image block (F-CNT-2): the package asset filename (the
/// thumbnail lookup token), the display size (a **layout input**) and
/// the placement around the title.
public struct ImageBlock: Sendable, Hashable {
    public let asset: String
    public let size: CGSize
    public let placement: ImagePlacement

    public init(asset: String, size: CGSize, placement: ImagePlacement = .above) {
        self.asset = asset
        self.size = size
        self.placement = placement
    }
}

/// Everything drawn around a node's title (SPEC §7): the leading
/// decoration column (task checkbox / progress ring, the marker row),
/// the trailing badges (note ≡, link, attachment, source) and the tag
/// pill row under the title. A `nil`/empty value renders the plain node
/// M1/M2 draw today.
public struct NodeDecorations: Sendable, Hashable {
    public var task: TaskMark?
    public var hasNote: Bool
    public var linkURL: String?
    public var tags: [TagPill]
    /// Marker glyphs before the title (F-CNT-3).
    public var markers: [MarkerBadge]
    /// The image block (F-CNT-2) — its display size is a layout input.
    public var image: ImageBlock?
    /// The LaTeX flag (F-CNT-5): the title text is the LaTeX source,
    /// rendered as math when the host provides a glyph (F-CNT-5's
    /// fallback is the source text).
    public var math: Bool
    /// The source anchor's URL (F-CNT-8) — drawn as a citation chip.
    public var source: String?
    /// How many file attachments (F-CNT-7) — the paperclip badge.
    public var attachmentCount: Int

    public init(
        task: TaskMark? = nil,
        hasNote: Bool = false,
        linkURL: String? = nil,
        tags: [TagPill] = [],
        markers: [MarkerBadge] = [],
        image: ImageBlock? = nil,
        math: Bool = false,
        source: String? = nil,
        attachmentCount: Int = 0
    ) {
        self.task = task
        self.hasNote = hasNote
        self.linkURL = linkURL
        self.tags = tags
        self.markers = markers
        self.image = image
        self.math = math
        self.source = source
        self.attachmentCount = attachmentCount
    }

    public var isEmpty: Bool {
        task == nil && !hasNote && linkURL == nil && tags.isEmpty && markers.isEmpty
            && image == nil && !math && source == nil && attachmentCount == 0
    }
}

/// Fixed decoration metrics (points). The theme seam: a future theme
/// field can override `doneOpacity` and the colors; today these are
/// the Paper reference values (§7.2), and the completed task's 50%
/// text opacity is theme-controlled from here (F-TSK-1).
public enum NodeDecorationMetrics {
    /// The checkbox's and the progress ring's square edge.
    public static let checkboxSize: CGFloat = 14
    /// Gap between the leading column and the title.
    public static let leadingGap: CGFloat = 6
    /// One trailing badge's width/height.
    public static let badgeSize: CGFloat = 14
    /// Gap between two trailing badges, and between title and badges.
    public static let badgeGap: CGFloat = 5
    /// The tag pill row's height (and one pill's).
    public static let pillHeight: CGFloat = 15
    /// Vertical gap between the title row and the pill row.
    public static let pillRowGap: CGFloat = 4
    /// Horizontal padding inside one pill.
    public static let pillPadding: CGFloat = 6
    /// Gap between two pills.
    public static let pillGap: CGFloat = 5
    /// Text opacity of a completed task's title (F-TSK-1: 50%,
    /// theme-controlled).
    public static let doneOpacity: CGFloat = 0.5
    /// The pill label's font size.
    public static let pillFontSize: CGFloat = 10
    /// One marker glyph's edge (F-CNT-3).
    public static let markerSize: CGFloat = 14
    /// The gap before/after and between the marker glyphs.
    public static let markerGap: CGFloat = 3
    /// The gap between the image block and the title band (F-CNT-2).
    public static let imageGap: CGFloat = 6

    /// The marker row's width: a gap on each side plus the glyphs.
    public static func markerRowWidth(_ count: Int) -> CGFloat {
        count == 0 ? 0 : markerGap * 2 + CGFloat(count) * markerSize + CGFloat(count - 1) * markerGap
    }

    /// Total leading column width for these decorations (0 when no
    /// task mark and no markers).
    public static func leadingWidth(_ decorations: NodeDecorations?) -> CGFloat {
        guard let decorations else { return 0 }
        var width: CGFloat = decorations.task == nil ? 0 : checkboxSize + leadingGap
        width += markerRowWidth(decorations.markers.count)
        return width
    }

    /// Total trailing column width for these decorations.
    public static func trailingWidth(_ decorations: NodeDecorations?) -> CGFloat {
        guard let decorations else { return 0 }
        let badges =
            (decorations.hasNote ? 1 : 0) + (decorations.linkURL != nil ? 1 : 0)
            + (decorations.source != nil ? 1 : 0) + (decorations.attachmentCount > 0 ? 1 : 0)
        guard badges > 0 else { return 0 }
        return badgeGap + CGFloat(badges) * badgeSize + CGFloat(badges - 1) * badgeGap
    }

    /// The pill row's height (title-to-pill gap included).
    public static func tagRowHeight(_ decorations: NodeDecorations?) -> CGFloat {
        guard let decorations, !decorations.tags.isEmpty else { return 0 }
        return pillRowGap + pillHeight
    }
}

/// The decoration geometry of one node, in node coordinates — the one
/// layout the renderer, the editing overlay and hit-testing all share,
/// so a click lands where the checkbox was drawn.
public struct NodeDecorationLayout {
    /// The rect the title block may occupy (already shrunk by the
    /// image band, the leading/trailing columns and the pill row).
    public let titleRow: CGRect
    /// The checkbox's or progress ring's square, nil without a task.
    public let leadingRect: CGRect?
    /// The note badge's square, nil without a note.
    public let noteBadgeRect: CGRect?
    /// The link badge's square, nil without a link.
    public let linkBadgeRect: CGRect?
    /// The pill row's rect, nil without tags.
    public let tagRowRect: CGRect?
    /// The marker row's rect (F-CNT-3), nil without markers.
    public let markerRowRect: CGRect?
    /// The image block's rect (F-CNT-2), nil without an image. The
    /// bottom-right corner is the resize handle's hit region.
    public let imageRect: CGRect?
    /// The citation chip's square (F-CNT-8), nil without a source.
    public let sourceBadgeRect: CGRect?
    /// The attachment badge's square (F-CNT-7), nil without attachments.
    public let attachmentBadgeRect: CGRect?

    /// Layouts the decorations inside `frame`'s content rect for a
    /// title block of `textSize` (the size `TextMeasurer` returned).
    public static func layout(
        style: ResolvedNodeStyle, decorations: NodeDecorations?, contentRect: CGRect
    ) -> NodeDecorationLayout {
        guard let decorations, !decorations.isEmpty else {
            return NodeDecorationLayout(
                titleRow: contentRect, leadingRect: nil, noteBadgeRect: nil, linkBadgeRect: nil,
                tagRowRect: nil, markerRowRect: nil, imageRect: nil, sourceBadgeRect: nil,
                attachmentBadgeRect: nil)
        }

        // The image band first (F-CNT-2): above/below take a horizontal
        // strip, left/right a vertical one; the title row and its
        // columns live in the remainder.
        var rect = contentRect
        var imageRect: CGRect?
        if let image = decorations.image {
            let size = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
            switch image.placement {
            case .above:
                imageRect = CGRect(
                    x: contentRect.minX + max(0, (contentRect.width - size.width) / 2),
                    y: contentRect.minY, width: min(size.width, contentRect.width), height: size.height)
                rect = CGRect(
                    x: contentRect.minX, y: contentRect.minY + size.height + NodeDecorationMetrics.imageGap,
                    width: contentRect.width,
                    height: max(0, contentRect.height - size.height - NodeDecorationMetrics.imageGap))
            case .below:
                imageRect = CGRect(
                    x: contentRect.minX + max(0, (contentRect.width - size.width) / 2),
                    y: contentRect.maxY - size.height, width: min(size.width, contentRect.width),
                    height: size.height)
                rect = CGRect(
                    x: contentRect.minX, y: contentRect.minY, width: contentRect.width,
                    height: max(0, contentRect.height - size.height - NodeDecorationMetrics.imageGap))
            case .left:
                imageRect = CGRect(
                    x: contentRect.minX, y: rect.midY - size.height / 2, width: size.width,
                    height: size.height)
                rect = CGRect(
                    x: contentRect.minX + size.width + NodeDecorationMetrics.imageGap, y: contentRect.minY,
                    width: max(0, contentRect.width - size.width - NodeDecorationMetrics.imageGap),
                    height: contentRect.height)
            case .right:
                imageRect = CGRect(
                    x: contentRect.maxX - size.width, y: rect.midY - size.height / 2, width: size.width,
                    height: size.height)
                rect = CGRect(
                    x: contentRect.minX, y: contentRect.minY,
                    width: max(0, contentRect.width - size.width - NodeDecorationMetrics.imageGap),
                    height: contentRect.height)
            }
        }

        let leading = NodeDecorationMetrics.leadingWidth(decorations)
        let trailing = NodeDecorationMetrics.trailingWidth(decorations)
        let tagRowHeight = NodeDecorationMetrics.tagRowHeight(decorations)
        let titleRow = CGRect(
            x: rect.minX + leading,
            y: rect.minY,
            width: max(0, rect.width - leading - trailing),
            height: max(0, rect.height - tagRowHeight))

        var leadingRect: CGRect?
        if decorations.task != nil {
            leadingRect = CGRect(
                x: rect.minX,
                y: titleRow.midY - NodeDecorationMetrics.checkboxSize / 2,
                width: NodeDecorationMetrics.checkboxSize,
                height: NodeDecorationMetrics.checkboxSize)
        }

        var markerRowRect: CGRect?
        if !decorations.markers.isEmpty {
            let taskWidth =
                decorations.task == nil ? 0 : NodeDecorationMetrics.checkboxSize + NodeDecorationMetrics.leadingGap
            markerRowRect = CGRect(
                x: rect.minX + taskWidth,
                y: titleRow.midY - NodeDecorationMetrics.markerSize / 2,
                width: NodeDecorationMetrics.markerRowWidth(decorations.markers.count),
                height: NodeDecorationMetrics.markerSize)
        }

        // Trailing badges, from the right edge inward: link, note,
        // attachment, source chip.
        var noteRect: CGRect?
        var linkRect: CGRect?
        var attachmentRect: CGRect?
        var sourceRect: CGRect?
        var badgeCursor = rect.maxX
        if decorations.linkURL != nil {
            badgeCursor -= NodeDecorationMetrics.badgeSize
            linkRect = CGRect(
                x: badgeCursor, y: titleRow.midY - NodeDecorationMetrics.badgeSize / 2,
                width: NodeDecorationMetrics.badgeSize, height: NodeDecorationMetrics.badgeSize)
            badgeCursor -= NodeDecorationMetrics.badgeGap
        }
        if decorations.hasNote {
            badgeCursor -= NodeDecorationMetrics.badgeSize
            noteRect = CGRect(
                x: badgeCursor, y: titleRow.midY - NodeDecorationMetrics.badgeSize / 2,
                width: NodeDecorationMetrics.badgeSize, height: NodeDecorationMetrics.badgeSize)
            badgeCursor -= NodeDecorationMetrics.badgeGap
        }
        if decorations.attachmentCount > 0 {
            badgeCursor -= NodeDecorationMetrics.badgeSize
            attachmentRect = CGRect(
                x: badgeCursor, y: titleRow.midY - NodeDecorationMetrics.badgeSize / 2,
                width: NodeDecorationMetrics.badgeSize, height: NodeDecorationMetrics.badgeSize)
            badgeCursor -= NodeDecorationMetrics.badgeGap
        }
        if decorations.source != nil {
            badgeCursor -= NodeDecorationMetrics.badgeSize
            sourceRect = CGRect(
                x: badgeCursor, y: titleRow.midY - NodeDecorationMetrics.badgeSize / 2,
                width: NodeDecorationMetrics.badgeSize, height: NodeDecorationMetrics.badgeSize)
        }

        var tagRowRect: CGRect?
        if !decorations.tags.isEmpty {
            tagRowRect = CGRect(
                x: rect.minX, y: rect.maxY - NodeDecorationMetrics.pillHeight,
                width: rect.width, height: NodeDecorationMetrics.pillHeight)
        }

        return NodeDecorationLayout(
            titleRow: titleRow, leadingRect: leadingRect, noteBadgeRect: noteRect,
            linkBadgeRect: linkRect, tagRowRect: tagRowRect, markerRowRect: markerRowRect,
            imageRect: imageRect, sourceBadgeRect: sourceRect, attachmentBadgeRect: attachmentRect)
    }
}

extension NodeRenderer {
    /// The content size a node needs for `textSize` plus its
    /// decorations — what `SceneGeometry` adds padding to. Without
    /// decorations this is exactly `textSize`, so M1/M2 scenes are
    /// unchanged.
    ///
    /// F-CNT-2: the image block joins the size — above/below add a
    /// horizontal band (width grows to the wider of image and text),
    /// left/right add a vertical one. The LaTeX glyph (F-CNT-5) swaps
    /// `textSize` itself before this call (the scene builder measures
    /// through the host's math cache, falling back to the source text).
    public static func contentSize(
        textSize: CGSize, style: ResolvedNodeStyle, decorations: NodeDecorations?
    ) -> CGSize {
        guard let decorations, !decorations.isEmpty else { return textSize }
        let leading = NodeDecorationMetrics.leadingWidth(decorations)
        let trailing = NodeDecorationMetrics.trailingWidth(decorations)
        let gap = NodeDecorationMetrics.imageGap

        var contentWidth = textSize.width
        var contentHeight = textSize.height
        if let image = decorations.image {
            let width = max(1, image.size.width)
            let height = max(1, image.size.height)
            switch image.placement {
            case .above, .below:
                contentWidth = max(contentWidth, width)
                contentHeight += height + gap
            case .left, .right:
                contentWidth += width + gap
                contentHeight = max(contentHeight, height)
            }
        }

        let rowHeight = max(
            contentHeight,
            decorations.task == nil ? 0 : NodeDecorationMetrics.checkboxSize)
        let height = rowHeight + NodeDecorationMetrics.tagRowHeight(decorations)
        return CGSize(width: leading + contentWidth + trailing, height: height)
    }

    /// Draws the decoration columns around the already-drawn title:
    /// leading task mark and marker row, the image block, trailing
    /// badges, the citation chip and the pill row. (The completed
    /// task's strikethrough and 50% opacity ride `drawTitle`, which
    /// owns the text-space transform.)
    static func drawDecorations(
        style: ResolvedNodeStyle, layout: NodeDecorationLayout, decorations: NodeDecorations,
        measurer: TextMeasurer, media: NodeMedia?, in context: CGContext
    ) {
        let fillColor = style.borderColor ?? style.textColor
        context.saveGState()
        context.setStrokeColor(fillColor)
        context.setFillColor(fillColor)

        switch decorations.task {
        case .checkbox(let done):
            if let rect = layout.leadingRect {
                drawCheckbox(in: rect, done: done, in: context)
            }
        case .progress(let completed, let total):
            if let rect = layout.leadingRect {
                drawProgressRing(in: rect, completed: completed, total: total, in: context)
            }
        case nil:
            break
        }

        if let rect = layout.noteBadgeRect {
            drawNoteBadge(in: rect, in: context)
        }
        if let rect = layout.linkBadgeRect {
            drawLinkBadge(in: rect, in: context)
        }
        if let rect = layout.attachmentBadgeRect {
            drawAttachmentBadge(in: rect, in: context)
        }
        if let rect = layout.sourceBadgeRect {
            drawSourceChip(in: rect, in: context)
        }
        if let rect = layout.markerRowRect {
            drawMarkerRow(
                decorations.markers, in: rect, color: fillColor, measurer: measurer, media: media, in: context)
        }
        if let rect = layout.imageRect {
            drawImageBlock(in: rect, media: media, in: context)
        }
        if let row = layout.tagRowRect {
            drawTagPills(decorations.tags, in: row, in: context, measurer: measurer)
        }

        // The completed task's strikethrough (F-TSK-1). The 50% text
        // opacity itself is applied by `drawTitle` through its color.
        // (The strike over the drawn lines lives in drawTitle, where
        // the flipped text-space transform is active.)
        context.restoreGState()
    }

    // MARK: pieces

    /// An empty checkbox with a drawn check when done (no glyph
    /// dependency; stays crisp at every raster scale).
    private static func drawCheckbox(in rect: CGRect, done: Bool, in context: CGContext) {
        let box = rect.insetBy(dx: 1.25, dy: 1.25)
        let path = CGPath(
            roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.setLineWidth(1.5)
        context.addPath(path)
        context.strokePath()
        guard done else { return }
        let check = CGMutablePath()
        check.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.midY + rect.height * 0.02))
        check.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.maxY - rect.height * 0.32))
        check.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY + rect.height * 0.32))
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(check)
        context.strokePath()
    }

    /// The progress ring: a full circle stroke plus a pie wedge filled
    /// to the completed/total ratio (F-TSK-2).
    private static func drawProgressRing(
        in rect: CGRect, completed: Int, total: Int, in context: CGContext
    ) {
        guard total > 0 else { return }
        let inset = rect.insetBy(dx: 1.75, dy: 1.75)
        context.setLineWidth(1.75)
        context.strokeEllipse(in: inset)
        guard completed > 0 else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 2.5
        let fraction = CGFloat(completed) / CGFloat(total)
        // From 12 o'clock, clockwise in the flipped convention.
        let pie = CGMutablePath()
        pie.move(to: center)
        pie.addArc(
            center: center, radius: radius,
            startAngle: -.pi / 2,
            endAngle: -.pi / 2 + fraction * 2 * .pi,
            clockwise: false)
        pie.closeSubpath()
        context.addPath(pie)
        context.fillPath()
    }

    /// The note badge: three stacked lines (the "≡" of F-CNT-1, drawn
    /// as strokes so it follows the text color).
    private static func drawNoteBadge(in rect: CGRect, in context: CGContext) {
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        for step in -1...1 {
            let y = rect.midY + CGFloat(step) * rect.height * 0.22
            context.move(to: CGPoint(x: rect.minX + 2, y: y))
            context.addLine(to: CGPoint(x: rect.maxX - 2, y: y))
        }
        context.strokePath()
    }

    /// The link badge: a small rounded square with a ↗ arrow
    /// (F-CNT-4).
    private static func drawLinkBadge(in rect: CGRect, in context: CGContext) {
        let box = rect.insetBy(dx: 2.5, dy: 2.5)
        context.setLineWidth(1.2)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        context.strokePath()
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: box.minX + box.width * 0.15, y: box.maxY - box.height * 0.15))
        arrow.addLine(to: CGPoint(x: box.maxX - box.width * 0.2, y: box.minY + box.height * 0.2))
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        context.addPath(arrow)
        context.strokePath()
        context.move(to: CGPoint(x: box.maxX - box.width * 0.2, y: box.minY + box.height * 0.2))
        context.addLine(to: CGPoint(x: box.maxX - box.width * 0.2, y: box.minY + box.height * 0.55))
        context.move(to: CGPoint(x: box.maxX - box.width * 0.2, y: box.minY + box.height * 0.2))
        context.addLine(to: CGPoint(x: box.maxX - box.width * 0.55, y: box.minY + box.height * 0.2))
        context.strokePath()
    }

    /// The tag pills, laid out left to right inside the row; each a
    /// rounded rect of its tag color with a centered label (F-TAG-1).
    private static func drawTagPills(
        _ pills: [TagPill], in row: CGRect, in context: CGContext, measurer: TextMeasurer
    ) {
        let font = FontSpec(size: NodeDecorationMetrics.pillFontSize, weight: 0.1)
        var cursor = row.minX
        for pill in pills {
            let label = NodeTitle(text: pill.name)
            let textSize = measurer.singleLineSize(label, font: font)
            let width = textSize.width + NodeDecorationMetrics.pillPadding * 2
            let rect = CGRect(
                x: cursor, y: row.minY, width: width, height: row.height)
            let color = ThemeHex.color(pill.colorHex) ?? CGColor(gray: 0.5, alpha: 1)
            // Clip to the row so an over-long pill never paints
            // outside the node's content rect.
            context.saveGState()
            context.clip(to: row.insetBy(dx: 0, dy: 1))
            context.setFillColor(color)
            let radius = min(6, row.height / 2 - 1)
            context.addPath(
                CGPath(
                    roundedRect: CGRect(
                        x: rect.minX, y: row.minY + 1, width: rect.width, height: row.height - 2),
                    cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.restoreGState()

            // Label: white on dark fills, near-black on light ones.
            let luminance = Self.relativeLuminance(pill.colorHex)
            let labelColor =
                luminance > 0.55
                ? CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let attributed = measurer.attributed(
                label, font: font, color: labelColor, lineHeight: 1.1)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            context.saveGState()
            context.translateBy(x: rect.minX, y: row.maxY)
            context.scaleBy(x: 1, y: -1)
            let local = CGRect(x: 0, y: 0, width: rect.width, height: row.height)
            let textFrame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: 0, length: 0), CGPath(rect: local, transform: nil), nil)
            context.textMatrix = CGAffineTransform.identity
            context.saveGState()
            context.translateBy(x: 0, y: (row.height - textSize.height) / 2)
            CTFrameDraw(textFrame, context)
            context.restoreGState()
            context.restoreGState()
            cursor += width + NodeDecorationMetrics.pillGap
        }
    }

    /// A strikethrough over every line of the drawn title (the
    /// completed-task state of F-TSK-1). `context` carries the same
    /// flipped local transform `drawTitle` draws the CTFrame under,
    /// and line origins are already in that y-up space.
    static func drawStrikethrough(textFrame: CTFrame, in context: CGContext) {
        let lines = (CTFrameGetLines(textFrame) as? [CTLine]) ?? []
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: 0), &origins)
        context.setLineWidth(1)
        context.setLineCap(.round)
        for (line, origin) in zip(lines, origins) {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let y = origin.y + ascent * 0.28
            context.move(to: CGPoint(x: origin.x, y: y))
            context.addLine(to: CGPoint(x: origin.x + width, y: y))
        }
        context.strokePath()
    }

    /// WCAG-style relative luminance of a `#RRGGBB` color, 1.0 white.
    static func relativeLuminance(_ hex: String) -> Double {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return 0.5 }
        func channel(_ raw: UInt32) -> Double {
            let component = Double(raw) / 255
            return component <= 0.03928
                ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((value >> 16) & 0xFF)
            + 0.7152 * channel((value >> 8) & 0xFF)
            + 0.0722 * channel(value & 0xFF)
    }
}
