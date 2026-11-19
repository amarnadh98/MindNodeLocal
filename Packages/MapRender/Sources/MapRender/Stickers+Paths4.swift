import CoreGraphics
import Foundation

/// The sticker catalog's path builders (F-CNT-3, the `Stickers`
/// extension): symbols, people, milestones, documents, media and the decision marks.
/// Every path is authored in a 24×24 unit box, y growing down —
/// original Arbor artwork (nothing copied, AGENTS.md).
extension Stickers {
    static func person() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 8.6, y: 3, width: 6.8, height: 6.8))
            // Shoulders as a dome under the head.
            path.addEllipse(in: CGRect(x: 4.5, y: 11.5, width: 15, height: 10))
        }
    }

    static func people() -> CGPath {
        let combined = CGMutablePath()
        combined.addEllipse(in: CGRect(x: 3.6, y: 4.4, width: 5.6, height: 5.6))
        combined.addEllipse(in: CGRect(x: 1.5, y: 14, width: 10, height: 7))
        combined.addEllipse(in: CGRect(x: 14.8, y: 3, width: 6, height: 6))
        combined.addEllipse(in: CGRect(x: 13, y: 13, width: 9.5, height: 8))
        return combined
    }

    static func thumbs(_ up: Bool) -> CGPath {
        let thumb = CGMutablePath()
        thumb.addPath(
            build { path in
                path.addRect(CGRect(x: 3, y: 10.5, width: 7.5, height: 10))
            })
        thumb.addPath(
            build { path in
                path.move(to: CGPoint(x: 10.5, y: 10.5))
                path.addLines(
                    between: [
                        CGPoint(x: 10.5, y: 10.5), CGPoint(x: 13.5, y: 3.5), CGPoint(x: 16, y: 4.5),
                        CGPoint(x: 15, y: 10.5), CGPoint(x: 20, y: 10.5),
                    ])
                path.addQuadCurve(to: CGPoint(x: 20.5, y: 15.5), control: CGPoint(x: 22, y: 12.5))
                path.addQuadCurve(to: CGPoint(x: 18, y: 20.5), control: CGPoint(x: 21, y: 19))
                path.addLine(to: CGPoint(x: 10.5, y: 20.5))
                path.closeSubpath()
            })
        return up
            ? thumb
            : {
                var transform = CGAffineTransform(translationX: 12, y: 12).rotated(by: .pi)
                    .translatedBy(x: -12, y: -12)
                return thumb.copy(using: &transform) ?? thumb
            }()
    }

    static func trophy() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 8, y: 2.5, width: 8, height: 6))
            path.addLines(between: [CGPoint(x: 9, y: 8.5), CGPoint(x: 6, y: 11)])
            path.addArc(
                center: CGPoint(x: 6.4, y: 7), radius: 2.8, startAngle: .pi / 2, endAngle: 1.5 * .pi, clockwise: true)
            path.addLines(between: [CGPoint(x: 15, y: 8.5), CGPoint(x: 18, y: 11)])
            path.addArc(
                center: CGPoint(x: 17.6, y: 7), radius: 2.8, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
            path.addLines(between: [CGPoint(x: 11, y: 8.5), CGPoint(x: 11, y: 13)])
            path.addLines(between: [CGPoint(x: 13, y: 8.5), CGPoint(x: 13, y: 13)])
            path.addRect(CGRect(x: 7.5, y: 13, width: 9, height: 2.4))
            path.addRect(CGRect(x: 5.5, y: 15.4, width: 13, height: 2))
            path.addRect(CGRect(x: 4, y: 17.4, width: 16, height: 4))
        }
    }

    static func medal() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 8.5, y: 2.5), CGPoint(x: 12, y: 10)])
            path.addLines(between: [CGPoint(x: 15.5, y: 2.5), CGPoint(x: 12, y: 10)])
            path.addEllipse(in: CGRect(x: 6, y: 9.5, width: 12, height: 12))
            path.addEllipse(in: CGRect(x: 9, y: 12.5, width: 6, height: 6))
        }
    }

    static func ribbon() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 8, y: 3, width: 8, height: 8))
            path.addLines(
                between: [CGPoint(x: 9, y: 10.5), CGPoint(x: 5.5, y: 21.5), CGPoint(x: 12, y: 18)])
            path.addLines(
                between: [CGPoint(x: 15, y: 10.5), CGPoint(x: 18.5, y: 21.5), CGPoint(x: 12, y: 18)])
        }
    }

    static func finishFlag() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 2.5), CGPoint(x: 5, y: 21.5)])
            path.addRect(CGRect(x: 5, y: 4, width: 13, height: 9))
            path.addLines(between: [CGPoint(x: 9.7, y: 4), CGPoint(x: 9.7, y: 13)])
            path.addLines(between: [CGPoint(x: 13.3, y: 4), CGPoint(x: 13.3, y: 13)])
            path.addLines(between: [CGPoint(x: 5, y: 8.5), CGPoint(x: 18, y: 8.5)])
        }
    }

    static func document() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 5, y: 2.5))
            path.addLine(to: CGPoint(x: 15.5, y: 2.5))
            path.addLine(to: CGPoint(x: 19, y: 6.5))
            path.addLine(to: CGPoint(x: 19, y: 21.5))
            path.addLine(to: CGPoint(x: 5, y: 21.5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 15.5, y: 2.5), CGPoint(x: 15.5, y: 6.5)])
            path.addLines(between: [CGPoint(x: 15.5, y: 6.5), CGPoint(x: 19, y: 6.5)])
            path.addLines(between: [CGPoint(x: 8, y: 11), CGPoint(x: 16, y: 11)])
            path.addLines(between: [CGPoint(x: 8, y: 14.5), CGPoint(x: 16, y: 14.5)])
            path.addLines(between: [CGPoint(x: 8, y: 18), CGPoint(x: 13, y: 18)])
        }
    }

    static func folder() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 3, y: 6))
            path.addLine(to: CGPoint(x: 9.5, y: 6))
            path.addLine(to: CGPoint(x: 11.5, y: 8.5))
            path.addLine(to: CGPoint(x: 21, y: 8.5))
            path.addLine(to: CGPoint(x: 21, y: 19.5))
            path.addLine(to: CGPoint(x: 3, y: 19.5))
            path.closeSubpath()
        }
    }

    static func clipboard() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 4, y: 4.5, width: 16, height: 17), cornerWidth: 1.6, cornerHeight: 1.6)
            path.addRoundedRect(in: CGRect(x: 8.5, y: 2.5, width: 7, height: 4), cornerWidth: 1.4, cornerHeight: 1.4)
            path.addLines(between: [CGPoint(x: 7.5, y: 11), CGPoint(x: 16.5, y: 11)])
            path.addLines(between: [CGPoint(x: 7.5, y: 15), CGPoint(x: 16.5, y: 15)])
        }
    }

    static func noteSheet() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4.5, y: 3, width: 15, height: 18))
            path.addLines(between: [CGPoint(x: 7.5, y: 7.5), CGPoint(x: 16.5, y: 7.5)])
            path.addLines(between: [CGPoint(x: 7.5, y: 11), CGPoint(x: 16.5, y: 11)])
            path.addLines(between: [CGPoint(x: 7.5, y: 14.5), CGPoint(x: 13, y: 14.5)])
        }
    }

    static func archive() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3, y: 6, width: 18, height: 4.5))
            path.addRect(CGRect(x: 4.8, y: 10.5, width: 14.4, height: 10.5))
            path.addLines(between: [CGPoint(x: 9.5, y: 14.5), CGPoint(x: 14.5, y: 14.5)])
        }
    }

    static func musicNote() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 4.5, y: 15, width: 7, height: 5.5))
            path.addLines(between: [CGPoint(x: 11.5, y: 17.5), CGPoint(x: 11.5, y: 4)])
            path.addLine(to: CGPoint(x: 19.5, y: 6.5))
            path.addLine(to: CGPoint(x: 19.5, y: 9.5))
            path.addLine(to: CGPoint(x: 14, y: 8))
            path.addLine(to: CGPoint(x: 14, y: 19.5))
            path.addEllipse(in: CGRect(x: 11, y: 15, width: 7, height: 5.5))
        }
    }

    static func film() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3, y: 4.5, width: 18, height: 15))
            for index in 0..<3 {
                let y = CGFloat(6.6 + Double(index) * 5.2)
                path.addRect(CGRect(x: 4.2, y: y, width: 1.9, height: 3.2))
                path.addRect(CGRect(x: 17.9, y: y, width: 1.9, height: 3.2))
            }
        }
    }

    static func book() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 6.5))
            path.addQuadCurve(to: CGPoint(x: 4, y: 4.5), control: CGPoint(x: 8, y: 4.5))
            path.addLine(to: CGPoint(x: 4, y: 19))
            path.addQuadCurve(to: CGPoint(x: 12, y: 21), control: CGPoint(x: 8, y: 19))
            path.addQuadCurve(to: CGPoint(x: 20, y: 19), control: CGPoint(x: 16, y: 19))
            path.addLine(to: CGPoint(x: 20, y: 4.5))
            path.addQuadCurve(to: CGPoint(x: 12, y: 6.5), control: CGPoint(x: 16, y: 4.5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 12, y: 6.5), CGPoint(x: 12, y: 21)])
        }
    }

    static func pencil() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 17.5, y: 2.5))
            path.addLine(to: CGPoint(x: 21.5, y: 6.5))
            path.addLine(to: CGPoint(x: 7.5, y: 20.5))
            path.addLine(to: CGPoint(x: 2.5, y: 21.5))
            path.addLine(to: CGPoint(x: 3.5, y: 16.5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 15.5, y: 4.5), CGPoint(x: 19.5, y: 8.5)])
        }
    }

    static func scissors() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 12, y: 11), CGPoint(x: 20.5, y: 2.5)])
            path.addLines(between: [CGPoint(x: 12, y: 11), CGPoint(x: 20.5, y: 19.5)])
            path.addEllipse(in: CGRect(x: 5, y: 16.5, width: 5.4, height: 5.4))
            path.addEllipse(in: CGRect(x: 5, y: 2.6, width: 5.4, height: 5.4))
        }
    }

    static func quoteGlyph() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 4, y: 14, width: 4.4, height: 4.4))
            path.addRect(CGRect(x: 4, y: 5, width: 2.4, height: 10))
            path.addEllipse(in: CGRect(x: 13.6, y: 14, width: 4.4, height: 4.4))
            path.addRect(CGRect(x: 13.6, y: 5, width: 2.4, height: 10))
        }
    }

    static func checkPath() -> CGPath {
        build { path in
            path.addLines(
                between: [
                    CGPoint(x: 3.5, y: 12.5), CGPoint(x: 9, y: 18.5), CGPoint(x: 20.5, y: 5.5),
                ])
        }
    }

    static func crossPath() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 4.5, y: 4.5), CGPoint(x: 19.5, y: 19.5)])
            path.addLines(between: [CGPoint(x: 19.5, y: 4.5), CGPoint(x: 4.5, y: 19.5)])
        }
    }

    static func bangGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 12, y: 2.5), CGPoint(x: 13.6, y: 14.5)])
            path.addLine(to: CGPoint(x: 10.4, y: 14.5))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 10.4, y: 17.5, width: 3.2, height: 3.2))
        }
    }

    static func magnet() -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 7, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addRect(CGRect(x: 2.5, y: 12, width: 2.6, height: 5.5))
            path.addRect(CGRect(x: 18.9, y: 12, width: 2.6, height: 5.5))
            path.addRect(CGRect(x: 2.5, y: 12, width: 2.6, height: 2.2))
            path.addRect(CGRect(x: 18.9, y: 12, width: 2.6, height: 2.2))
        }
    }

    static func rosette() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 5.5, y: 3, width: 13, height: 13))
            path.addLines(
                between: [CGPoint(x: 8, y: 15.5), CGPoint(x: 6, y: 21.5), CGPoint(x: 12, y: 18.5)])
            path.addLines(
                between: [CGPoint(x: 16, y: 15.5), CGPoint(x: 18, y: 21.5), CGPoint(x: 12, y: 18.5)])
        }
    }
}
