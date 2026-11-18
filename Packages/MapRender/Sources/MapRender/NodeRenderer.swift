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
    public var cornerRadius: CGFloat
    public var paddingWidth: CGFloat
    public var paddingHeight: CGFloat
    public var textColor: CGColor
    public var font: FontSpec
    public var underlineWidth: CGFloat
    public var shadows: [ShadowLayer]
    public var maxWidth: CGFloat

    public init(
        shape: NodeShape,
        fillColor: CGColor?,
        borderColor: CGColor? = nil,
        borderWidth: CGFloat = 0,
        cornerRadius: CGFloat = 0,
        paddingWidth: CGFloat = 10,
        paddingHeight: CGFloat = 10,
        textColor: CGColor,
        font: FontSpec,
        underlineWidth: CGFloat = 0,
        shadows: [ShadowLayer] = [],
        maxWidth: CGFloat = 280
    ) {
        self.shape = shape
        self.fillColor = fillColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.paddingWidth = paddingWidth
        self.paddingHeight = paddingHeight
        self.textColor = textColor
        self.font = font
        self.underlineWidth = underlineWidth
        self.shadows = shadows
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
    /// the title optically centered (SPEC §7.5).
    public static func draw(
        style: ResolvedNodeStyle, title: NodeTitle, measurer: TextMeasurer,
        in context: CGContext, frame: CGRect
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
            context.addPath(shapePath(style: style, frame: frame))
            context.strokePath()
        }

        if let underlineColor = style.borderColor, style.shape == .underline {
            let underlineY = frame.maxY - style.underlineWidth / 2
            context.setStrokeColor(underlineColor)
            context.setLineWidth(style.underlineWidth)
            context.move(to: CGPoint(x: frame.minX, y: underlineY))
            context.addLine(to: CGPoint(x: frame.maxX, y: underlineY))
            context.strokePath()
        }

        drawTitle(style: style, title: title, measurer: measurer, in: context, frame: frame)
        context.restoreGState()
    }

    /// Text is optically centered in the padded content rect, laid out with
    /// the same framesetter constraints the measurer used, so a frame sized
    /// exactly to the measurement always fits its lines. `CTFrameDraw`
    /// renders y-up, so the context is flipped locally around the text
    /// rect to keep glyphs upright in the flipped convention.
    private static func drawTitle(
        style: ResolvedNodeStyle, title: NodeTitle, measurer: TextMeasurer,
        in context: CGContext, frame: CGRect
    ) {
        guard !title.text.isEmpty else { return }
        let contentRect = Self.contentRect(style: style, frame: frame)
        guard contentRect.width > 1, contentRect.height > 1 else { return }

        let textSize = measurer.nodeTitleSize(
            title, font: style.font, maxWidth: contentRect.width)
        guard textSize.width > 0, textSize.height > 0 else { return }
        let textRect = CGRect(
            x: contentRect.minX + max(0, (contentRect.width - textSize.width) / 2),
            y: contentRect.minY + max(0, (contentRect.height - textSize.height) / 2),
            width: contentRect.width,
            height: textSize.height + 2)

        let attributed = measurer.attributed(
            title, font: style.font, color: style.textColor, lineHeight: 1.25)
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
            return CGPath(ellipseIn: frame, transform: nil)
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
}
