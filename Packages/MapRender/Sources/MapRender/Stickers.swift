import CoreGraphics
import Foundation

/// One of Arbor's original vector stickers (F-CNT-3): authored here as
/// code — every path drawn in a 24×24 unit box, y growing down, the same
/// convention the node renderer paints in. No third-party artwork: these
/// are Arbor's own glyphs (MindNode assets are never copied, AGENTS.md).
///
/// `mode` picks how the renderer paints the path: filled with the
/// theme's decoration color, stroked (a `lineWidth` in unit-box
/// coordinates), or both. Stickers render at any size by scaling the
/// unit box.
///
/// `@unchecked Sendable`: the stored `CGPath` is an immutable
/// CF value that is only ever read after the catalog is built (the
/// SDK does not yet annotate it).
public struct Sticker: @unchecked Sendable {
    public enum Mode: Sendable {
        case fill
        case stroke
        case fillStroke
    }

    public let id: String
    public let category: String
    /// The path in a 24×24 unit box (y-down).
    public let path: CGPath
    public let mode: Mode
    /// Stroke width in unit-box coordinates (mode `.stroke`/`.fillStroke`).
    public let lineWidth: CGFloat

    init(
        id: String, category: String, path: CGPath, mode: Sticker.Mode = .fill,
        lineWidth: CGFloat = 1.8
    ) {
        self.id = id
        self.category = category
        self.path = path
        self.mode = mode
        self.lineWidth = lineWidth
    }
}

/// The Arbor sticker set (~120 originals, F-CNT-3): arrows, priority
/// 1–5, progress eighths, flags, stars, faces, check/x/question, the
/// learning markers SPEC §5.4 names (idea, question, pitfall, key,
/// review) and the everyday set MindNode users reach for — authored
/// from scratch as compact vector paths.
public enum Stickers {
    /// The full catalog, id-stable (SPEC §8.2's `sticker:<id>` tokens
    /// reference these forever).
    public static let all: [Sticker] = build()

    /// Category display order (the picker's sections).
    public static let categoryOrder: [String] = [
        "Priority", "Progress", "Flags", "Stars", "Arrows", "Faces", "Learning",
        "Hearts", "Weather", "Tech", "Nature", "Food", "Charts", "Time",
        "Symbols", "People", "Milestone", "Documents", "Media", "Misc",
    ]

    public static func sticker(id: String) -> Sticker? {
        all.first { $0.id == id }
    }

    // MARK: build

    private static func build() -> [Sticker] {
        var stickers: [Sticker] = []

        // Priority 1–5: a filled stack of bars.
        for count in 1...5 {
            stickers.append(
                Sticker(id: "priority-\(count)", category: "Priority", path: priorityBars(count)))
        }

        // Progress 0–8: a ring filled to n/8 from 12 o'clock.
        for eighth in 0...8 {
            stickers.append(
                Sticker(
                    id: "progress-\(eighth)", category: "Progress",
                    path: progressRing(CGFloat(eighth) / 8), mode: .fillStroke, lineWidth: 1.8))
        }

        // Flags: one outline-plus-banner path; the color comes from the
        // sticker id (the picker previews them tinted per id).
        let flagHues = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "gray"]
        for hue in flagHues {
            stickers.append(Sticker(id: "flag-\(hue)", category: "Flags", path: flagPath()))
        }

        // Stars.
        stickers.append(contentsOf: [
            Sticker(id: "star-full", category: "Stars", path: star(12, innerRatio: 0.42)),
            Sticker(id: "star-half", category: "Stars", path: star(12, innerRatio: 0.42), mode: .fillStroke),
            Sticker(id: "star-empty", category: "Stars", path: star(12, innerRatio: 0.42), mode: .stroke),
            Sticker(id: "star-small", category: "Stars", path: star(12, innerRatio: 0.42)),
            Sticker(id: "sparkle", category: "Stars", path: sparkle(12)),
            Sticker(id: "sparkles", category: "Stars", path: sparkles()),
            Sticker(id: "starburst", category: "Stars", path: star(16, innerRatio: 0.82)),
            Sticker(id: "badge-award", category: "Stars", path: rosette()),
        ])

        // Arrows.
        stickers.append(contentsOf: [
            Sticker(id: "arrow-right", category: "Arrows", path: arrow(0), mode: .fill),
            Sticker(id: "arrow-left", category: "Arrows", path: arrow(.pi), mode: .fill),
            Sticker(id: "arrow-up", category: "Arrows", path: arrow(-.pi / 2), mode: .fill),
            Sticker(id: "arrow-down", category: "Arrows", path: arrow(.pi / 2), mode: .fill),
            Sticker(id: "arrow-double-right", category: "Arrows", path: doubleArrow()),
            Sticker(id: "arrow-double-left", category: "Arrows", path: mirrored(doubleArrow())),
            Sticker(id: "arrow-bend-up-right", category: "Arrows", path: bendArrow()),
            Sticker(id: "arrow-bend-up-left", category: "Arrows", path: mirrored(bendArrow())),
            Sticker(id: "arrow-curve-right", category: "Arrows", path: curveArrow()),
            Sticker(id: "arrow-return", category: "Arrows", path: returnArrow()),
        ])

        // Faces: a circle head plus features.
        stickers.append(contentsOf: [
            Sticker(id: "face-happy", category: "Faces", path: face(.happy), mode: .fillStroke),
            Sticker(id: "face-grin", category: "Faces", path: face(.grin), mode: .fillStroke),
            Sticker(id: "face-wink", category: "Faces", path: face(.wink), mode: .fillStroke),
            Sticker(id: "face-sad", category: "Faces", path: face(.sad), mode: .fillStroke),
            Sticker(id: "face-crying", category: "Faces", path: face(.crying), mode: .fillStroke),
            Sticker(id: "face-angry", category: "Faces", path: face(.angry), mode: .fillStroke),
            Sticker(id: "face-surprised", category: "Faces", path: face(.surprised), mode: .fillStroke),
            Sticker(id: "face-neutral", category: "Faces", path: face(.neutral), mode: .fillStroke),
        ])

        // The learning markers SPEC names, plus study-adjacent ones.
        stickers.append(contentsOf: [
            Sticker(id: "idea", category: "Learning", path: lightbulb(), mode: .fillStroke),
            Sticker(id: "question", category: "Learning", path: questionMark(), mode: .fillStroke),
            Sticker(id: "pitfall", category: "Learning", path: warningTriangle(), mode: .fillStroke),
            Sticker(id: "key", category: "Learning", path: keyPath(), mode: .fillStroke),
            Sticker(id: "pin", category: "Learning", path: pinPath(), mode: .fillStroke),
            Sticker(id: "review", category: "Learning", path: reviewLoop(), mode: .fillStroke),
            Sticker(id: "bookmark", category: "Learning", path: bookmarkPath(), mode: .fillStroke),
            Sticker(id: "target", category: "Learning", path: targetPath(), mode: .fillStroke),
        ])

        // Hearts.
        stickers.append(contentsOf: [
            Sticker(id: "heart-full", category: "Hearts", path: heart()),
            Sticker(id: "heart-half", category: "Hearts", path: heart(), mode: .fillStroke),
            Sticker(id: "heart-empty", category: "Hearts", path: heart(), mode: .stroke),
            Sticker(id: "heart-broken", category: "Hearts", path: brokenHeart(), mode: .fillStroke),
        ])

        // Weather.
        stickers.append(contentsOf: [
            Sticker(id: "sun", category: "Weather", path: sun(), mode: .fillStroke),
            Sticker(id: "moon", category: "Weather", path: moon()),
            Sticker(id: "cloud", category: "Weather", path: cloud(), mode: .fillStroke),
            Sticker(id: "rain", category: "Weather", path: rainCloud(), mode: .fillStroke),
            Sticker(id: "snow", category: "Weather", path: snowCloud(), mode: .fillStroke),
            Sticker(id: "lightning", category: "Weather", path: lightning(), mode: .fillStroke),
            Sticker(id: "rainbow", category: "Weather", path: rainbow(), mode: .stroke),
            Sticker(id: "umbrella", category: "Weather", path: umbrella(), mode: .fillStroke),
        ])

        // Tech.
        stickers.append(contentsOf: [
            Sticker(id: "laptop", category: "Tech", path: laptop(), mode: .fillStroke),
            Sticker(id: "phone", category: "Tech", path: phone(), mode: .fillStroke),
            Sticker(id: "wifi", category: "Tech", path: wifi(), mode: .stroke),
            Sticker(id: "battery", category: "Tech", path: battery(), mode: .fillStroke),
            Sticker(id: "camera", category: "Tech", path: camera(), mode: .fillStroke),
            Sticker(id: "gear", category: "Tech", path: gear(), mode: .fillStroke),
            Sticker(id: "plug", category: "Tech", path: plug(), mode: .fillStroke),
            Sticker(id: "code", category: "Tech", path: codeGlyphs(), mode: .stroke),
        ])

        // Nature.
        stickers.append(contentsOf: [
            Sticker(id: "leaf", category: "Nature", path: leaf(), mode: .fillStroke),
            Sticker(id: "flower", category: "Nature", path: flower(), mode: .fillStroke),
            Sticker(id: "tree", category: "Nature", path: tree(), mode: .fillStroke),
            Sticker(id: "drop", category: "Nature", path: drop()),
            Sticker(id: "fire", category: "Nature", path: fire(), mode: .fillStroke),
        ])

        // Food.
        stickers.append(contentsOf: [
            Sticker(id: "apple", category: "Food", path: apple(), mode: .fillStroke),
            Sticker(id: "coffee", category: "Food", path: coffee(), mode: .fillStroke),
            Sticker(id: "cake", category: "Food", path: cake(), mode: .fillStroke),
            Sticker(id: "pizza", category: "Food", path: pizza(), mode: .fillStroke),
            Sticker(id: "carrot", category: "Food", path: carrot(), mode: .fillStroke),
            Sticker(id: "ice-cream", category: "Food", path: iceCream(), mode: .fillStroke),
        ])

        // Charts.
        stickers.append(contentsOf: [
            Sticker(id: "chart-bar", category: "Charts", path: barChart(), mode: .fillStroke),
            Sticker(id: "chart-pie", category: "Charts", path: pieChart(), mode: .fillStroke),
            Sticker(id: "chart-line", category: "Charts", path: lineChart(), mode: .stroke),
            Sticker(id: "trend-up", category: "Charts", path: trend(true), mode: .stroke),
            Sticker(id: "trend-down", category: "Charts", path: trend(false), mode: .stroke),
            Sticker(id: "percent", category: "Charts", path: percentGlyph(), mode: .stroke),
        ])

        // Time.
        stickers.append(contentsOf: [
            Sticker(id: "clock", category: "Time", path: clock(), mode: .fillStroke),
            Sticker(id: "calendar", category: "Time", path: calendar(), mode: .fillStroke),
            Sticker(id: "bell", category: "Time", path: bell(), mode: .fillStroke),
            Sticker(id: "hourglass", category: "Time", path: hourglass(), mode: .fillStroke),
            Sticker(id: "timer", category: "Time", path: timer(), mode: .fillStroke),
            Sticker(id: "alarm", category: "Time", path: alarm(), mode: .fillStroke),
        ])

        // Symbols.
        stickers.append(contentsOf: [
            Sticker(id: "infinity", category: "Symbols", path: infinityLoop(), mode: .stroke),
            Sticker(id: "plus", category: "Symbols", path: plusGlyph(), mode: .stroke),
            Sticker(id: "minus", category: "Symbols", path: minusGlyph(), mode: .stroke),
            Sticker(id: "multiply", category: "Symbols", path: multiplyGlyph(), mode: .stroke),
            Sticker(id: "divide", category: "Symbols", path: divideGlyph(), mode: .stroke),
            Sticker(id: "equal", category: "Symbols", path: equalGlyph(), mode: .stroke),
            Sticker(id: "sqrt", category: "Symbols", path: sqrtGlyph(), mode: .stroke),
            Sticker(id: "pi", category: "Symbols", path: piGlyph(), mode: .stroke),
        ])

        // People.
        stickers.append(contentsOf: [
            Sticker(id: "person", category: "People", path: person(), mode: .fillStroke),
            Sticker(id: "people", category: "People", path: people(), mode: .fillStroke),
            Sticker(id: "thumbs-up", category: "People", path: thumbs(true), mode: .fillStroke),
            Sticker(id: "thumbs-down", category: "People", path: thumbs(false), mode: .fillStroke),
        ])

        // Milestone.
        stickers.append(contentsOf: [
            Sticker(id: "trophy", category: "Milestone", path: trophy(), mode: .fillStroke),
            Sticker(id: "medal", category: "Milestone", path: medal(), mode: .fillStroke),
            Sticker(id: "ribbon", category: "Milestone", path: ribbon(), mode: .fillStroke),
            Sticker(id: "finish", category: "Milestone", path: finishFlag(), mode: .fillStroke),
        ])

        // Documents.
        stickers.append(contentsOf: [
            Sticker(id: "doc", category: "Documents", path: document(), mode: .fillStroke),
            Sticker(id: "folder", category: "Documents", path: folder(), mode: .fillStroke),
            Sticker(id: "clipboard", category: "Documents", path: clipboard(), mode: .fillStroke),
            Sticker(id: "note", category: "Documents", path: noteSheet(), mode: .fillStroke),
            Sticker(id: "archive", category: "Documents", path: archive(), mode: .fillStroke),
        ])

        // Media.
        stickers.append(contentsOf: [
            Sticker(id: "music", category: "Media", path: musicNote(), mode: .fillStroke),
            Sticker(id: "film", category: "Media", path: film(), mode: .fillStroke),
            Sticker(id: "book", category: "Media", path: book(), mode: .fillStroke),
            Sticker(id: "pencil", category: "Media", path: pencil(), mode: .fillStroke),
            Sticker(id: "scissors", category: "Media", path: scissors(), mode: .fillStroke),
            Sticker(id: "quote", category: "Media", path: quoteGlyph(), mode: .fillStroke),
        ])

        // Misc — decision marks and the everyday tail.
        stickers.append(contentsOf: [
            Sticker(id: "check", category: "Misc", path: checkPath(), mode: .stroke),
            Sticker(id: "cross", category: "Misc", path: crossPath(), mode: .stroke),
            Sticker(id: "bang", category: "Misc", path: bangGlyph(), mode: .fillStroke),
            Sticker(id: "magnet", category: "Misc", path: magnet(), mode: .fillStroke),
        ])

        return stickers
    }

    // MARK: unit-box path helpers (24×24, y-down)

    private static func build(_ body: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        body(path)
        return path
    }

    private static func star(_ points: Int, innerRatio: CGFloat, radius: CGFloat = 10) -> CGPath {
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
    private static func sparkle(at center: (CGFloat, CGFloat), radius: CGFloat) -> CGPath {
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

    private static func sparkle(_ radius: CGFloat) -> CGPath {
        sparkle(at: (12, 12.5), radius: 10)
    }

    private static func sparkles() -> CGPath {
        let combined = CGMutablePath()
        combined.addPath(sparkle(at: (9, 9), radius: 7))
        combined.addPath(sparkle(at: (17, 16), radius: 4))
        return combined
    }

    private static func priorityBars(_ count: Int) -> CGPath {
        build { path in
            for index in 0..<count {
                let height = CGFloat(4 + index * 4)
                let rect = CGRect(x: CGFloat(3 + index * 4), y: 21 - height, width: 3, height: height)
                path.addRect(rect)
            }
        }
    }

    private static func progressRing(_ fraction: CGFloat) -> CGPath {
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

    private static func flagPath() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 6, y: 21))
            path.addLine(to: CGPoint(x: 6, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 9.5))
            path.closeSubpath()
        }
    }

    private static func arrow(_ rotation: CGFloat) -> CGPath {
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

    private static func mirrored(_ path: CGPath) -> CGPath {
        var transform = CGAffineTransform(translationX: 12, y: 0).scaledBy(x: -1, y: 1)
            .translatedBy(x: -12, y: 0)
        return path.copy(using: &transform) ?? path
    }

    private static func doubleArrow() -> CGPath {
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

    private static func bendArrow() -> CGPath {
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

    private static func curveArrow() -> CGPath {
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

    private static func returnArrow() -> CGPath {
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

    private enum Face {
        case happy, grin, wink, sad, crying, angry, surprised, neutral
    }

    private static func face(_ kind: Face) -> CGPath {
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

    private static func lightbulb() -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 9.6), radius: 6, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
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

    private static func questionMark() -> CGPath {
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

    private static func warningTriangle() -> CGPath {
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

    private static func keyPath() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 2.5, y: 3, width: 9, height: 9))
            path.addRect(CGRect(x: 10.5, y: 6.6, width: 11, height: 1.8))
            path.addRect(CGRect(x: 17, y: 8.4, width: 1.8, height: 3.4))
            path.addRect(CGRect(x: 13.5, y: 8.4, width: 1.8, height: 3.4))
        }
    }

    private static func pinPath() -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 9.5), radius: 6.2, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            path.move(to: CGPoint(x: 12, y: 15.7))
            path.addLine(to: CGPoint(x: 12, y: 21.5))
        }
    }

    private static func reviewLoop() -> CGPath {
        // Two circular arrows — the "review again" loop.
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 7, startAngle: -.pi / 2, endAngle: .pi * 0.75, clockwise: false)
            path.addLines(
                between: [
                    CGPoint(x: 12, y: 1.6), CGPoint(x: 15.4, y: 5.6), CGPoint(x: 8.6, y: 5.6),
                ])
            path.closeSubpath()
        }
    }

    private static func bookmarkPath() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 6, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 3))
            path.addLine(to: CGPoint(x: 18, y: 21))
            path.addLine(to: CGPoint(x: 12, y: 15.5))
            path.addLine(to: CGPoint(x: 6, y: 21))
            path.closeSubpath()
        }
    }

    private static func targetPath() -> CGPath {
        let combined = CGMutablePath()
        for radius in [8.5, 4.6] {
            let ring = CGMutablePath()
            ring.addArc(center: CGPoint(x: 12, y: 12), radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            combined.addPath(ring)
        }
        combined.addEllipse(in: CGRect(x: 10.6, y: 10.6, width: 2.8, height: 2.8))
        return combined
    }

    private static func heart() -> CGPath {
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

    private static func brokenHeart() -> CGPath {
        let whole = heart()
        let combined = CGMutablePath()
        combined.addPath(whole)
        combined.addLines(
            between: [CGPoint(x: 12, y: 4), CGPoint(x: 9.5, y: 9), CGPoint(x: 13.5, y: 12.5), CGPoint(x: 11, y: 17)])
        return combined
    }

    private static func sun() -> CGPath {
        let combined = CGMutablePath()
        combined.addEllipse(in: CGRect(x: 7.5, y: 7.5, width: 9, height: 9))
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            combined.move(to: CGPoint(x: 12 + cos(angle) * 6.4, y: 12 + sin(angle) * 6.4))
            combined.addLine(to: CGPoint(x: 12 + cos(angle) * 10.6, y: 12 + sin(angle) * 10.6))
        }
        return combined
    }

    private static func moon() -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 13.5, y: 12), radius: 8.5, startAngle: .pi * 0.25, endAngle: .pi * 1.75, clockwise: false)
            path.addArc(center: CGPoint(x: 8.5, y: 12), radius: 6.2, startAngle: .pi * 0.72, endAngle: .pi * 0.28, clockwise: true)
            path.closeSubpath()
        }
    }

    private static func cloudBody() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 5, y: 17))
            path.addArc(center: CGPoint(x: 7.5, y: 14.5), radius: 3.4, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
            path.addArc(center: CGPoint(x: 8.6, y: 10), radius: 3.8, startAngle: .pi * 0.9, endAngle: .pi * 1.7, clockwise: false)
            path.addArc(center: CGPoint(x: 14.8, y: 8.6), radius: 4.4, startAngle: .pi * 1.55, endAngle: .pi * 0.45, clockwise: false)
            path.addArc(center: CGPoint(x: 17.8, y: 13.5), radius: 3.4, startAngle: .pi * 1.5, endAngle: .pi / 2, clockwise: false)
            path.closeSubpath()
        }
    }

    private static func cloud() -> CGPath { cloudBody() }

    private static func rainCloud() -> CGPath {
        let combined = CGMutablePath()
        combined.addPath(cloudBody())
        combined.addLines(between: [CGPoint(x: 8, y: 17.5), CGPoint(x: 6.5, y: 21.5)])
        combined.addLines(between: [CGPoint(x: 12.5, y: 17.5), CGPoint(x: 11, y: 21.5)])
        combined.addLines(between: [CGPoint(x: 17, y: 17.5), CGPoint(x: 15.5, y: 21.5)])
        return combined
    }

    private static func snowCloud() -> CGPath {
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

    private static func lightning() -> CGPath {
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

    private static func rainbow() -> CGPath {
        build { path in
            for radius in [9.5, 6.5, 3.5] {
                path.move(to: CGPoint(x: 12 - radius, y: 19))
                // The UPPER arc in the y-down convention.
                path.addArc(center: CGPoint(x: 12, y: 19), radius: radius, startAngle: .pi, endAngle: 0, clockwise: false)
            }
        }
    }

    private static func umbrella() -> CGPath {
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

    private static func laptop() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 5, y: 6, width: 14, height: 9.5))
            path.addRect(CGRect(x: 2.5, y: 17.5, width: 19, height: 2))
        }
    }

    private static func phone() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 7.5, y: 3, width: 9, height: 18), cornerWidth: 2.4, cornerHeight: 2.4)
            path.addRect(CGRect(x: 10.5, y: 18.2, width: 3, height: 1.2))
        }
    }

    private static func wifi() -> CGPath {
        build { path in
            for radius: CGFloat in [4, 8, 12] {
                path.addArc(
                    center: CGPoint(x: 12, y: 21), radius: radius,
                    startAngle: .pi * 1.2, endAngle: .pi * 1.8, clockwise: false)
            }
            path.addEllipse(in: CGRect(x: 10.8, y: 19, width: 2.4, height: 2.4))
        }
    }

    private static func battery() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 2.5, y: 8, width: 17, height: 8), cornerWidth: 1.6, cornerHeight: 1.6)
            path.addRect(CGRect(x: 20, y: 10.5, width: 2, height: 3))
            path.addRect(CGRect(x: 4.5, y: 10, width: 11, height: 4))
        }
    }

    private static func camera() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 2.5, y: 7, width: 19, height: 13), cornerWidth: 2.2, cornerHeight: 2.2)
            path.addEllipse(in: CGRect(x: 8.5, y: 9.5, width: 8, height: 8))
            path.addRect(CGRect(x: 8.5, y: 4.5, width: 5, height: 2.5))
        }
    }

    private static func gear() -> CGPath {
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

    private static func plug() -> CGPath {
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

    private static func codeGlyphs() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 8.5, y: 7))
            path.addLine(to: CGPoint(x: 3, y: 12))
            path.addLine(to: CGPoint(x: 8.5, y: 17))
            path.move(to: CGPoint(x: 15.5, y: 7))
            path.addLine(to: CGPoint(x: 21, y: 12))
            path.addLine(to: CGPoint(x: 15.5, y: 17))
        }
    }

    private static func leaf() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 5, y: 20))
            path.addQuadCurve(to: CGPoint(x: 20, y: 4.5), control: CGPoint(x: 19.5, y: 19.5))
            path.addQuadCurve(to: CGPoint(x: 5, y: 20), control: CGPoint(x: 4.5, y: 5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 5, y: 20), CGPoint(x: 12, y: 12.5)])
        }
    }

    private static func flower() -> CGPath {
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

    private static func tree() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 5, y: 2.5, width: 14, height: 11))
            path.addRect(CGRect(x: 10.7, y: 13, width: 2.6, height: 9))
        }
    }

    private static func drop() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 3))
            path.addCurve(
                to: CGPoint(x: 12, y: 13), control1: CGPoint(x: 18.5, y: 10), control2: CGPoint(x: 17.5, y: 17))
            path.addArc(center: CGPoint(x: 12, y: 15.5), radius: 6.2, startAngle: .pi * 0.65, endAngle: .pi * 0.35, clockwise: true)
            path.closeSubpath()
        }
    }

    private static func fire() -> CGPath {
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

    private static func apple() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 3, y: 8, width: 18, height: 13.5))
            path.addLines(between: [CGPoint(x: 12, y: 8), CGPoint(x: 14, y: 3)])
            path.addQuadCurve(to: CGPoint(x: 10, y: 3.5), control: CGPoint(x: 12, y: 1.5))
            path.closeSubpath()
        }
    }

    private static func coffee() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4, y: 7, width: 12, height: 12))
            path.move(to: CGPoint(x: 16, y: 9))
            path.addQuadCurve(to: CGPoint(x: 21, y: 11), control: CGPoint(x: 21, y: 8.5))
            path.addQuadCurve(to: CGPoint(x: 16, y: 14), control: CGPoint(x: 21, y: 13.5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 3, y: 21), CGPoint(x: 17.5, y: 21)])
        }
    }

    private static func cake() -> CGPath {
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

    private static func pizza() -> CGPath {
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

    private static func carrot() -> CGPath {
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

    private static func iceCream() -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 9), radius: 6.4, startAngle: .pi * 1.05, endAngle: .pi * 1.95, clockwise: false)
            path.addLine(to: CGPoint(x: 4.5, y: 9.5))
            path.addLine(to: CGPoint(x: 12, y: 21))
            path.addLine(to: CGPoint(x: 19.5, y: 9.5))
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 4.5, y: 11.5), CGPoint(x: 19.5, y: 11.5)])
        }
    }

    private static func barChart() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4, y: 12, width: 3.6, height: 9))
            path.addRect(CGRect(x: 10.2, y: 7, width: 3.6, height: 14))
            path.addRect(CGRect(x: 16.4, y: 3.5, width: 3.6, height: 17.5))
        }
    }

    private static func pieChart() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 12, y: 12))
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 9, startAngle: -.pi / 2, endAngle: .pi * 0.7, clockwise: false)
            path.closeSubpath()
        }
    }

    private static func lineChart() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 3, y: 18))
            path.addLine(to: CGPoint(x: 8, y: 12))
            path.addLine(to: CGPoint(x: 12.5, y: 15))
            path.addLine(to: CGPoint(x: 21, y: 5))
        }
    }

    private static func trend(_ up: Bool) -> CGPath {
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

    private static func percentGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 19.5), CGPoint(x: 19, y: 4.5)])
            path.addEllipse(in: CGRect(x: 3.4, y: 3.4, width: 5.6, height: 5.6))
            path.addEllipse(in: CGRect(x: 15, y: 15, width: 5.6, height: 5.6))
        }
    }

    private static func clock() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            path.addLines(between: [CGPoint(x: 12, y: 7.5), CGPoint(x: 12, y: 12.5)])
            path.addLines(between: [CGPoint(x: 12, y: 12.5), CGPoint(x: 16, y: 15)])
        }
    }

    private static func calendar() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3.5, y: 5, width: 17, height: 16))
            path.addRect(CGRect(x: 3.5, y: 5, width: 17, height: 4.5))
            path.addLines(between: [CGPoint(x: 7.5, y: 2.5), CGPoint(x: 7.5, y: 7)])
            path.addLines(between: [CGPoint(x: 16.5, y: 2.5), CGPoint(x: 16.5, y: 7)])
        }
    }

    private static func bell() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 4, y: 17))
            path.addQuadCurve(to: CGPoint(x: 12, y: 5), control: CGPoint(x: 4, y: 5))
            path.addQuadCurve(to: CGPoint(x: 20, y: 17), control: CGPoint(x: 20, y: 5))
            path.addLine(to: CGPoint(x: 4, y: 17))
            path.closeSubpath()
            path.addArc(center: CGPoint(x: 12, y: 18.6), radius: 2.6, startAngle: .pi * 1.2, endAngle: .pi * 1.8, clockwise: false)
            path.addLines(between: [CGPoint(x: 9.8, y: 18.6), CGPoint(x: 14.2, y: 18.6)])
        }
    }

    private static func hourglass() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 3), CGPoint(x: 19, y: 3)])
            path.addLine(to: CGPoint(x: 13.5, y: 10))
            path.addLine(to: CGPoint(x: 19, y: 21))
            path.addLine(to: CGPoint(x: 5, y: 21))
            path.addLine(to: CGPoint(x: 10.5, y: 10))
            path.closeSubpath()
        }
    }

    private static func timer() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 4, y: 5.5, width: 16, height: 16))
            path.addLines(between: [CGPoint(x: 12, y: 10), CGPoint(x: 12, y: 13.5)])
            path.addLines(between: [CGPoint(x: 12, y: 13.5), CGPoint(x: 15, y: 15.5)])
            path.addRect(CGRect(x: 9.5, y: 2, width: 5, height: 2.2))
        }
    }

    private static func alarm() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 3.5, y: 5.5, width: 17, height: 16))
            path.addLines(between: [CGPoint(x: 12, y: 10), CGPoint(x: 12, y: 14)])
            path.addLines(between: [CGPoint(x: 12, y: 14), CGPoint(x: 15.4, y: 16.4)])
            path.addLines(between: [CGPoint(x: 3, y: 7), CGPoint(x: 7.5, y: 3)])
            path.addLines(between: [CGPoint(x: 21, y: 7), CGPoint(x: 16.5, y: 3)])
        }
    }

    private static func infinityLoop() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 6.5, y: 12))
            path.addCurve(to: CGPoint(x: 12, y: 7), control1: CGPoint(x: 1.5, y: 7), control2: CGPoint(x: 9, y: 7))
            path.addCurve(to: CGPoint(x: 17.5, y: 12), control1: CGPoint(x: 15, y: 7), control2: CGPoint(x: 22.5, y: 7))
            path.addCurve(to: CGPoint(x: 12, y: 17), control1: CGPoint(x: 22.5, y: 17), control2: CGPoint(x: 15, y: 17))
            path.addCurve(to: CGPoint(x: 6.5, y: 12), control1: CGPoint(x: 9, y: 17), control2: CGPoint(x: 1.5, y: 17))
        }
    }

    private static func plusGlyph() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 10.5, y: 3.5, width: 3, height: 17))
            path.addRect(CGRect(x: 3.5, y: 10.5, width: 17, height: 3))
        }
    }

    private static func minusGlyph() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3.5, y: 10.5, width: 17, height: 3))
        }
    }

    private static func multiplyGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 5), CGPoint(x: 19, y: 19)])
            path.addLines(between: [CGPoint(x: 19, y: 5), CGPoint(x: 5, y: 19)])
        }
    }

    private static func divideGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 4, y: 12), CGPoint(x: 20, y: 12)])
            path.addEllipse(in: CGRect(x: 10.6, y: 3.6, width: 2.8, height: 2.8))
            path.addEllipse(in: CGRect(x: 10.6, y: 17.6, width: 2.8, height: 2.8))
        }
    }

    private static func equalGlyph() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4, y: 8, width: 16, height: 2.6))
            path.addRect(CGRect(x: 4, y: 13.4, width: 16, height: 2.6))
        }
    }

    private static func sqrtGlyph() -> CGPath {
        build { path in
            path.move(to: CGPoint(x: 2.5, y: 13.5))
            path.addLine(to: CGPoint(x: 6.5, y: 13.5))
            path.addLine(to: CGPoint(x: 9, y: 5))
            path.addLine(to: CGPoint(x: 13, y: 19))
            path.addLine(to: CGPoint(x: 21.5, y: 19))
        }
    }

    private static func piGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 4, y: 7), CGPoint(x: 20, y: 7)])
            path.addLines(between: [CGPoint(x: 8, y: 7), CGPoint(x: 8, y: 18)])
            path.addLines(between: [CGPoint(x: 16, y: 7), CGPoint(x: 16, y: 16)])
            path.addQuadCurve(to: CGPoint(x: 16, y: 18.5), control: CGPoint(x: 16, y: 20))
        }
    }

    private static func person() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 8.6, y: 3, width: 6.8, height: 6.8))
            // Shoulders as a dome under the head.
            path.addEllipse(in: CGRect(x: 4.5, y: 11.5, width: 15, height: 10))
        }
    }

    private static func people() -> CGPath {
        let combined = CGMutablePath()
        combined.addEllipse(in: CGRect(x: 3.6, y: 4.4, width: 5.6, height: 5.6))
        combined.addEllipse(in: CGRect(x: 1.5, y: 14, width: 10, height: 7))
        combined.addEllipse(in: CGRect(x: 14.8, y: 3, width: 6, height: 6))
        combined.addEllipse(in: CGRect(x: 13, y: 13, width: 9.5, height: 8))
        return combined
    }

    private static func thumbs(_ up: Bool) -> CGPath {
        let thumb = CGMutablePath()
        thumb.addPath(build { path in
            path.addRect(CGRect(x: 3, y: 10.5, width: 7.5, height: 10))
        })
        thumb.addPath(build { path in
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

    private static func trophy() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 8, y: 2.5, width: 8, height: 6))
            path.addLines(between: [CGPoint(x: 9, y: 8.5), CGPoint(x: 6, y: 11)])
            path.addArc(center: CGPoint(x: 6.4, y: 7), radius: 2.8, startAngle: .pi / 2, endAngle: 1.5 * .pi, clockwise: true)
            path.addLines(between: [CGPoint(x: 15, y: 8.5), CGPoint(x: 18, y: 11)])
            path.addArc(center: CGPoint(x: 17.6, y: 7), radius: 2.8, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
            path.addLines(between: [CGPoint(x: 11, y: 8.5), CGPoint(x: 11, y: 13)])
            path.addLines(between: [CGPoint(x: 13, y: 8.5), CGPoint(x: 13, y: 13)])
            path.addRect(CGRect(x: 7.5, y: 13, width: 9, height: 2.4))
            path.addRect(CGRect(x: 5.5, y: 15.4, width: 13, height: 2))
            path.addRect(CGRect(x: 4, y: 17.4, width: 16, height: 4))
        }
    }

    private static func medal() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 8.5, y: 2.5), CGPoint(x: 12, y: 10)])
            path.addLines(between: [CGPoint(x: 15.5, y: 2.5), CGPoint(x: 12, y: 10)])
            path.addEllipse(in: CGRect(x: 6, y: 9.5, width: 12, height: 12))
            path.addEllipse(in: CGRect(x: 9, y: 12.5, width: 6, height: 6))
        }
    }

    private static func ribbon() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 8, y: 3, width: 8, height: 8))
            path.addLines(
                between: [CGPoint(x: 9, y: 10.5), CGPoint(x: 5.5, y: 21.5), CGPoint(x: 12, y: 18)])
            path.addLines(
                between: [CGPoint(x: 15, y: 10.5), CGPoint(x: 18.5, y: 21.5), CGPoint(x: 12, y: 18)])
        }
    }

    private static func finishFlag() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 5, y: 2.5), CGPoint(x: 5, y: 21.5)])
            path.addRect(CGRect(x: 5, y: 4, width: 13, height: 9))
            path.addLines(between: [CGPoint(x: 9.7, y: 4), CGPoint(x: 9.7, y: 13)])
            path.addLines(between: [CGPoint(x: 13.3, y: 4), CGPoint(x: 13.3, y: 13)])
            path.addLines(between: [CGPoint(x: 5, y: 8.5), CGPoint(x: 18, y: 8.5)])
        }
    }

    private static func document() -> CGPath {
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

    private static func folder() -> CGPath {
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

    private static func clipboard() -> CGPath {
        build { path in
            path.addRoundedRect(in: CGRect(x: 4, y: 4.5, width: 16, height: 17), cornerWidth: 1.6, cornerHeight: 1.6)
            path.addRoundedRect(in: CGRect(x: 8.5, y: 2.5, width: 7, height: 4), cornerWidth: 1.4, cornerHeight: 1.4)
            path.addLines(between: [CGPoint(x: 7.5, y: 11), CGPoint(x: 16.5, y: 11)])
            path.addLines(between: [CGPoint(x: 7.5, y: 15), CGPoint(x: 16.5, y: 15)])
        }
    }

    private static func noteSheet() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 4.5, y: 3, width: 15, height: 18))
            path.addLines(between: [CGPoint(x: 7.5, y: 7.5), CGPoint(x: 16.5, y: 7.5)])
            path.addLines(between: [CGPoint(x: 7.5, y: 11), CGPoint(x: 16.5, y: 11)])
            path.addLines(between: [CGPoint(x: 7.5, y: 14.5), CGPoint(x: 13, y: 14.5)])
        }
    }

    private static func archive() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3, y: 6, width: 18, height: 4.5))
            path.addRect(CGRect(x: 4.8, y: 10.5, width: 14.4, height: 10.5))
            path.addLines(between: [CGPoint(x: 9.5, y: 14.5), CGPoint(x: 14.5, y: 14.5)])
        }
    }

    private static func musicNote() -> CGPath {
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

    private static func film() -> CGPath {
        build { path in
            path.addRect(CGRect(x: 3, y: 4.5, width: 18, height: 15))
            for index in 0..<3 {
                let y = CGFloat(6.6 + Double(index) * 5.2)
                path.addRect(CGRect(x: 4.2, y: y, width: 1.9, height: 3.2))
                path.addRect(CGRect(x: 17.9, y: y, width: 1.9, height: 3.2))
            }
        }
    }

    private static func book() -> CGPath {
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

    private static func pencil() -> CGPath {
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

    private static func scissors() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 12, y: 11), CGPoint(x: 20.5, y: 2.5)])
            path.addLines(between: [CGPoint(x: 12, y: 11), CGPoint(x: 20.5, y: 19.5)])
            path.addEllipse(in: CGRect(x: 5, y: 16.5, width: 5.4, height: 5.4))
            path.addEllipse(in: CGRect(x: 5, y: 2.6, width: 5.4, height: 5.4))
        }
    }

    private static func quoteGlyph() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 4, y: 14, width: 4.4, height: 4.4))
            path.addRect(CGRect(x: 4, y: 5, width: 2.4, height: 10))
            path.addEllipse(in: CGRect(x: 13.6, y: 14, width: 4.4, height: 4.4))
            path.addRect(CGRect(x: 13.6, y: 5, width: 2.4, height: 10))
        }
    }

    private static func checkPath() -> CGPath {
        build { path in
            path.addLines(
                between: [
                    CGPoint(x: 3.5, y: 12.5), CGPoint(x: 9, y: 18.5), CGPoint(x: 20.5, y: 5.5),
                ])
        }
    }

    private static func crossPath() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 4.5, y: 4.5), CGPoint(x: 19.5, y: 19.5)])
            path.addLines(between: [CGPoint(x: 19.5, y: 4.5), CGPoint(x: 4.5, y: 19.5)])
        }
    }

    private static func bangGlyph() -> CGPath {
        build { path in
            path.addLines(between: [CGPoint(x: 12, y: 2.5), CGPoint(x: 13.6, y: 14.5)])
            path.addLine(to: CGPoint(x: 10.4, y: 14.5))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 10.4, y: 17.5, width: 3.2, height: 3.2))
        }
    }

    private static func magnet() -> CGPath {
        build { path in
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 7, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addRect(CGRect(x: 2.5, y: 12, width: 2.6, height: 5.5))
            path.addRect(CGRect(x: 18.9, y: 12, width: 2.6, height: 5.5))
            path.addRect(CGRect(x: 2.5, y: 12, width: 2.6, height: 2.2))
            path.addRect(CGRect(x: 18.9, y: 12, width: 2.6, height: 2.2))
        }
    }

    private static func rosette() -> CGPath {
        build { path in
            path.addEllipse(in: CGRect(x: 5.5, y: 3, width: 13, height: 13))
            path.addLines(
                between: [CGPoint(x: 8, y: 15.5), CGPoint(x: 6, y: 21.5), CGPoint(x: 12, y: 18.5)])
            path.addLines(
                between: [CGPoint(x: 16, y: 15.5), CGPoint(x: 18, y: 21.5), CGPoint(x: 12, y: 18.5)])
        }
    }
}
