import CoreGraphics
import Foundation
import MapCore

/// Which part of a map an export renders (SPEC §5.17 PDF options).
public enum ExportContent: Sendable, Hashable {
    /// Every visible node of the scene.
    case wholeMap
    /// Only the subtrees rooted at these ids (a selection export).
    case subtree(Set<String>)
}

/// Options for the PDF exporter: content, background and the document
/// outline (bookmarks) mirroring the tree.
public struct PDFExportOptions: Sendable, Hashable {
    /// What goes into the PDF.
    public enum Content: Sendable, Hashable {
        /// The rendered map, one page sized to the content.
        case map(ExportContent)
        /// A text outline document (paginated, one line per node).
        case outline
    }

    public var content: Content
    /// Whether the canvas background color paints behind the map.
    public var includeBackground: Bool
    /// Whether the PDF document outline (bookmarks) mirrors the tree.
    public var includeBookmarks: Bool
    /// Whitespace around the content, in points.
    public var margin: CGFloat
    /// The document outline root's title.
    public var title: String

    public init(
        content: Content = .map(.wholeMap),
        includeBackground: Bool = true,
        includeBookmarks: Bool = true,
        margin: CGFloat = 24,
        title: String = "Map"
    ) {
        self.content = content
        self.includeBackground = includeBackground
        self.includeBookmarks = includeBookmarks
        self.margin = margin
        self.title = title
    }
}

/// Raster export formats (SPEC §5.17: PNG / JPEG / HEIC).
public enum ImageExportFormat: String, Sendable, Hashable, CaseIterable {
    case png
    case jpeg
    case heic

    public var utTypeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    public var supportsTransparency: Bool { self != .jpeg }
}

/// Options for the raster exporter.
public struct ImageExportOptions: Sendable, Hashable {
    public var format: ImageExportFormat = .png
    /// 1×/2×/3× (SPEC §5.17). Ignored when `targetLongEdgePixels` is set.
    public var pixelScale: Int = 1
    /// When set, the long edge is rendered at exactly this many pixels
    /// (the Quick Look thumbnail uses 512) instead of scaling by
    /// `pixelScale`.
    public var targetLongEdgePixels: Int? = nil
    /// Transparent background (PNG/HEIC only; JPEG always fills).
    public var transparentBackground: Bool = false
    /// Whitespace around the content, in points.
    public var margin: CGFloat = 16
    /// The SPEC §5.17 hard cap: requests beyond it are clamped.
    public var maxLongEdgePixels: Int = 16_384
    /// Edge length of one render tile; tiles keep raster working set
    /// bounded on huge exports.
    public var tileSize: Int = 4_096
    /// Outputs at or under this many pixels render in a single pass;
    /// bigger ones render in tiles.
    public var singlePassMaxPixels: Int = 64 * 1_024 * 1_024
    /// Test hook: forces the tiled path even for small outputs.
    public var forceTiled: Bool = false

    public init(
        format: ImageExportFormat = .png,
        pixelScale: Int = 1,
        targetLongEdgePixels: Int? = nil,
        transparentBackground: Bool = false,
        margin: CGFloat = 16
    ) {
        self.format = format
        self.pixelScale = pixelScale
        self.targetLongEdgePixels = targetLongEdgePixels
        self.transparentBackground = transparentBackground
        self.margin = margin
    }
}

/// Options for the SVG emitter.
public struct SVGExportOptions: Sendable, Hashable {
    /// Text as `<text>` (default) or as glyph outline paths (portable
    /// rendering without the fonts installed).
    public var textAsOutlines: Bool = false
    public var includeBackground: Bool = true
    public var margin: CGFloat = 16

    public init(textAsOutlines: Bool = false, includeBackground: Bool = true, margin: CGFloat = 16) {
        self.textAsOutlines = textAsOutlines
        self.includeBackground = includeBackground
        self.margin = margin
    }
}
