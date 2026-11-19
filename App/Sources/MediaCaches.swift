import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The decode target for node image thumbnails (F-CNT-2): images
/// render far smaller than this on the canvas. File scope so the
/// off-main decode path can read it without an actor hop.
private let mediaThumbnailLongEdge: CGFloat = 512

/// The document's decoded image thumbnails (F-CNT-2): assets live in
/// the package as bytes (`FileWrapper`, main-actor), so the bytes are
/// fetched on main (an in-memory dictionary hit) and the DECODE runs
/// off the main thread — the scene build never blocks on a decode
/// (§11.8: the keystroke path pays a cache lookup, a miss draws the
/// placeholder, and the completion bumps the media revision so exactly
/// the image nodes re-raster).
@MainActor
final class MediaAssetStore {
    private var thumbnails: [String: CGImage] = [:]
    private var pending: Set<String> = []
    private(set) var revision = 0
    /// Called on the main actor after a decode lands (the host bumps
    /// the scene media revision and rebuilds).
    var onDecoded: (() -> Void)?

    /// The thumbnail for `asset`, or nil when still decoding/absent —
    /// nil is the renderer's placeholder state, not an error.
    func thumbnail(named asset: String, fetch: () -> Data?) -> CGImage? {
        if let cached = thumbnails[asset] {
            return cached
        }
        guard !pending.contains(asset) else { return nil }
        guard let data = fetch() else { return nil }
        pending.insert(asset)
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = Self.decode(data)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pending.remove(asset)
                if let decoded {
                    self.thumbnails[asset] = decoded
                    self.revision += 1
                    self.onDecoded?()
                }
            }
        }
        return nil
    }

    /// One asset's decoded bytes, downscaled to the thumbnail edge via
    /// ImageIO's kCGImageSourceThumbnailMaxPixelSize (no AppKit on
    /// this path). Off the main actor by construction.
    nonisolated private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(mediaThumbnailLongEdge),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The store for the document's LONG-edge import downscale
    /// (F-CNT-2's setting, default on): images larger than 2048 px
    /// are downscaled before their bytes join the package.
    static func downscaledImagePNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return data
        }
        let longEdge = max(width, height)
        guard CGFloat(longEdge) > Self.importLongEdgeLimit else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(Self.importLongEdgeLimit),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return data }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return data }
        CGImageDestinationAddImage(destination, thumb, nil)
        guard CGImageDestinationFinalize(destination), !out.isEmpty else { return data }
        return out as Data
    }

    /// F-CNT-2's import downscale setting (Settings ▸ Editing, default
    /// 2048).
    static var importLongEdgeLimit: CGFloat {
        let raw = UserDefaults.standard.object(forKey: "ImageImportLongEdgeLimit") as? Double
        return CGFloat(raw ?? 2048)
    }
}

/// The SF Symbol marker glyph cache (F-CNT-3): `sf:<name>` tokens
/// raster tinted at a fixed crisp size (template symbol + tint +
/// 2× raster). AppKit-only glyphs, so they ride the raster seam the
/// stickers (vector paths) and emoji (Core Text) never touch.
@MainActor
enum SFSymbolGlyphCache {
    private static var cache: [String: CGImage] = [:]
    /// Raster edge in points (drawn at 2×).
    static let glyphEdge: CGFloat = 16

    static func image(token: String, tint: CGColor) -> CGImage? {
        let name = String(token.dropFirst("sf:".count))
        let key = name + "-" + (tint.components?.map { String(format: "%.2f", $0) }.joined(separator: ",") ?? "")
        if let cached = cache[key] {
            return cached
        }
        var symbolName = name
        // Markers prefer filled variants at 14 pt — fall back to the
        // bare name when Apple ships no filled one.
        if !symbolName.hasSuffix(".fill") {
            if NSImage(systemSymbolName: symbolName + ".fill", accessibilityDescription: nil) != nil {
                symbolName += ".fill"
            }
        }
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        guard let raster = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        // Normalize into the fixed square and tint (template symbol →
        // color): draw, then fill with .sourceAtop.
        let edge = glyphEdge * 2
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int(edge), height: Int(edge), bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let side = min(raster.width, raster.height)
        let drawRect = CGRect(
            x: (edge - CGFloat(side)) / 2, y: (edge - CGFloat(side)) / 2,
            width: CGFloat(side), height: CGFloat(side))
        context.interpolationQuality = .high
        context.draw(raster, in: drawRect)
        context.setBlendMode(.sourceAtop)
        context.setFillColor(tint)
        context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        guard let normalized = context.makeImage() else { return nil }
        cache[key] = normalized
        return normalized
    }

    /// The picker's searchable catalog: a curated, stable slice of SF
    /// Symbols that reads well at marker size (F-CNT-3's "searchable,
    /// tintable" tab).
    static let catalog: [String] = [
        "star", "bookmark", "flag", "tag", "flame", "bolt", "sparkles", "sun.max", "moon",
        "cloud", "snowflake", "wind", "drop", "leaf", "tree", "camera", "photo", "film",
        "music.note", "mic", "headphones", "book", "newspaper", "graduationcap", "pencil",
        "highlighter", "scissors", "paperclip", "doc", "folder", "archivebox", "clipboard",
        "link", "magnifyingglass", "lightbulb", "questionmark", "exclamationmark", "checkmark",
        "xmark", "plus", "minus", "multiply", "divide", "equal", "percent", "infinity",
        "arrow.right", "arrow.left", "arrow.up", "arrow.down", "arrow.triangle.2.circlepath",
        "clock", "alarm", "calendar", "hourglass", "bell", "timer", "airplane", "car",
        "bicycle", "figure.walk", "heart", "hand.thumbsup", "hand.thumbsdown", "face.smiling",
        "face.crying", "person", "person.2", "trophy", "medal", "rosette", "target",
        "chart.bar", "chart.pie", "chart.line.uptrend.xy", "chart.line.downtrend.xy",
        "gauge", "scalemass", "keyboard", "desktopcomputer", "laptopcomputer", "iphone",
        "battery", "wifi", "antenna", "gear", "wrench", "hammer", "screwdriver", "paintbrush",
        "gift", "cart", "creditcard", "dollarsign", "creditcard", "banknote", "house",
        "building", "map", "mappin", "location", "globe", "paperplane", "envelope",
        "phone", "message", "bubble.left", "quote.opening", "key", "lock",
        "shield", "eye", "ear", "brain", "atom", "flask", "dna", "microbe", "pill",
        "stethoscope", "bandage", "cup.and.saucer", "fork.knife", "carrot", "birthday.cake",
    ]
}
