import CanvasKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import MapCore
import MapRender

/// Raster export (SPEC §5.17: PNG / JPEG / HEIC at 1×/2×/3×, transparent
/// background, max 16k px on the long edge). Large outputs render in
/// tiles into one lazily-committed `mmap` bitmap and are assembled into
/// a single image through `CGImageDestination`.
///
/// ImageIO has no tile-compositing API (every `CGImageDestinationAddImage`
/// adds another *frame*, not a stitch), so the assembler buffer is an
/// anonymous `mmap`: the full-resolution bitmap is reserved, but pages
/// commit only where content actually draws — the background stays
/// untouched (zero = transparent) unless it must be painted. Per-tile
/// clipped rendering keeps Quartz's working set bounded no matter the
/// map size, and encoding happens while the buffer is still alive
/// because `makeImage()` may reference the context's memory in place.
public enum ImageExporter {
    /// A finished raster export: encoded bytes plus the pixel size that
    /// was actually rendered (after any 16k clamping).
    public struct Result: Sendable {
        public let data: Data
        public let pixelSize: CGSize
    }

    public static func export(
        scene: CanvasScene,
        model: MapModel,
        content: ExportContent = .wholeMap,
        options: ImageExportOptions,
        measurer: TextMeasurer = SceneRenderer.sharedMeasurer
    ) throws -> Result {
        let export = ExportGeometry.content(
            scene: scene, model: model, content: content, margin: options.margin)
        guard !export.nodes.isEmpty else { throw SceneExportError.emptyScene }

        let pixelSize = outputPixelSize(for: export.bounds, options: options)
        let renderScale = pixelSize.width / export.bounds.width
        // JPEG has no alpha; its background always paints.
        let background: CGColor? =
            options.format.supportsTransparency && options.transparentBackground
            ? nil : export.canvasColor

        let singlePass =
            !options.forceTiled
            && Int(pixelSize.width) * Int(pixelSize.height) <= options.singlePassMaxPixels
        let tileSize = singlePass ? pixelSize : CGSize(width: options.tileSize, height: options.tileSize)

        let data = try render(
            export: export, pixelSize: pixelSize, renderScale: renderScale,
            tileSize: tileSize, background: background,
            format: options.format, dpi: 72 * renderScale, measurer: measurer)
        return Result(data: data, pixelSize: pixelSize)
    }

    // MARK: size math

    /// The output pixel size for `bounds`: the chosen scale (or the
    /// exact `targetLongEdgePixels`), clamped so the long edge never
    /// exceeds `maxLongEdgePixels` (SPEC §5.17's 16k cap).
    public static func outputPixelSize(for bounds: CGRect, options: ImageExportOptions) -> CGSize {
        var width: CGFloat
        var height: CGFloat
        if let target = options.targetLongEdgePixels {
            let scale = CGFloat(target) / max(bounds.width, bounds.height)
            width = (bounds.width * scale).rounded()
            height = (bounds.height * scale).rounded()
        } else {
            let scale = CGFloat(max(1, options.pixelScale))
            width = (bounds.width * scale).rounded()
            height = (bounds.height * scale).rounded()
        }
        let longEdge = max(width, height)
        if longEdge > CGFloat(options.maxLongEdgePixels) {
            let clamp = CGFloat(options.maxLongEdgePixels) / longEdge
            width = (width * clamp).rounded(.down)
            height = (height * clamp).rounded(.down)
            // The long edge lands exactly on the cap, regardless of where
            // the proportional arithmetic fell.
            if width >= height {
                width = CGFloat(options.maxLongEdgePixels)
            } else {
                height = CGFloat(options.maxLongEdgePixels)
            }
        }
        return CGSize(width: max(1, width), height: max(1, height))
    }

    // MARK: rendering

    /// Premultiplied BGRA (`byteOrder32Little | premultipliedFirst`) —
    /// the alpha byte of pixel `p` is `buffer[p * 4 + 3]`.
    private static let bitmapInfo =
        CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    /// Renders the whole export, one clipped tile at a time, into a
    /// lazily-committed bitmap, then encodes it before the buffer is
    /// released.
    private static func render(
        export: ExportScene,
        pixelSize: CGSize,
        renderScale: CGFloat,
        tileSize: CGSize,
        background: CGColor?,
        format: ImageExportFormat,
        dpi: CGFloat,
        measurer: TextMeasurer
    ) throws -> Data {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let rowBytes = width * 4
        let totalBytes = rowBytes * height

        // A tile-sized (or smaller) render never needs the mapping: the
        // plain allocator is cheaper.
        let needsMapping = totalBytes > Int(tileSize.width * tileSize.height * 4)
        let bufferBase: UnsafeMutableRawPointer
        let release: () -> Void
        if needsMapping, let mapping = anonymousMap(bytes: totalBytes) {
            bufferBase = mapping.base
            release = { munmap(mapping.base, mapping.count) }
        } else {
            guard let heap = malloc(totalBytes) else {
                throw SceneExportError.bitmapContextCreationFailed(width: width, height: height)
            }
            memset(heap, 0, totalBytes)
            bufferBase = heap
            release = { free(heap) }
        }
        defer { release() }

        guard
            let context = CGContext(
                data: bufferBase,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: bitmapInfo)
        else {
            throw SceneExportError.bitmapContextCreationFailed(width: width, height: height)
        }

        if let background {
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: pixelSize))
        }

        for tileTop in stride(from: 0, to: Int(pixelSize.height), by: Int(tileSize.height)) {
            for tileLeft in stride(from: 0, to: Int(pixelSize.width), by: Int(tileSize.width)) {
                let tileHeight = min(Int(tileSize.height), height - tileTop)
                let tileWidth = min(Int(tileSize.width), width - tileLeft)
                // Clip in exact device pixels (integer rect, y-up from the
                // bitmap's bottom-left) *before* the model transform, so
                // tile seams rasterize bit-identically to a single pass.
                let deviceTile = CGRect(
                    x: tileLeft, y: height - tileTop - tileHeight,
                    width: tileWidth, height: tileHeight)
                context.saveGState()
                context.clip(to: deviceTile)
                // The canvas's y-down convention: (0,0) at the top-left of
                // the bitmap, then the render scale. `ScenePainter`
                // subtracts the bounds origin itself.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                context.scaleBy(x: renderScale, y: renderScale)
                ScenePainter.draw(export, measurer: measurer, in: context, background: nil)
                context.restoreGState()
            }
        }

        guard let image = context.makeImage() else {
            throw SceneExportError.bitmapContextCreationFailed(width: width, height: height)
        }
        return try encode(image, format: format, dpi: dpi)
    }

    /// Reserves `bytes` of lazily-committed zero pages. Anonymous private
    /// mappings commit on first touch, so a 16k-px buffer costs memory
    /// only where content actually drew.
    private static func anonymousMap(bytes: Int) -> (base: UnsafeMutableRawPointer, count: Int)? {
        guard bytes > 0 else { return nil }
        let raw = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
        guard let base = raw, base != MAP_FAILED else { return nil }
        return (base, bytes)
    }

    // MARK: encoding

    /// Assembles the finished bitmap into the requested container via
    /// `CGImageDestination`.
    private static func encode(_ image: CGImage, format: ImageExportFormat, dpi: CGFloat) throws -> Data {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, format.utTypeIdentifier as CFString, 1, nil)
        else {
            throw SceneExportError.imageDestinationFailed(format.rawValue)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SceneExportError.imageDestinationFailed(format.rawValue)
        }
        return output as Data
    }
}
