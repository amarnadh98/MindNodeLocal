import CoreGraphics
import CoreText
import Foundation
import MapCore

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
    public var shadow: ShadowStyle
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
        shadow: ShadowStyle = .none,
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
        self.shadow = shadow
        self.maxWidth = maxWidth
    }
}

/// Draws nodes into any `CGContext` — the one renderer behind the canvas,
/// export and Quick Look (SPEC §11: a single `TextMeasurer` and
/// `NodeRenderer` is shared by all of them).
public enum NodeRenderer {
    /// Draws the node: shape (with optional shadow), border, then the title
    /// optically centered (SPEC §7.5).
    public static func draw(
        style: ResolvedNodeStyle, title: NodeTitle, measurer: TextMeasurer,
        in context: CGContext, frame: CGRect
    ) {
        context.saveGState()

        if let fillColor = style.fillColor {
            context.saveGState()
            if style.shadow != .none {
                let shadowGeometry = shadowParameters(style.shadow)
                context.setShadow(
                    offset: CGSize(width: 0, height: -shadowGeometry.offsetY),
                    blur: shadowGeometry.blur,
                    color: CGColor(gray: 0, alpha: shadowGeometry.alpha))
            }
            context.setFillColor(fillColor)
            context.addPath(shapePath(style: style, frame: frame))
            context.fillPath()
            context.restoreGState()
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

    /// Text is optically centered in the padded content rect; underline
    /// nodes sit on their line (§7.5), so they get one extra line of
    /// bottom room.
    private static func drawTitle(
        style: ResolvedNodeStyle, title: NodeTitle, measurer: TextMeasurer,
        in context: CGContext, frame: CGRect
    ) {
        guard !title.text.isEmpty else { return }
        let contentRect = contentRect(style: style, frame: frame)
        guard contentRect.width > 1, contentRect.height > 1 else { return }

        let attributed = measurer.attributed(
            title, font: style.font, color: style.textColor, lineHeight: 1.25)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textSize = measurer.nodeTitleSize(
            title, font: style.font, maxWidth: contentRect.width)
        let textOrigin = CGPoint(
            x: contentRect.minX + max(0, (contentRect.width - textSize.width) / 2),
            y: contentRect.minY + max(0, (contentRect.height - textSize.height) / 2))

        let textPath = CGPath(
            rect: CGRect(origin: textOrigin, size: CGSize(width: contentRect.width, height: contentRect.height + 4)),
            transform: nil)
        let textFrame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), textPath, nil)
        context.textPosition = textOrigin
        CTFrameDraw(textFrame, context)
    }

    /// The rect the title may occupy, in canvas coordinates.
    public static func contentRect(style: ResolvedNodeStyle, frame: CGRect) -> CGRect {
        let padX = style.paddingWidth
        let padY = style.paddingHeight
        return frame.insetBy(dx: padX, dy: padY)
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

    /// Where a child branch leaves this node (§7.4): the outer edge at the
    /// vertical center — or, for underline shapes, the end of the line.
    public static func branchAnchor(style: ResolvedNodeStyle, frame: CGRect) -> CGPoint {
        if style.shape == .underline {
            return CGPoint(x: frame.maxX, y: frame.maxY - style.underlineWidth / 2)
        }
        return CGPoint(x: frame.maxX, y: frame.midY)
    }

    private struct ShadowGeometry {
        let offsetY: CGFloat
        let blur: CGFloat
        let alpha: CGFloat
    }

    private static func shadowParameters(_ shadow: ShadowStyle) -> ShadowGeometry {
        switch shadow {
        case .none: ShadowGeometry(offsetY: 0, blur: 0, alpha: 0)
        case .soft: ShadowGeometry(offsetY: 1, blur: 3, alpha: 0.08)
        case .raised: ShadowGeometry(offsetY: 4, blur: 12, alpha: 0.06)
        }
    }
}
