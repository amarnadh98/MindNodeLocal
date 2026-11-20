import CoreGraphics
import CoreText
import Foundation
import MapCore

/// One connection prepared for drawing (F-REL-1): the stroke path plus
/// arrowheads, the label and its placement. All geometry lives in model
/// space (y down); the caller's context must be flipped, the same
/// convention `NodeRenderer` uses.
public struct ConnectionVisual {
    public let id: String
    /// The connection stroke (cubic or straight).
    public let path: CGPath
    /// Filled arrowheads, oriented along the curve tangents (`nil` per
    /// the arrowheads option).
    public let arrowStart: CGPath?
    public let arrowEnd: CGPath?
    /// Conservative drawing bounds (model space).
    public let bounds: CGRect
    public let color: CGColor
    public let lineWidth: CGFloat
    public let dash: Bool
    public let label: String?
    /// The label's center on the curve (the t = 0.5 point).
    public let labelCenter: CGPoint
    public let labelColor: CGColor
    public let labelFont: FontSpec
    /// When non-nil the connection renders with a selection halo in
    /// this color under its stroke (F-REL-1's selectability).
    public let selectionHalo: CGColor?

    public init(
        id: String,
        path: CGPath,
        arrowStart: CGPath?,
        arrowEnd: CGPath?,
        bounds: CGRect,
        color: CGColor,
        lineWidth: CGFloat,
        dash: Bool,
        label: String?,
        labelCenter: CGPoint,
        labelColor: CGColor,
        labelFont: FontSpec,
        selectionHalo: CGColor? = nil
    ) {
        self.id = id
        self.path = path
        self.arrowStart = arrowStart
        self.arrowEnd = arrowEnd
        self.bounds = bounds
        self.color = color
        self.lineWidth = lineWidth
        self.dash = dash
        self.label = label
        self.labelCenter = labelCenter
        self.labelColor = labelColor
        self.labelFont = labelFont
        self.selectionHalo = selectionHalo
    }
}

/// One boundary prepared for drawing (F-REL-2): the outline (rounded
/// or organic), the tinted fill and the optional title.
public struct BoundaryVisual {
    public let id: String
    public let outline: CGPath
    public let bounds: CGRect
    public let fillColor: CGColor
    public let strokeColor: CGColor
    public let lineWidth: CGFloat
    public let dash: Bool
    public let title: String?
    /// The title's center (the top-left "tab" of the outline).
    public let titleCenter: CGPoint
    public let titleColor: CGColor
    public let titleFont: FontSpec

    public init(
        id: String,
        outline: CGPath,
        bounds: CGRect,
        fillColor: CGColor,
        strokeColor: CGColor,
        lineWidth: CGFloat,
        dash: Bool,
        title: String?,
        titleCenter: CGPoint,
        titleColor: CGColor,
        titleFont: FontSpec
    ) {
        self.id = id
        self.outline = outline
        self.bounds = bounds
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.lineWidth = lineWidth
        self.dash = dash
        self.title = title
        self.titleCenter = titleCenter
        self.titleColor = titleColor
        self.titleFont = titleFont
    }
}

/// One summary brace prepared for drawing (F-REL-3).
public struct SummaryVisual {
    public let id: String
    public let brace: CGPath
    public let bounds: CGRect
    public let color: CGColor
    public let lineWidth: CGFloat

    public init(id: String, brace: CGPath, bounds: CGRect, color: CGColor, lineWidth: CGFloat) {
        self.id = id
        self.brace = brace
        self.bounds = bounds
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// Draws the cross-node relations (F-REL-1/2/3) into any flipped
/// `CGContext` — the one relation drawing path behind the canvas
/// overlay layers, `SceneRenderer` and every exporter (SPEC §11: "a
/// single NodeRenderer is shared by the canvas, export and Quick
/// Look"; relations follow the same rule).
public enum RelationRenderer {
    /// The connection line dash per §7.2 (4 on, 3 off).
    public static let dashPattern: [CGFloat] = [4, 3]
    /// The boundary title's type size.
    public static let boundaryTitleFont = FontSpec(size: 12, weight: 0.23)
    /// The connection label's type size.
    public static let connectionLabelFont = FontSpec(size: 12, weight: 0.0)

    /// Draws one connection: optional selection halo, the dashed or
    /// solid stroke, filled arrowheads, then the label on the curve.
    public static func draw(
        connection: ConnectionVisual, measurer: TextMeasurer, in context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: -connection.bounds.minX, y: -connection.bounds.minY)

        if let halo = connection.selectionHalo {
            context.setStrokeColor(halo)
            context.setLineWidth(connection.lineWidth + 2)
            context.setLineCap(.round)
            context.addPath(connection.path)
            context.strokePath()
        }

        context.setStrokeColor(connection.color)
        context.setFillColor(connection.color)
        context.setLineWidth(connection.lineWidth)
        context.setLineCap(.round)
        if connection.dash {
            context.setLineDash(phase: 0, lengths: dashPattern)
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
        context.addPath(connection.path)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        if let arrow = connection.arrowStart {
            context.addPath(arrow)
            context.fillPath()
        }
        if let arrow = connection.arrowEnd {
            context.addPath(arrow)
            context.fillPath()
        }

        if let label = connection.label, !label.isEmpty {
            let labelCenter = CGPoint(
                x: connection.labelCenter.x - connection.bounds.minX,
                y: connection.labelCenter.y - connection.bounds.minY)
            drawPlainText(
                label,
                center: labelCenter,
                font: connection.labelFont,
                color: connection.labelColor,
                measurer: measurer,
                in: context)
        }
        context.restoreGState()
    }

    /// Draws one boundary: the tinted fill, the dashed or solid stroke,
    /// then the optional title tab at the outline's top-left.
    public static func draw(
        boundary: BoundaryVisual, measurer: TextMeasurer, in context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: -boundary.bounds.minX, y: -boundary.bounds.minY)

        context.setFillColor(boundary.fillColor)
        context.addPath(boundary.outline)
        context.fillPath()

        context.setStrokeColor(boundary.strokeColor)
        context.setLineWidth(boundary.lineWidth)
        if boundary.dash {
            context.setLineDash(phase: 0, lengths: dashPattern)
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
        context.addPath(boundary.outline)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])

        if let title = boundary.title, !title.isEmpty {
            let titleCenter = CGPoint(
                x: boundary.titleCenter.x - boundary.bounds.minX,
                y: boundary.titleCenter.y - boundary.bounds.minY)
            drawPlainText(
                title,
                center: titleCenter,
                font: boundary.titleFont,
                color: boundary.titleColor,
                measurer: measurer,
                in: context)
        }
        context.restoreGState()
    }

    /// Draws one summary brace (F-REL-3): a solid rounded stroke in the
    /// theme's connection color.
    public static func draw(summary: SummaryVisual, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: -summary.bounds.minX, y: -summary.bounds.minY)
        context.setStrokeColor(summary.color)
        context.setFillColor(summary.color)
        context.setLineWidth(summary.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(summary.brace)
        context.strokePath()
        context.restoreGState()
    }

    /// Draws all overlays of a scene in z-order (boundaries under
    /// everything, braces over branches, connections on top) — the one
    /// call exporters make. Pure: it only draws what it is handed.
    public static func draw(
        boundaries: [BoundaryVisual], summaries: [SummaryVisual], connections: [ConnectionVisual],
        measurer: TextMeasurer, in context: CGContext
    ) {
        for boundary in boundaries {
            draw(boundary: boundary, measurer: measurer, in: context)
        }
        for summary in summaries {
            draw(summary: summary, in: context)
        }
        for connection in connections {
            draw(connection: connection, measurer: measurer, in: context)
        }
    }

    /// Plain single-line text centered on `center` — the label/title
    /// drawing shared with `NodeRenderer`'s Core Text convention
    /// (y-down context, glyphs upright).
    static func drawPlainText(
        _ text: String, center: CGPoint, font: FontSpec, color: CGColor,
        measurer: TextMeasurer, in context: CGContext
    ) {
        let title = NodeTitle(text: text)
        let size = measurer.nodeTitleSize(title, font: font, maxWidth: 400)
        guard size.width > 0, size.height > 0 else { return }
        let attributed = measurer.attributed(title, font: font, color: color, lineHeight: 1.25)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let textRect = CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width + 2, height: size.height + 2)
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
}
