import CoreGraphics
import Foundation
import ImageIO
import MapCore
import Testing
import UniformTypeIdentifiers

@testable import SceneExport

/// Raster export tests: dimensions per scale, the 16k clamp, alpha
/// behavior, and tiled ≡ single-pass equivalence.
struct ImageExporterTests {
    private func export(_ options: ImageExportOptions) throws -> ImageExporter.Result {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)
        return try ImageExporter.export(scene: scene, model: model, options: options)
    }

    @Test func dimensionsFollowThePixelScale() throws {
        let single = try export(ImageExportOptions(format: .png, pixelScale: 1))
        #expect(single.pixelSize.width > 0)
        #expect(single.pixelSize.height > 0)

        let double = try export(ImageExportOptions(format: .png, pixelScale: 2))
        #expect(double.pixelSize.width.rounded() == (single.pixelSize.width * 2).rounded())
        #expect(double.pixelSize.height.rounded() == (single.pixelSize.height * 2).rounded())

        let triple = try export(ImageExportOptions(format: .png, pixelScale: 3))
        #expect(triple.pixelSize.width.rounded() == (single.pixelSize.width * 3).rounded())
    }

    @Test func requestsBeyond16kAreClampedOnTheLongEdge() throws {
        var options = ImageExportOptions(format: .png, pixelScale: 200)
        options.margin = 0
        let result = try export(options)
        #expect(max(result.pixelSize.width, result.pixelSize.height) == 16_384)
        #expect(result.pixelSize.width <= 16_384)
        #expect(result.pixelSize.height <= 16_384)
        // The clamped file decodes at the clamped size.
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == Int(result.pixelSize.width))
        #expect(image.height == Int(result.pixelSize.height))
    }

    @Test func transparentPNGHasZeroAlphaOutsideNodesAndOpaqueDoesNot() throws {
        let transparent = try export(
            ImageExportOptions(format: .png, pixelScale: 1, transparentBackground: true))
        #expect(try cornerAlpha(of: transparent.data) == 0)

        let opaque = try export(
            ImageExportOptions(format: .png, pixelScale: 1, transparentBackground: false))
        let opaqueAlpha = try cornerAlpha(of: opaque.data)
        #expect(opaqueAlpha == 255)
    }

    @Test func jpegAndHEICEncodeOpaqueAtRequestedSize() throws {
        for format in [ImageExportFormat.jpeg, .heic] {
            let result = try export(ImageExportOptions(format: format, pixelScale: 1))
            let source = try #require(
                CGImageSourceCreateWithData(result.data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == Int(result.pixelSize.width))
            #expect(image.height == Int(result.pixelSize.height))
            #expect(try cornerAlpha(of: result.data) == 255)
        }
    }

    @Test func tiledRenderMatchesSinglePassPixelForPixel() throws {
        var singleOptions = ImageExportOptions(format: .png, pixelScale: 2)
        singleOptions.margin = 8
        let singlePass = try export(singleOptions)

        var tiledOptions = singleOptions
        tiledOptions.forceTiled = true
        tiledOptions.tileSize = 64
        let tiled = try export(tiledOptions)

        #expect(tiled.pixelSize == singlePass.pixelSize)
        try comparePixels(tiled.data, against: singlePass.data, size: singlePass.pixelSize)
    }

    @Test func targetLongEdgeProducesExactThumbnailSize() throws {
        let result = try export(
            ImageExportOptions(format: .png, pixelScale: 1, targetLongEdgePixels: 512))
        #expect(max(result.pixelSize.width, result.pixelSize.height) == 512)
    }

    /// Every node lands where the export bounds put it, including the
    /// left-hand branches of a balanced map (bounds.minX < 0). The bounds
    /// offset is applied once, by `ScenePainter`.
    @Test func nodesPaintAtTheirExportPositions() throws {
        let model = ExportFixtures.canonicalMap()
        let scene = ExportFixtures.scene(for: model)
        let options = ImageExportOptions(format: .png, pixelScale: 1, transparentBackground: true)
        let geometry = ExportGeometry.content(
            scene: scene, model: model, content: .wholeMap, margin: options.margin)
        try #require(geometry.bounds.minX < -10, "the fixture needs left-hand branches")

        let result = try ImageExporter.export(scene: scene, model: model, options: options)
        let width = Int(result.pixelSize.width)
        let height = Int(result.pixelSize.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try decode(result.data, into: &pixels, width: width, height: height)
        // Any painted pixel inside the node's frame counts: text-only
        // nodes leave gaps between glyphs.
        for node in geometry.nodes {
            let frame = node.frame.offsetBy(dx: -geometry.bounds.minX, dy: -geometry.bounds.minY)
            var painted = false
            for row in Int(frame.minY)..<Int(frame.maxY) where !painted {
                // The decoded buffer's rows run bottom-up.
                let y = height - 1 - row
                for column in Int(frame.minX)..<Int(frame.maxX) where pixels[(y * width + column) * 4 + 3] > 0 {
                    painted = true
                    break
                }
            }
            #expect(painted, "node \(node.id) is not painted at its export position")
        }
    }

    // MARK: pixel helpers

    /// The alpha byte of the output's top-left pixel — pure background
    /// thanks to the margin.
    private func cornerAlpha(of data: Data) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try decode(data, into: &pixels, width: image.width, height: image.height)
        // The decoded buffer's rows run bottom-up: the top-left pixel
        // starts the last row.
        return pixels[(image.height - 1) * image.width * 4 + 3]
    }

    /// Decodes both files to premultiplied RGBA and requires equality
    /// within antialiasing tolerance: tile seams clip in exact device
    /// pixels, so in practice the buffers are byte-identical, but Quartz
    /// may round a coverage value differently on either side of a seam.
    private func comparePixels(_ first: Data, against second: Data, size: CGSize) throws {
        let width = Int(size.width)
        let height = Int(size.height)
        var firstPixels = [UInt8](repeating: 0, count: width * height * 4)
        var secondPixels = [UInt8](repeating: 0, count: width * height * 4)
        try decode(first, into: &firstPixels, width: width, height: height)
        try decode(second, into: &secondPixels, width: width, height: height)

        var mismatchedPixels = 0
        var maxDelta = 0
        for index in 0..<(width * height) {
            var pixelDelta = 0
            for channel in 0..<4 {
                pixelDelta = max(
                    pixelDelta,
                    abs(Int(firstPixels[index * 4 + channel]) - Int(secondPixels[index * 4 + channel])))
            }
            if pixelDelta > 0 {
                mismatchedPixels += 1
                maxDelta = max(maxDelta, pixelDelta)
            }
        }
        print(
            "tiled vs single-pass: \(mismatchedPixels) of \(width * height) pixels differ, max channel delta \(maxDelta)"
        )
        #expect(maxDelta <= 1)
        // A seam rounding here and there is noise; anything more is wrong.
        #expect(mismatchedPixels <= max(1, width * height / 1_000))
    }

    private func decode(_ data: Data, into pixels: inout [UInt8], width: Int, height: Int) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            Issue.record("could not decode rendered PNG for comparison")
            return
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
