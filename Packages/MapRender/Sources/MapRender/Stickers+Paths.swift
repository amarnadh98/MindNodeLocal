import CoreGraphics
import Foundation

/// The sticker catalog's path builders (F-CNT-3, the `Stickers`
/// extension): the families the picker leads with
/// (priorities, progress, flags, stars, arrows) plus the tiny `build`
/// helper every path composes through
/// Every path is authored in a 24×24 unit box, y growing down —
/// original Arbor artwork (nothing copied, AGENTS.md).
extension Stickers {
    static func build(_ body: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        body(path)
        return path
    }

    static func star(_ points: Int, innerRatio: CGFloat, radius: CGFloat = 10) -> CGPath {
        build { path in
            let center = CGPoint(x: 12, y: 12.5)
            for index in 0..<(points * 2) {
                let angle = CGFloat(index) * .pi / CGFloat(points) - .pi / 2
                let distance = index % 2 == 0 ? radius : radius * innerRatio
                let vertex = CGPoint(
                    x: center.x + cos(angle) * distance,
                    y: center.y + sin(angle) * distance)
                if index == 0 {
                    path.move(to: vertex)
                } else {
                    path.addLine(to: vertex)
                }
            }
            path.closeSubpath()
        }
    }

    /// A single 4-point sparkle centered at `center`.
    static func sparkle(at center: (CGFloat, CGFloat), radius: CGFloat) -> CGPath {
        build { path in
            let (cx, cy) = center
            let inner = radius * 0.28
            path.move(to: CGPoint(x: cx, y: cy - radius))
            path.addCurve(
                to: CGPoint(x: cx + radius, y: cy),
                control1: CGPoint(x: cx + inner, y: cy - inner),
                control2: CGPoint(x: cx + radius - inner, y: cy - inner))
            path.addCurve(
                to: CGPoint(x: cx, y: cy + radius),
                control1: CGPoint(x: cx + radius - inner, y: cy + inner),
                control2: CGPoint(x: cx + inner, y: cy + inner))
            path.addCurve(
                to: CGPoint(x: cx - radius, y: cy),
                control1: CGPoint(x: cx - inner, y: cy + inner),
                control2: CGPoint(x: cx - radius + inner, y: cy + inner))
            path.addCurve(
                to: CGPoint(x: cx, y: cy - radius),
                control1: CGPoint(x: cx - radius + inner, y: cy - inner),
                control2: CGPoint(x: cx - inner, y: cy - inner))
            path.closeSubpath()
        }
    }

    static func sparkle(_ radius: CGFloat) -> CGPath {
        sparkle(at: (12, 12.5), radius: 10)
    }

    static func sparkles() -> CGPath {
        let combined = CGMutablePath()
        combined.addPath(sparkle(at: (9, 9), radius: 7))
        combined.addPath(sparkle(at: (17, 16), radius: 4))
        return combined
    }

    static func priorityBars(_ count: Int) -> CGPath {
        build { path in
            for index in 0..<count {
                let height = CGFloat(4 + index * 4)
                let rect = CGRect(x: CGFloat(3 + index * 4), y: 21 - height, width: 3, height: height)
                path.addRect(rect)
            }
        }
    }

    static func progressRing(_ fraction: CGFloat) -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 8.6, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            guard fraction > 0 else { return }
            let pie = CGMutablePath()
            pie.move(to: CGPoint(x: 12, y: 12))
            pie.addArc(
                center: CGPoint(x: 12, y: 12), radius: 6.4,
                startAngle: -.pi / 2, endAngle: -.pi / 2 + fraction * 2 * .pi, clockwise: false)
            pie.closeSubpath()
            path.addPath(pie)
        }
    }

    static func flagPath() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 6, y: 21))
            path.addLine(to: CGPoint(x: 6, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 9.5))
            path.closeSubpath()
        }
    }

    static func arrow(_ rotation: CGFloat) -> CGPath {
        // A right-pointing arrow in the unit box, rotated about center.
        let base = build { path in
            path.move(to: CGPoint(x: 3, y: 9))
            path.addLine(to: CGPoint(x: 13, y: 9))
            path.addLine(to: CGPoint(x: 13, y: 5.5))
            path.addLine(to: CGPoint(x: 21, y: 12))
            path.addLine(to: CGPoint(x: 13, y: 18.5))
            path.addLine(to: CGPoint(x: 13, y: 15))
            path.addLine(to: CGPoint(x: 3, y: 15))
            path.closeSubpath()
        }
        var transform = CGAffineTransform(translationX: 12, y: 12)
            .rotated(by: rotation).translatedBy(x: -12, y: -12)
        return base.copy(using: &transform) ?? base
    }

    static func mirrored(_ path: CGPath) -> CGPath {
        var transform = CGAffineTransform(translationX: 12, y: 0).scaledBy(x: -1, y: 1)
            .translatedBy(x: -12, y: 0)
        return path.copy(using: &transform) ?? path
    }

    static func doubleArrow() -> CGPath {
        let combined = CGMutablePath()
        combined.addPath(arrow(0))
        combined.addPath(
            build { path in
                path.move(to: CGPoint(x: 2, y: 12))
                path.addLine(to: CGPoint(x: 8, y: 9))
                path.addLine(to: CGPoint(x: 8, y: 15))
                path.closeSubpath()
            })
        return combined
    }

    static func bendArrow() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 4, y: 20))
            path.addQuadCurve(to: CGPoint(x: 4, y: 6), control: CGPoint(x: 4, y: 12))
            path.addQuadCurve(to: CGPoint(x: 13, y: 5), control: CGPoint(x: 9, y: 5))
            path.addLine(to: CGPoint(x: 13, y: 1.5))
            path.addLine(to: CGPoint(x: 21, y: 7.5))
            path.addLine(to: CGPoint(x: 13, y: 13))
            path.addLine(to: CGPoint(x: 13, y: 9))
            path.addQuadCurve(to: CGPoint(x: 8, y: 10), control: CGPoint(x: 10, y: 9))
            path.addQuadCurve(to: CGPoint(x: 8, y: 20), control: CGPoint(x: 8, y: 14))
            path.closeSubpath()
        }
    }

    static func curveArrow() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 3, y: 16))
            path.addQuadCurve(to: CGPoint(x: 14, y: 8), control: CGPoint(x: 9, y: 17))
            path.addLine(to: CGPoint(x: 14, y: 4.5))
            path.addLine(to: CGPoint(x: 21, y: 10.5))
            path.addLine(to: CGPoint(x: 14, y: 16.5))
            path.addLine(to: CGPoint(x: 14, y: 12.5))
            path.addQuadCurve(to: CGPoint(x: 7, y: 17), control: CGPoint(x: 10, y: 13))
            path.closeSubpath()
        }
    }

    static func returnArrow() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 4, y: 8))
            path.addLine(to: CGPoint(x: 17, y: 8))
            path.addQuadCurve(to: CGPoint(x: 20, y: 14), control: CGPoint(x: 20, y: 8))
            path.addLine(to: CGPoint(x: 20, y: 21))
            path.addLine(to: CGPoint(x: 16.5, y: 21))
            path.addLine(to: CGPoint(x: 16.5, y: 14.5))
            path.addQuadCurve(to: CGPoint(x: 14, y: 12), control: CGPoint(x: 17, y: 12))
            path.addLine(to: CGPoint(x: 4, y: 12))
            path.addLine(to: CGPoint(x: 7.5, y: 8.5))
            path.closeSubpath()
        }
    }

    enum Face {
        case happy, grin, wink, sad, crying, angry, surprised, neutral
    }

    static func face(_ kind: Face) -> CGPath {
        let combined = CGMutablePath()
        // The head.
        combined.addEllipse(in: CGRect(x: 3, y: 4, width: 18, height: 18))
        // Eyes (wink closes one; angry adds brows).
        switch kind {
        case .wink:
            combined.addRect(CGRect(x: 6.5, y: 10, width: 3.4, height: 1.8))
            combined.addEllipse(in: CGRect(x: 14.2, y: 9.4, width: 2.6, height: 3.4))
        case .angry:
            combined.addEllipse(in: CGRect(x: 7, y: 11, width: 2.6, height: 2.6))
            combined.addEllipse(in: CGRect(x: 14.4, y: 11, width: 2.6, height: 2.6))
            combined.addLines(
                between: [CGPoint(x: 6, y: 8), CGPoint(x: 10.4, y: 10)])
            combined.addLines(
                between: [CGPoint(x: 18, y: 8), CGPoint(x: 13.6, y: 10)])
        default:
            combined.addEllipse(in: CGRect(x: 7.2, y: 9.6, width: 2.6, height: 3.4))
            combined.addEllipse(in: CGRect(x: 14.2, y: 9.6, width: 2.6, height: 3.4))
        }
        // The mouth.
        switch kind {
        case .happy, .grin:
            let mouth = CGMutablePath()
            mouth.addArc(
                center: CGPoint(x: 12, y: 12), radius: 5.4, startAngle: 0.35, endAngle: .pi - 0.35,
                clockwise: true)
            combined.addPath(mouth)
        case .sad, .crying:
            let mouth = CGMutablePath()
            mouth.addArc(
                center: CGPoint(x: 12, y: 18.2), radius: 4.4, startAngle: .pi + 0.4, endAngle: 2 * .pi - 0.4,
                clockwise: true)
            combined.addPath(mouth)
            if kind == .crying {
                combined.addEllipse(in: CGRect(x: 7.4, y: 14.5, width: 1.8, height: 4.5))
                combined.addEllipse(in: CGRect(x: 14.8, y: 14.5, width: 1.8, height: 4.5))
            }
        case .surprised:
            combined.addEllipse(in: CGRect(x: 10.2, y: 14.4, width: 3.6, height: 4.2))
        case .neutral:
            combined.addRect(CGRect(x: 8.6, y: 16, width: 6.8, height: 1.8))
        case .wink, .angry:
            combined.addRect(CGRect(x: 8.8, y: 16.2, width: 6.4, height: 1.8))
        }
        return combined
    }

    static func lightbulb() -> CGPath {
        build { path in
            path.addArc(
                center: CGPoint(x: 12, y: 9.6), radius: 6, startAngle: .pi * 0.15, endAngle: .pi * 0.85,
                clockwise: false)
            path.addLine(to: CGPoint(x: 15.5, y: 16.5))
            path.addLine(to: CGPoint(x: 8.5, y: 16.5))
            path.closeSubpath()
            path.addRect(CGRect(x: 8.6, y: 18, width: 6.8, height: 1.6))
            path.addRect(CGRect(x: 8.6, y: 21, width: 6.8, height: 1.6))
            for index in 0..<3 {
                let angle = CGFloat(index - 1) * 0.5
                path.move(to: CGPoint(x: 12 + cos(angle - .pi / 2) * 8.4, y: 9.6 + sin(angle - .pi / 2) * 8.4))
                path.addLine(to: CGPoint(x: 12 + cos(angle - .pi / 2) * 10.6, y: 9.6 + sin(angle - .pi / 2) * 10.6))
            }
        }
    }

    static func questionMark() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 7.5, y: 8))
            path.addQuadCurve(to: CGPoint(x: 12, y: 4.5), control: CGPoint(x: 7.5, y: 4.5))
            path.addQuadCurve(to: CGPoint(x: 16.5, y: 8), control: CGPoint(x: 16.5, y: 4.5))
            path.addQuadCurve(to: CGPoint(x: 13.4, y: 11.6), control: CGPoint(x: 16.5, y: 10.8))
            path.addLine(to: CGPoint(x: 13.4, y: 14.5))
            path.addLine(to: CGPoint(x: 10.6, y: 14.5))
            path.addLine(to: CGPoint(x: 10.6, y: 11))
            path.addQuadCurve(to: CGPoint(x: 12, y: 9.4), control: CGPoint(x: 10.6, y: 9))
            path.addQuadCurve(to: CGPoint(x: 13.7, y: 8), control: CGPoint(x: 14.8, y: 9.4))
            path.addQuadCurve(to: CGPoint(x: 12, y: 6.9), control: CGPoint(x: 13.7, y: 6.6))
            path.addQuadCurve(to: CGPoint(x: 10.3, y: 8), control: CGPoint(x: 10.3, y: 6.6))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 10.4, y: 17.5, width: 3.2, height: 3.2))
        }
    }

    static func warningTriangle() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 3.5))
            path.addLine(to: CGPoint(x: 21.5, y: 20.5))
            path.addLine(to: CGPoint(x: 2.5, y: 20.5))
            path.closeSubpath()
            path.addLines(
                between: [CGPoint(x: 12, y: 9.5), CGPoint(x: 12, y: 15)])
            path.addEllipse(in: CGRect(x: 10.9, y: 16.6, width: 2.2, height: 2.2))
        }
    }

    static func keyPath() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 2.5, y: 3, width: 9, height: 9))
            path.addRect(CGRect(x: 10.5, y: 6.6, width: 11, height: 1.8))
            path.addRect(CGRect(x: 17, y: 8.4, width: 1.8, height: 3.4))
            path.addRect(CGRect(x: 13.5, y: 8.4, width: 1.8, height: 3.4))
        }
    }

    static func pinPath() -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 9.5), radius: 6.2, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.move(to: CGPoint(x: 12, y: 15.7))
            path.addLine(to: CGPoint(x: 12, y: 21.5))
        }
    }

    static func reviewLoop() -> CGPath {
        // Two circular arrows — the "review again" loop.
        build { path in
            path.addArc(
                center: CGPoint(x: 12, y: 12), radius: 7, startAngle: -.pi / 2, endAngle: .pi * 0.75, clockwise: false)
            path.addLines(
                between: [
                    CGPoint(x: 12, y: 1.6), CGPoint(x: 15.4, y: 5.6), CGPoint(x: 8.6, y: 5.6),
                ])
            path.closeSubpath()
        }
    }

    static func bookmarkPath() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 6, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 21))
            path.addLine(to: CGPoint(x: 12, y: 15.5))
            path.addLine(to: CGPoint(x: 6, y: 21))
            path.closeSubpath()
        }
    }

    static func targetPath() -> CGPath {
        let combined = CGMutablePath()
        for radius in [8.5, 4.6] {
            let ring = CGMutablePath()
            ring.addArc(
                center: CGPoint(x: 12, y: 12), radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            combined.addPath(ring)
        }
        combined.addEllipse(in: CGRect(x: 10.6, y: 10.6, width: 2.8, height: 2.8))
        return combined
    }

    static func heart() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 21))
            path.addCurve(
                to: CGPoint(x: 2.5, y: 9), control1: CGPoint(x: 4.5, y: 16), control2: CGPoint(x: 2.5, y: 13))
            path.addArc(center: CGPoint(x: 7.2, y: 8.8), radius: 4.7, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addArc(center: CGPoint(x: 16.8, y: 8.8), radius: 4.7, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addCurve(
                to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 21.5, y: 13), control2: CGPoint(x: 19.5, y: 16))
            path.closeSubpath()
        }
    }
}
