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

    // The path builders live in Stickers+Paths*.swift
}
