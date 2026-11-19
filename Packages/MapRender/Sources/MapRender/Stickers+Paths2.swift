import CoreGraphics
import Foundation

/// The sticker catalog's path builders (F-CNT-3, the `Stickers`
/// extension): faces, the learning markers, hearts and weather.
/// Every path is authored in a 24×24 unit box, y growing down —
/// original Arbor artwork (nothing copied, AGENTS.md).
extension Stickers {
    static func brokenHeart() -> CGPath {
        let whole = heart()
        let combined = CGMutablePath()
        combined.addPath(whole)
        combined.addLines(
            between: [CGPoint(x: 12, y: 4), CGPoint(x: 9.5, y: 9), CGPoint(x: 13.5, y: 12.5), CGPoint(x: 11, y: 17)])
        return combined
    }

    static func sun() -> CGPath {
        let combined = CGMutablePath()
        combined.addEllipse(in: CGRect(x: 7.5, y: 7.5, width: 9, height: 9))
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            combined.move(to: CGPoint(x: 12 + cos(angle) * 6.4, y: 12 + sin(angle) * 6.4))
            combined.addLine(to: CGPoint(x: 12 + cos(angle) * 10.6, y: 12 + sin(angle) * 10.6))
        }
        return combined
    }

    static func moon() -> CGPath {
        build { path in
            path.addArc(
                center: CGPoint(x: 13.5, y: 12), radius: 8.5, startAngle: .pi * 0.25, endAngle: .pi * 1.75,
                clockwise: false)
            path.addArc(
                center: CGPoint(x: 8.5, y: 12), radius: 6.2, startAngle: .pi * 0.72, endAngle: .pi * 0.28,
                clockwise: true)
            path.closeSubpath()
        }
    }

    static func cloudBody() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 5, y: 17))
            path.addArc(
                center: CGPoint(x: 7.5, y: 14.5), radius: 3.4, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
            path.addArc(
                center: CGPoint(x: 8.6, y: 10), radius: 3.8, startAngle: .pi * 0.9, endAngle: .pi * 1.7,
                clockwise: false)
            path.addArc(
                center: CGPoint(x: 14.8, y: 8.6), radius: 4.4, startAngle: .pi * 1.55, endAngle: .pi * 0.45,
                clockwise: false)
            path.addArc(
                center: CGPoint(x: 17.8, y: 13.5), radius: 3.4, startAngle: .pi * 1.5, endAngle: .pi / 2,
                clockwise: false)
            path.closeSubpath()
        }
    }

    static func cloud() -> CGPath { cloudBody() }

    static func rainCloud() -> CGPath {
        let combined = CGMutablePath()
        combined.addPath(cloudBody())
        combined.addLines(between: [CGPoint(x: 8, y: 17.5), CGPoint(x: 6.5, y: 21.5)])
        combined.addLines(between: [CGPoint(x: 12.5, y: 17.5), CGPoint(x: 11, y: 21.5)])
        combined.addLines(between: [CGPoint(x: 17, y: 17.5), CGPoint(x: 15.5, y: 21.5)])
        return combined
    }

    static func snowCloud() -> CGPath {
        let combined = CGMutablePath()
        combined.addPath(cloudBody())
        for x in [8, 12, 16] {
            combined.addLines(
                between: [CGPoint(x: CGFloat(x) - 1.4, y: 19), CGPoint(x: CGFloat(x) + 1.4, y: 21.8)])
            combined.addLines(
                between: [CGPoint(x: CGFloat(x) + 1.4, y: 19), CGPoint(x: CGFloat(x) - 1.4, y: 21.8)])
            combined.addLines(
                between: [CGPoint(x: CGFloat(x) - 1.7, y: 20.4), CGPoint(x: CGFloat(x) + 1.7, y: 20.4)])
        }
        return combined
    }

    static func lightning() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 13.5, y: 2.5))
            path.addLine(to: CGPoint(x: 6.5, y: 13.5))
            path.addLine(to: CGPoint(x: 11, y: 13.5))
            path.addLine(to: CGPoint(x: 9.5, y: 21.5))
            path.addLine(to: CGPoint(x: 17.5, y: 9.5))
            path.addLine(to: CGPoint(x: 12.5, y: 9.5))
            path.closeSubpath()
        }
    }

    static func rainbow() -> CGPath {
        build { path in
            for radius in [9.5, 6.5, 3.5] {
                path.move(to: CGPoint(x: 12 - radius, y: 19))
                // The UPPER arc in the y-down convention.
                path.addArc(
                    center: CGPoint(x: 12, y: 19), radius: radius, startAngle: .pi, endAngle: 0, clockwise: false)
            }
        }
    }

    static func umbrella() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 2, y: 13))
            path.addQuadCurve(to: CGPoint(x: 12, y: 5), control: CGPoint(x: 6, y: 5))
            path.addQuadCurve(to: CGPoint(x: 22, y: 13), control: CGPoint(x: 18, y: 5))
            path.addQuadCurve(to: CGPoint(x: 17, y: 9), control: CGPoint(x: 18.5, y: 12))
            path.addQuadCurve(to: CGPoint(x: 12, y: 5), control: CGPoint(x: 15.5, y: 6.4))
            path.addQuadCurve(to: CGPoint(x: 7, y: 9), control: CGPoint(x: 8.5, y: 6.4))
            path.addQuadCurve(to: CGPoint(x: 2, y: 13), control: CGPoint(x: 5.5, y: 12))
            path.move(to: CGPoint(x: 12, y: 5))
            path.addLine(to: CGPoint(x: 12, y: 18))
            path.addArc(center: CGPoint(x: 10, y: 18), radius: 2, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        }
    }

    static func laptop() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 5, y: 6, width: 14, height: 9.5))
            path.addRect(CGRect(x: 2.5, y: 17.5, width: 19, height: 2))
        }
    }

    static func phone() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 7.5, y: 3, width: 9, height: 18), cornerWidth: 2.4, cornerHeight: 2.4)
            path.addRect(CGRect(x: 10.5, y: 18.2, width: 3, height: 1.2))
        }
    }

    static func wifi() -> CGPath {
        build { path in
            for radius: CGFloat in [4, 8, 12] {
                path.addArc(
                    center: CGPoint(x: 12, y: 21), radius: radius,
                    startAngle: .pi * 1.2, endAngle: .pi * 1.8, clockwise: false)
            }
            path.addEllipse(in: CGRect(x: 10.8, y: 19, width: 2.4, height: 2.4))
        }
    }

    static func battery() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 2.5, y: 8, width: 17, height: 8), cornerWidth: 1.6, cornerHeight: 1.6)
            path.addRect(CGRect(x: 20, y: 10.5, width: 2, height: 3))
            path.addRect(CGRect(x: 4.5, y: 10, width: 11, height: 4))
        }
    }

    static func camera() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 2.5, y: 7, width: 19, height: 13), cornerWidth: 2.2, cornerHeight: 2.2)
            path.addEllipse(in: CGRect(x: 8.5, y: 9.5, width: 8, height: 8))
            path.addRect(CGRect(x: 8.5, y: 4.5, width: 5, height: 2.5))
        }
    }

    static func gear() -> CGPath {
        build { path in
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                let tooth = CGMutablePath()
                tooth.addRect(
                    CGRect(
                        x: 12 + cos(angle) * 7 - 1.7, y: 12 + sin(angle) * 7 - 1.7,
                        width: 3.4, height: 3.4))
                path.addPath(tooth)
            }
            path.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            path.addEllipse(in: CGRect(x: 8.6, y: 8.6, width: 6.8, height: 6.8))
        }
    }

    static func plug() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 7, y: 2.5, width: 3, height: 5.5))
            path.addRect(CGRect(x: 14, y: 2.5, width: 3, height: 5.5))
            path.move(to: CGPoint(x: 7, y: 8))
            path.addLine(to: CGPoint(x: 7, y: 11.5))
            path.addQuadCurve(to: CGPoint(x: 12, y: 15), control: CGPoint(x: 7, y: 15))
            path.addQuadCurve(to: CGPoint(x: 17, y: 11.5), control: CGPoint(x: 17, y: 15))
            path.addLine(to: CGPoint(x: 17, y: 8))
            path.addLine(to: CGPoint(x: 7, y: 8))
            path.closeSubpath()
            path.move(to: CGPoint(x: 12, y: 15))
            path.addLine(to: CGPoint(x: 12, y: 21.5))
        }
    }

    static func codeGlyphs() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 8.5, y: 7))
            path.addLine(to: CGPoint(x: 3, y: 12))
            path.addLine(to: CGPoint(x: 8.5, y: 17))
            path.move(to: CGPoint(x: 15.5, y: 7))
            path.addLine(to: CGPoint(x: 21, y: 12))
            path.addLine(to: CGPoint(x: 15.5, y: 17))
        }
    }

    static func leaf() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 5, y: 20))
            path.addQuadCurve(to: CGPoint(x: 20, y: 4.5), control: CGPoint(x: 19.5, y: 19.5))
            path.addQuadCurve(to: CGPoint(x: 5, y: 20), control: CGPoint(x: 4.5, y: 5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 5, y: 20), CGPoint(x: 12, y: 12.5)])
        }
    }

    static func flower() -> CGPath {
        let combined = CGMutablePath()
        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3
            let petal = CGMutablePath()
            petal.addEllipse(
                in: CGRect(x: 12 + cos(angle) * 5 - 3, y: 10 + sin(angle) * 5 - 3, width: 6, height: 6))
            combined.addPath(petal)
        }
        combined.addEllipse(in: CGRect(x: 9.4, y: 7.4, width: 5.2, height: 5.2))
        combined.addLines(between: [CGPoint(x: 12, y: 15), CGPoint(x: 12, y: 21.5)])
        return combined
    }

    static func tree() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 5, y: 2.5, width: 14, height: 11))
            path.addRect(CGRect(x: 10.7, y: 13, width: 2.6, height: 9))
        }
    }

    static func drop() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 3))
            path.addCurve(
                to: CGPoint(x: 12, y: 13), control1: CGPoint(x: 18.5, y: 10), control2: CGPoint(x: 17.5, y: 17))
            path.addArc(
                center: CGPoint(x: 12, y: 15.5), radius: 6.2, startAngle: .pi * 0.65, endAngle: .pi * 0.35,
                clockwise: true)
            path.closeSubpath()
        }
    }

    static func fire() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 2.5))
            path.addCurve(
                to: CGPoint(x: 6, y: 9), control1: CGPoint(x: 16, y: 6), control2: CGPoint(x: 11, y: 6.5))
            path.addCurve(
                to: CGPoint(x: 8.5, y: 17), control1: CGPoint(x: 2.5, y: 12), control2: CGPoint(x: 5.5, y: 15.5))
            path.addArc(center: CGPoint(x: 12, y: 16), radius: 3.8, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addCurve(
                to: CGPoint(x: 12, y: 20.5), control1: CGPoint(x: 16.5, y: 18), control2: CGPoint(x: 15, y: 20.5))
            path.addCurve(
                to: CGPoint(x: 8, y: 14.5), control1: CGPoint(x: 6.5, y: 20.5), control2: CGPoint(x: 7, y: 17))
            path.addQuadCurve(to: CGPoint(x: 10.5, y: 9), control: CGPoint(x: 10, y: 13))
            path.addQuadCurve(to: CGPoint(x: 12, y: 2.5), control: CGPoint(x: 14, y: 6.5))
            path.closeSubpath()
        }
    }

    static func apple() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 3, y: 8, width: 18, height: 13.5))
            path.addLines(between: [CGPoint(x: 12, y: 8), CGPoint(x: 14, y: 3)])
            path.addQuadCurve(to: CGPoint(x: 10, y: 3.5), control: CGPoint(x: 12, y: 1.5))
            path.closeSubpath()
        }
    }
}
