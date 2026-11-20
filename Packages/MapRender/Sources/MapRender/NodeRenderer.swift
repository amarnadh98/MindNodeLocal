import CoreGraphics
import CoreText
import Foundation
import MapCore

/// One layer of a node shadow (SPEC §7.2: the raised style is two layers).
public struct ShadowLayer {
    public let offsetY: CGFloat
    public let blur: CGFloat
    public let color: CGColor

    public init(offsetY: CGFloat, blur: CGFloat, color: CGColor) {
        self.offsetY = offsetY
        self.blur = blur
        self.color = color
    }
}

/// The side of a parent a branch leaves from — right/left for horizontal
/// layouts, down/up for vertical ones.
public enum BranchDirection: Sendable, Hashable {
    case right
    case left
    case down
    case up
}

/// Horizontal placement of the title inside the content rect (F-STY-2
/// text alignment; `.center` is the optical default of §7.5).
public enum ResolvedTextAlignment: String, Sendable, Hashable {
    case leading
    case center
    case trailing
}

/// A node's visual style after theme resolution (SPEC §7.2, F-STY-2/F-STY-3):
/// theme → level style → branch color → per-node overrides, flattened into
/// one value the renderer consumes. Render types hold `CGColor`/`CGPath`
/// and are not `Sendable`; rendering happens on one context (canvas,
/// export or Quick Look).
public struct ResolvedNodeStyle {
    public var shape: NodeShape
    public var fillColor: CGColor?
    public var borderColor: CGColor?
    public var borderWidth: CGFloat
    /// Dashed border stroke (F-STY-2; §7.2's 4/3 dash rhythm).
    public var borderDash: Bool
    public var cornerRadius: CGFloat
    public var paddingWidth: CGFloat
    public var paddingHeight: CGFloat
    public var textColor: CGColor
    public var font: FontSpec
    /// The title's horizontal alignment inside the content rect
    /// (F-STY-2 text alignment).
    public var textAlignment: ResolvedTextAlignment
    public var underlineWidth: CGFloat
    public var shadows: [ShadowLayer]
    /// Auto-width floors at this (F-STY-2 width min; 0 = no floor).
    public var minWidth: CGFloat
    public var maxWidth: CGFloat

    public init(
        shape: NodeShape,
        fillColor: CGColor?,
        borderColor: CGColor? = nil,
        borderWidth: CGFloat = 0,
        borderDash: Bool = false,
        cornerRadius: CGFloat = 0,
        paddingWidth: CGFloat = 10,
        paddingHeight: CGFloat = 10,
        textColor: CGColor,
        font: FontSpec,
        textAlignment: ResolvedTextAlignment = .center,
        underlineWidth: CGFloat = 0,
        shadows: [ShadowLayer] = [],
        minWidth: CGFloat = 0,
        maxWidth: CGFloat = 280
    ) {
        self.shape = shape
        self.fillColor = fillColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.borderDash = borderDash
        self.cornerRadius = cornerRadius
        self.paddingWidth = paddingWidth
        self.paddingHeight = paddingHeight
        self.textColor = textColor
        self.font = font
        self.textAlignment = textAlignment
        self.underlineWidth = underlineWidth
        self.shadows = shadows
        self.minWidth = minWidth
        self.maxWidth = maxWidth
    }
}

/// Draws nodes into any `CGContext` — the one renderer behind the canvas,
/// export and Quick Look (SPEC §11: a single `TextMeasurer` and
/// `NodeRenderer` is shared by all of them).
///
/// Coordinate convention: the context must be **flipped** (top-left
/// origin, `y` growing down), matching the canvas and `TreeLayout`'s
/// frame space. Titles render upright inside that convention; the
/// underline shape sits at the frame's *bottom* edge (`maxY`).
public enum NodeRenderer {
    /// Draws the node: shape (shadow layer by shadow layer), border, then
    /// the title optically centered (SPEC §7.5) with its decorations —
    /// the leading task mark, trailing note/link badges and tag pills —
    /// when `decorations` carries any (SPEC §7). One renderer for the
    /// canvas, export and Quick Look (SPEC §11).
    public static func draw(
        style: ResolvedNodeStyle, title: NodeTitle, decorations: NodeDecorations? = nil,
        measurer: TextMeasurer, media: NodeMedia? = nil, in context: CGContext, frame: CGRect
    ) {
        context.saveGState()

        if let fillColor = style.fillColor {
            if style.shadows.isEmpty {
                context.setFillColor(fillColor)
                context.addPath(shapePath(style: style, frame: frame))
                context.fillPath()
            } else {
                for shadow in style.shadows {
                    context.saveGState()
                    context.setShadow(
                        offset: CGSize(width: 0, height: -shadow.offsetY),
                        blur: shadow.blur,
                        color: shadow.color)
                    context.setFillColor(fillColor)
                    context.addPath(shapePath(style: style, frame: frame))
                    context.fillPath()
                    context.restoreGState()
                }
            }
        }

        if style.shape != .underline, style.shape != .none, let borderColor = style.borderColor, style.borderWidth > 0 {
            context.setStrokeColor(borderColor)
            context.setLineWidth(style.borderWidth)
            if style.borderDash {
                // §7.2's connection dash rhythm doubles as the dashed
                // border token (F-STY-2 border dash).
                context.setLineDash(phase: 0, lengths: [4, 3])
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.addPath(shapePath(style: style, frame: frame))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }

        if let underlineColor = style.borderColor, style.shape == .underline {
            let underlineY = frame.maxY - style.underlineWidth / 2
            context.setStrokeColor(underlineColor)
            context.setLineWidth(style.underlineWidth)
            context.move(to: CGPoint(x: frame.minX, y: underlineY))
            context.addLine(to: CGPoint(x: frame.maxX, y: underlineY))
            context.strokePath()
        }

        drawTitle(
            style: style, title: title, decorations: decorations, media: media, measurer: measurer, in: context,
            frame: frame)
        if let decorations, !decorations.isEmpty {
            let layout = decorationLayout(style: style, decorations: decorations, frame: frame)
            drawDecorations(
                style: style, layout: layout, decorations: decorations,
                measurer: measurer, media: media, in: context)
        }
        context.restoreGState()
    }

    /// The decoration layout of a node frame: title row, leading mark,
    /// trailing badges and the pill row, in node coordinates. The
    /// editing overlay and hit-testing share it, so a click lands where
    /// the renderer drew.
    public static func decorationLayout(
        style: ResolvedNodeStyle, decorations: NodeDecorations?, frame: CGRect
    ) -> NodeDecorationLayout {
        NodeDecorationLayout.layout(
            style: style, decorations: decorations, contentRect: contentRect(style: style, frame: frame))
    }

    /// Text is optically centered in the padded content rect, laid out with
    /// the same framesetter constraints the measurer used, so a frame sized
    /// exactly to the measurement always fits its lines. `CTFrameDraw`
    /// renders y-up, so the context is flipped locally around the text
    /// rect to keep glyphs upright in the flipped convention.
    ///
    /// Decorations reshape the rect: the title centers inside the
    /// decoration layout's `titleRow` (shrunk by the leading/trailing
    /// columns and the pill row), and a completed task draws at the
    /// theme-controlled 50% opacity with a strikethrough (F-TSK-1).
    private static func drawTitle(
        style: ResolvedNodeStyle, title: NodeTitle, decorations: NodeDecorations?,
        media: NodeMedia?, measurer: TextMeasurer, in context: CGContext, frame: CGRect
    ) {
        guard !title.text.isEmpty else { return }
        let titleRow = NodeDecorationLayout.layout(
            style: style, decorations: decorations,
            contentRect: contentRect(style: style, frame: frame)
        ).titleRow
        guard titleRow.width > 1, titleRow.height > 1 else { return }

        // F-CNT-5: a math node draws the rendered glyph; the source
        // text is the fallback (a parse error or a missing glyph).
        if decorations?.math == true, let glyph = media?.math {
            drawMathGlyph(glyph, in: titleRow, in: context)
            return
        }

        let textSize = measurer.nodeTitleSize(
            title, font: style.font, maxWidth: titleRow.width)
        guard textSize.width > 0, textSize.height > 0 else { return }
        // F-STY-2 text alignment: leading/trailing pin the measured text
        // block to its edge of the title row; center stays §7.5's
        // optical default.
        let slack = max(0, titleRow.width - textSize.width)
        let textOffsetX: CGFloat
        switch style.textAlignment {
        case .leading: textOffsetX = 0
        case .center: textOffsetX = slack / 2
        case .trailing: textOffsetX = slack
        }
        let textRect = CGRect(
            x: titleRow.minX + textOffsetX,
            y: titleRow.minY + max(0, (titleRow.height - textSize.height) / 2),
            width: titleRow.width,
            height: textSize.height + 2)

        let isDone = decorations?.task?.isDoneCheckbox ?? false
        let textColor =
            isDone
            ? style.textColor.copy(alpha: NodeDecorationMetrics.doneOpacity) ?? style.textColor
            : style.textColor
        let attributed = measurer.attributed(
            title, font: style.font, color: textColor, lineHeight: 1.25)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        context.saveGState()
        context.translateBy(x: textRect.minX, y: textRect.maxY)
        context.scaleBy(x: 1, y: -1)
        let localPath = CGPath(
            rect: CGRect(x: 0, y: 0, width: textRect.width, height: textRect.height),
            transform: nil)
        let textFrame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), localPath, nil)
        context.textMatrix = CGAffineTransform.identity
        CTFrameDraw(textFrame, context)
        if isDone {
            drawStrikethrough(textFrame: textFrame, in: context)
        }
        context.restoreGState()
    }

    /// The rect the title may occupy, in canvas coordinates. Shape-specific
    /// insets (keeping text out of circle and diamond corners) are a
    /// tracked follow-up for the canvas slice.
    public static func contentRect(style: ResolvedNodeStyle, frame: CGRect) -> CGRect {
        frame.insetBy(dx: style.paddingWidth, dy: style.paddingHeight)
    }

    /// The shape path for a node frame. `underline` returns an empty path:
    /// its visual is drawn as the stroke in `draw`, and children anchor at
    /// the underline's far end (§7.4).
    public static func shapePath(style: ResolvedNodeStyle, frame: CGRect) -> CGPath {
        switch style.shape {
        case .roundedRect:
            return CGPath(
                roundedRect: frame, cornerWidth: min(style.cornerRadius, frame.height / 2),
                cornerHeight: min(style.cornerRadius, frame.height / 2), transform: nil)
        case .rectangle:
            return CGPath(rect: frame, transform: nil)
        case .pill:
            return CGPath(
                roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2,
                transform: nil)
        case .circle:
            return CGPath(ellipseIn: frame, transform: nil)
        case .square:
            let side = min(frame.width, frame.height)
            let origin = CGPoint(
                x: frame.midX - side / 2, y: frame.midY - side / 2)
            return CGPath(rect: CGRect(origin: origin, size: CGSize(width: side, height: side)), transform: nil)
        case .diamond:
            return polygonPath(frame: frame, sides: 4, rotation: .pi / 2)
        case .hexagon:
            return polygonPath(frame: frame, sides: 6, rotation: .pi / 6)
        case .octagon:
            return polygonPath(frame: frame, sides: 8, rotation: .pi / 8)
        case .cloud:
            return cloudPath(frame: frame)
        case .underline, .none:
            return CGPath(rect: .zero, transform: nil)
        }
    }

    /// Where a child branch leaves this node (§7.4): the outer edge in
    /// `direction` — or, for underline shapes, the end of the line on that
    /// side.
    public static func outgoingAnchor(
        style: ResolvedNodeStyle, frame: CGRect, direction: BranchDirection
    ) -> CGPoint {
        if style.shape == .underline {
            let underlineOffset = style.underlineWidth / 2
            switch direction {
            case .right: return CGPoint(x: frame.maxX, y: frame.maxY - underlineOffset)
            case .left: return CGPoint(x: frame.minX, y: frame.maxY - underlineOffset)
            case .down: return CGPoint(x: frame.midX, y: frame.maxY)
            case .up: return CGPoint(x: frame.midX, y: frame.minY)
            }
        }
        switch direction {
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        case .down: return CGPoint(x: frame.midX, y: frame.maxY)
        case .up: return CGPoint(x: frame.midX, y: frame.minY)
        }
    }

    /// Where a branch arrives at this node: the near edge in `direction`
    /// — or, for underline shapes, the near end of the line.
    public static func incomingAnchor(
        style: ResolvedNodeStyle, frame: CGRect, direction: BranchDirection
    ) -> CGPoint {
        if style.shape == .underline {
            let underlineOffset = style.underlineWidth / 2
            switch direction {
            case .right: return CGPoint(x: frame.minX, y: frame.maxY - underlineOffset)
            case .left: return CGPoint(x: frame.maxX, y: frame.maxY - underlineOffset)
            case .down: return CGPoint(x: frame.midX, y: frame.minY)
            case .up: return CGPoint(x: frame.midX, y: frame.maxY)
            }
        }
        switch direction {
        case .right: return CGPoint(x: frame.minX, y: frame.midY)
        case .left: return CGPoint(x: frame.maxX, y: frame.midY)
        case .down: return CGPoint(x: frame.midX, y: frame.minY)
        case .up: return CGPoint(x: frame.midX, y: frame.maxY)
        }
    }

    /// A regular polygon inscribed in `frame`'s bounding ellipse, rotated
    /// so a flat edge faces the branch axis.
    private static func polygonPath(frame: CGRect, sides: Int, rotation: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radiusX = frame.width / 2
        let radiusY = frame.height / 2
        for index in 0...sides {
            let angle = rotation + CGFloat(index % sides) / CGFloat(sides) * 2 * .pi
            let point = CGPoint(
                x: center.x + cos(angle) * radiusX,
                y: center.y + sin(angle) * radiusY)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    /// The cloud outline (F-STY-1): a closed silhouette of six circular
    /// bumps — left, three on top (the middle one largest), right, a
    /// small shoulder at the bottom right — over a gently sagging
    /// bottom edge, all inscribed in `frame`. Bumps are true circular
    /// arcs (not circles unioned by winding), so a dashed border
    /// strokes one clean outline.
    private static func cloudPath(frame: CGRect) -> CGPath {
        let width = frame.width
        let height = frame.height
        // Bump anchor points around the silhouette, clockwise in the
        // flipped (y-down) convention, as frame fractions; `radius` is
        // each bump's arc radius as a height fraction.
        let anchors = [
            (x: 0.10, y: 0.82, radius: 0.26),  // bottom-left shoulder
            (x: 0.06, y: 0.46, radius: 0.34),  // left bump
            (x: 0.28, y: 0.13, radius: 0.30),  // top-left bump
            (x: 0.52, y: 0.02, radius: 0.46),  // top-mid bump (largest)
            (x: 0.78, y: 0.13, radius: 0.28),  // top-right bump
            (x: 0.96, y: 0.48, radius: 0.30),  // right bump
            (x: 0.88, y: 0.82, radius: 0.22),  // bottom-right shoulder
        ]
        let points = anchors.map { anchor in
            CGPoint(
                x: frame.minX + anchor.x * width,
                y: frame.minY + anchor.y * height)
        }

        let centroid = CGPoint(x: frame.midX, y: frame.midY)
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in 0..<points.count {
            let start = points[index]
            let end = points[(index + 1) % points.count]
            addBump(
                path, from: start, to: end,
                radius: anchors[index].radius * height, centroid: centroid)
        }
        // The sagging bottom edge back to the start.
        addBump(
            path, from: points[points.count - 1], to: points[0],
            radius: 0.9 * width, centroid: centroid)
        path.closeSubpath()
        return path
    }

    /// One circular-arc segment `from` → `to`, bulging away from
    /// `centroid` (the shape's interior). The center lands on the
    /// interior side of the chord, so the short-way sweep bows outward;
    /// degenerate chords (shorter than the diameter) fall back to a
    /// line.
    private static func addBump(
        _ path: CGMutablePath, from: CGPoint, to: CGPoint,
        radius: CGFloat, centroid: CGPoint
    ) {
        let chord = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let chordLength = hypot(chord.x, chord.y)
        guard chordLength > 0.0001 else { return }
        // Clamped so the half-chord always fits: r² = d² + (chord/2)².
        let radius = max(radius, chordLength * 0.51)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let offset = sqrt(max(0, radius * radius - (chordLength / 2) * (chordLength / 2)))
        let unit = CGPoint(x: -chord.y / chordLength, y: chord.x / chordLength)
        // Two candidate centers along the chord's perpendicular; the
        // interior one (nearest the centroid) leaves the bump bowing out.
        let candidateA = CGPoint(x: mid.x + unit.x * offset, y: mid.y + unit.y * offset)
        let candidateB = CGPoint(x: mid.x - unit.x * offset, y: mid.y - unit.y * offset)
        let distanceA = hypot(candidateA.x - centroid.x, candidateA.y - centroid.y)
        let distanceB = hypot(candidateB.x - centroid.x, candidateB.y - centroid.y)
        let center = distanceA < distanceB ? candidateA : candidateB

        let startAngle = atan2(from.y - center.y, from.x - center.x)
        var delta = atan2(to.y - center.y, to.x - center.x) - startAngle
        // Normalize to the short way (|delta| ≤ π): the small sag/bump
        // segments never want the long way around.
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        path.addArc(
            center: center, radius: radius,
            startAngle: startAngle, endAngle: startAngle + delta,
            clockwise: delta < 0)
    }
}
