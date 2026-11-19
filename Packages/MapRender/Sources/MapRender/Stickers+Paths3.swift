import CoreGraphics
import Foundation

/// The sticker catalog's path builders (F-CNT-3, the `Stickers`
/// extension): tech, nature, food, charts and time.
/// Every path is authored in a 24×24 unit box, y growing down —
/// original Arbor artwork (nothing copied, AGENTS.md).
extension Stickers {
    static func coffee() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4, y: 7, width: 12, height: 12))
            path.move(to: CGPoint(x: 16, y: 9))
            path.addQuadCurve(to: CGPoint(x: 21, y: 11), control: CGPoint(x: 21, y: 8.5))
            path.addQuadCurve(to: CGPoint(x: 16, y: 14), control: CGPoint(x: 21, y: 13.5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 3, y: 21), CGPoint(x: 17.5, y: 21)])
        }
    }

    static func cake() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3.5, y: 11, width: 17, height: 3.4))
            path.addRect(CGRect(x: 4.8, y: 15.5, width: 14.4, height: 3.6))
            path.addLines(between: [CGPoint(x: 6.5, y: 11), CGPoint(x: 6.5, y: 8)])
            path.addEllipse(in: CGRect(x: 5.8, y: 6, width: 1.6, height: 2))
            path.addLines(between: [CGPoint(x: 12, y: 11), CGPoint(x: 12, y: 7.5)])
            path.addEllipse(in: CGRect(x: 11.3, y: 5.4, width: 1.6, height: 2))
            path.addLines(between: [CGPoint(x: 17.5, y: 11), CGPoint(x: 17.5, y: 8)])
            path.addEllipse(in: CGRect(x: 16.8, y: 6, width: 1.6, height: 2))
        }
    }

    static func pizza() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 3, y: 18.5))
            path.addLine(to: CGPoint(x: 12, y: 4.5))
            path.addLine(to: CGPoint(x: 21, y: 18.5))
            path.addArc(center: CGPoint(x: 12, y: 18.5), radius: 9, startAngle: 0, endAngle: .pi, clockwise: true)
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 9.4, y: 13, width: 2.4, height: 2.4))
            path.addEllipse(in: CGRect(x: 13.6, y: 11, width: 2.2, height: 2.2))
            path.addEllipse(in: CGRect(x: 10.2, y: 9.8, width: 2, height: 2))
        }
    }

    static func carrot() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 21.5))
            path.addQuadCurve(to: CGPoint(x: 8.5, y: 9), control: CGPoint(x: 8, y: 16))
            path.addQuadCurve(to: CGPoint(x: 12, y: 6.5), control: CGPoint(x: 10, y: 7.5))
            path.addQuadCurve(to: CGPoint(x: 15.5, y: 9), control: CGPoint(x: 14, y: 7.5))
            path.addQuadCurve(to: CGPoint(x: 12, y: 21.5), control: CGPoint(x: 16, y: 16))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 12, y: 6.5), CGPoint(x: 9, y: 2.5)])
            path.addLines(between: [CGPoint(x: 12, y: 6.5), CGPoint(x: 13.5, y: 2.5)])
            path.addLines(between: [CGPoint(x: 12, y: 6.5), CGPoint(x: 15.5, y: 4)])
        }
    }

    static func iceCream() -> CGPath {
        build { path in
            path.addArc(
                center: CGPoint(x: 12, y: 9), radius: 6.4, startAngle: .pi * 1.05, endAngle: .pi * 1.95,
                clockwise: false)
            path.addLine(to: CGPoint(x: 4.5, y: 9.5))
            path.addLine(to: CGPoint(x: 12, y: 21))
            path.addLine(to: CGPoint(x: 19.5, y: 9.5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 4.5, y: 11.5), CGPoint(x: 19.5, y: 11.5)])
        }
    }

    static func barChart() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4, y: 12, width: 3.6, height: 9))
            path.addRect(CGRect(x: 10.2, y: 7, width: 3.6, height: 14))
            path.addRect(CGRect(x: 16.4, y: 3.5, width: 3.6, height: 17.5))
        }
    }

    static func pieChart() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 12))
            path.addArc(
                center: CGPoint(x: 12, y: 12), radius: 9, startAngle: -.pi / 2, endAngle: .pi * 0.7, clockwise: false)
            path.closeSubpath()
        }
    }

    static func lineChart() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 3, y: 18))
            path.addLine(to: CGPoint(x: 8, y: 12))
            path.addLine(to: CGPoint(x: 12.5, y: 15))
            path.addLine(to: CGPoint(x: 21, y: 5))
        }
    }

    static func trend(_ up: Bool) -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 3, y: up ? 18 : 6))
            path.addLine(to: CGPoint(x: 10, y: up ? 9 : 15))
            path.addLine(to: CGPoint(x: 14, y: up ? 12 : 12))
            path.addLine(to: CGPoint(x: 21, y: up ? 5 : 19))
            if up {
                path.addLines(between: [CGPoint(x: 16.5, y: 5), CGPoint(x: 21, y: 5), CGPoint(x: 21, y: 9.5)])
            } else {
                path.addLines(between: [CGPoint(x: 16.5, y: 19), CGPoint(x: 21, y: 19), CGPoint(x: 21, y: 14.5)])
            }
        }
    }

    static func percentGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 19.5), CGPoint(x: 19, y: 4.5)])
            path.addEllipse(in: CGRect(x: 3.4, y: 3.4, width: 5.6, height: 5.6))
            path.addEllipse(in: CGRect(x: 15, y: 15, width: 5.6, height: 5.6))
        }
    }

    static func clock() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            path.addLines(between: [CGPoint(x: 12, y: 7.5), CGPoint(x: 12, y: 12.5)])
            path.addLines(between: [CGPoint(x: 12, y: 12.5), CGPoint(x: 16, y: 15)])
        }
    }

    static func calendar() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3.5, y: 5, width: 17, height: 16))
            path.addRect(CGRect(x: 3.5, y: 5, width: 17, height: 4.5))
            path.addLines(between: [CGPoint(x: 7.5, y: 2.5), CGPoint(x: 7.5, y: 7)])
            path.addLines(between: [CGPoint(x: 16.5, y: 2.5), CGPoint(x: 16.5, y: 7)])
        }
    }

    static func bell() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 4, y: 17))
            path.addQuadCurve(to: CGPoint(x: 12, y: 5), control: CGPoint(x: 4, y: 5))
            path.addQuadCurve(to: CGPoint(x: 20, y: 17), control: CGPoint(x: 20, y: 5))
            path.addLine(to: CGPoint(x: 4, y: 17))
            path.closeSubpath()
            path.addArc(
                center: CGPoint(x: 12, y: 18.6), radius: 2.6, startAngle: .pi * 1.2, endAngle: .pi * 1.8,
                clockwise: false)
            path.addLines(between: [CGPoint(x: 9.8, y: 18.6), CGPoint(x: 14.2, y: 18.6)])
        }
    }

    static func hourglass() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 3), CGPoint(x: 19, y: 3)])
            path.addLine(to: CGPoint(x: 13.5, y: 10))
            path.addLine(to: CGPoint(x: 19, y: 21))
            path.addLine(to: CGPoint(x: 5, y: 21))
            path.addLine(to: CGPoint(x: 10.5, y: 10))
            path.closeSubpath()
        }
    }

    static func timer() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 4, y: 5.5, width: 16, height: 16))
            path.addLines(between: [CGPoint(x: 12, y: 10), CGPoint(x: 12, y: 13.5)])
            path.addLines(between: [CGPoint(x: 12, y: 13.5), CGPoint(x: 15, y: 15.5)])
            path.addRect(CGRect(x: 9.5, y: 2, width: 5, height: 2.2))
        }
    }

    static func alarm() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 3.5, y: 5.5, width: 17, height: 16))
            path.addLines(between: [CGPoint(x: 12, y: 10), CGPoint(x: 12, y: 14)])
            path.addLines(between: [CGPoint(x: 12, y: 14), CGPoint(x: 15.4, y: 16.4)])
            path.addLines(between: [CGPoint(x: 3, y: 7), CGPoint(x: 7.5, y: 3)])
            path.addLines(between: [CGPoint(x: 21, y: 7), CGPoint(x: 16.5, y: 3)])
        }
    }

    static func infinityLoop() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 6.5, y: 12))
            path.addCurve(to: CGPoint(x: 12, y: 7), control1: CGPoint(x: 1.5, y: 7), control2: CGPoint(x: 9, y: 7))
            path.addCurve(to: CGPoint(x: 17.5, y: 12), control1: CGPoint(x: 15, y: 7), control2: CGPoint(x: 22.5, y: 7))
            path.addCurve(to: CGPoint(x: 12, y: 17), control1: CGPoint(x: 22.5, y: 17), control2: CGPoint(x: 15, y: 17))
            path.addCurve(to: CGPoint(x: 6.5, y: 12), control1: CGPoint(x: 9, y: 17), control2: CGPoint(x: 1.5, y: 17))
        }
    }

    static func plusGlyph() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 10.5, y: 3.5, width: 3, height: 17))
            path.addRect(CGRect(x: 3.5, y: 10.5, width: 17, height: 3))
        }
    }

    static func minusGlyph() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3.5, y: 10.5, width: 17, height: 3))
        }
    }

    static func multiplyGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 5), CGPoint(x: 19, y: 19)])
            path.addLines(between: [CGPoint(x: 19, y: 5), CGPoint(x: 5, y: 19)])
        }
    }

    static func divideGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 4, y: 12), CGPoint(x: 20, y: 12)])
            path.addEllipse(in: CGRect(x: 10.6, y: 3.6, width: 2.8, height: 2.8))
            path.addEllipse(in: CGRect(x: 10.6, y: 17.6, width: 2.8, height: 2.8))
        }
    }

    static func equalGlyph() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4, y: 8, width: 16, height: 2.6))
            path.addRect(CGRect(x: 4, y: 13.4, width: 16, height: 2.6))
        }
    }

    static func sqrtGlyph() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 2.5, y: 13.5))
            path.addLine(to: CGPoint(x: 6.5, y: 13.5))
            path.addLine(to: CGPoint(x: 9, y: 5))
            path.addLine(to: CGPoint(x: 13, y: 19))
            path.addLine(to: CGPoint(x: 21.5, y: 19))
        }
    }

    static func piGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 4, y: 7), CGPoint(x: 20, y: 7)])
            path.addLines(between: [CGPoint(x: 8, y: 7), CGPoint(x: 8, y: 18)])
            path.addLines(between: [CGPoint(x: 16, y: 7), CGPoint(x: 16, y: 16)])
            path.addQuadCurve(to: CGPoint(x: 16, y: 18.5), control: CGPoint(x: 16, y: 20))
        }
    }
}
