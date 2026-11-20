import CoreGraphics
import Foundation
import MapRender

/// XML/SVG emission primitives: number formatting, entity escaping,
/// CSS color strings and a CGPath → SVG path-data converter.
enum SVGSupport {
    /// Compact decimal: up to two fraction digits, trailing zeros trimmed.
    static func number(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(format: "%.0f", rounded)
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Escapes text content: `&`, `<`, `>` (emoji and CJK pass through as
    /// UTF-8).
    static func escapeText(_ raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.utf8.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// Escapes an attribute value: text-content entities plus both quote
    /// kinds, so either delimiter stays legal.
    static func escapeAttribute(_ raw: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(raw.utf8.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// A CSS color for a CGColor: `#rrggbb` when opaque, `rgba(r,g,b,a)`
    /// when not (the Paper level-1 fills are palette colors at 16/24%).
    static func cssColor(_ color: CGColor) -> String {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil) ?? color
        guard let components = converted.components, components.count >= 3 else {
            return "#000000"
        }
        let red = clamp8bit(components[0])
        let green = clamp8bit(components[1])
        let blue = clamp8bit(components[2])
        let alpha = converted.alpha
        if alpha >= 0.999 {
            return String(format: "#%02x%02x%02x", red, green, blue)
        }
        let rgb = "rgba(\(red),\(green),\(blue)"
        return rgb + ",\(number(alpha)))"
    }

    private static func clamp8bit(_ value: CGFloat) -> Int {
        Int(min(255, max(0, (value * 255).rounded())))
    }

    /// SVG path data for any CGPath (CGPath stores appended arcs and
    /// quadratics as cubic Béziers, so four element kinds cover it).
    static func pathData(_ path: CGPath) -> String {
        var segments: [String] = []
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                segments.append("M\(number(points[0].x)) \(number(points[0].y))")
            case .addLineToPoint:
                segments.append("L\(number(points[0].x)) \(number(points[0].y))")
            case .addQuadCurveToPoint:
                segments.append("Q\(number(points[0].x)) \(number(points[0].y))")
                segments.append("\(number(points[1].x)) \(number(points[1].y))")
            case .addCurveToPoint:
                segments.append("C\(number(points[0].x)) \(number(points[0].y))")
                segments.append("\(number(points[1].x)) \(number(points[1].y))")
                segments.append("\(number(points[2].x)) \(number(points[2].y))")
            case .closeSubpath:
                segments.append("Z")
            @unknown default:
                break
            }
        }
        return segments.joined(separator: " ")
    }

    /// The SVG polygon `points` attribute for a regular polygon inscribed
    /// in `frame`'s bounding ellipse (the same construction
    /// `NodeRenderer.polygonPath` uses).
    static func polygonPoints(frame: CGRect, sides: Int, rotation: CGFloat) -> String {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radiusX = frame.width / 2
        let radiusY = frame.height / 2
        var points: [String] = []
        points.reserveCapacity(sides)
        for index in 0..<sides {
            let angle = rotation + CGFloat(index) / CGFloat(sides) * 2 * .pi
            points.append(
                "\(number(center.x + cos(angle) * radiusX)),\(number(center.y + sin(angle) * radiusY))")
        }
        return points.joined(separator: " ")
    }

    /// SVG font-weight for a Core Text weight constant (0 regular,
    /// 0.23 medium, 0.3 semibold, 0.4 bold).
    static func fontWeight(_ weight: CGFloat) -> String {
        switch weight {
        case ..<0.1: "400"
        case ..<0.27: "500"
        case ..<0.35: "600"
        default: "700"
        }
    }

    /// A CSS font-family stack for a FontSpec.
    static func fontFamily(_ font: FontSpec) -> String {
        if font.monospace {
            return "Menlo, monospace"
        }
        if font.family == FontSpec.roundedFamily {
            return "ui-rounded, 'SF Pro Rounded', -apple-system, BlinkMacSystemFont, sans-serif"
        }
        if let family = font.family, !family.isEmpty {
            return escapeAttribute(family)
        }
        return "-apple-system, BlinkMacSystemFont, sans-serif"
    }
}
