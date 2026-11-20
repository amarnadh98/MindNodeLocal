import CoreGraphics
import Foundation
import ImageIO
import MapCore
import MapRender
import PDFKit
import SceneExport
import SystemIntegration
import Testing

/// F-INT-3's shared choice logic (ADR-0029): freshness of the stored
/// payloads, the stored-vs-render thumbnail decision, the render
/// fallbacks the Quick Look extensions use, and the appearance/title
/// derivations.
@Suite
struct PackagePreviewsTests {
    private func fixtureModel() -> MapModel {
        var model = MapModel.emptyDocument()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ id: String, _ text: String, parent: String? = nil) {
            var node = Node(id: id, title: NodeTitle(text: text), created: date, modified: date)
            node.parent = parent
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
            model.nodes[id] = node
        }
        add("root", "Trip")
        add("alpha", "Pack", parent: "root")
        add("alpha-child", "Passport", parent: "alpha")
        add("beta", "Budget", parent: "root")
        return model
    }

    /// Writes a package with the model and, when asked, stored preview
    /// payloads with chosen modification dates. Returns the package URL.
    private func writePackage(
        model: MapModel,
        stored: (thumbnail: Bool, preview: Bool)? = nil,
        previewNewerThanMap: Bool = true
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-\(UUID().uuidString).arbor")
        try ArborPackage.write(
            model,
            meta: PackageMeta(
                formatVersion: ArborFormat.formatVersion, appVersion: "0.1.0-test", docID: model.docID
            ),
            to: url)
        guard let stored else { return url }
        let quickLook = url.appendingPathComponent("QuickLook")
        try FileManager.default.createDirectory(
            at: quickLook, withIntermediateDirectories: true)
        let mapDate = modificationDate(
            of: url.appendingPathComponent(ArborPackage.mapEntryName))
        var previewDate = mapDate
        if !previewNewerThanMap {
            previewDate = mapDate.addingTimeInterval(-60)
        }
        if stored.thumbnail {
            let png = try ArborPreviewRenderer.renderThumbnail(
                model: model, variant: .light, longEdgePixels: 512)
            try png.write(to: quickLook.appendingPathComponent("Thumbnail.png"))
        }
        if stored.preview {
            let pdf = try ArborPreviewRenderer.renderPreviewPDF(model: model, variant: .light)
            try pdf.write(to: quickLook.appendingPathComponent("Preview.pdf"))
        }
        if stored.thumbnail {
            setModificationDate(
                of: quickLook.appendingPathComponent("Thumbnail.png"), to: previewDate)
        }
        if stored.preview {
            setModificationDate(
                of: quickLook.appendingPathComponent("Preview.pdf"), to: previewDate)
        }
        return url
    }

    private func modificationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            ?? Date.distantPast
    }

    private func setModificationDate(of url: URL, to date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: freshness

    @Test func freshnessRule() {
        let map = Date(timeIntervalSince1970: 1_000)
        #expect(!PackagePreviews.isFresh(nil, relativeTo: map))
        #expect(!PackagePreviews.isFresh(Date(timeIntervalSince1970: 1_000), relativeTo: nil))
        #expect(PackagePreviews.isFresh(map, relativeTo: map))
        #expect(PackagePreviews.isFresh(map.addingTimeInterval(1), relativeTo: map))
        #expect(!PackagePreviews.isFresh(map.addingTimeInterval(-1), relativeTo: map))
    }

    @Test func payloadReadsFreshAndStaleFiles() throws {
        let model = fixtureModel()
        // Nothing stored: both arms read as missing + stale.
        let bare = try writePackage(model: model)
        let barePayload = PackagePreviews.readPayload(at: bare)
        #expect(barePayload.thumbnailPNG == nil)
        #expect(barePayload.previewPDF == nil)
        #expect(!barePayload.thumbnailFresh)
        #expect(!barePayload.previewFresh)

        // Stored by the same save that wrote map.json: fresh.
        let fresh = try writePackage(
            model: model, stored: (thumbnail: true, preview: true), previewNewerThanMap: true)
        let freshPayload = PackagePreviews.readPayload(at: fresh)
        #expect(freshPayload.thumbnailPNG != nil)
        #expect(freshPayload.previewPDF != nil)
        #expect(freshPayload.thumbnailFresh)
        #expect(freshPayload.previewFresh)

        // Stored by an EARLIER save than the current map.json: stale.
        let stale = try writePackage(
            model: model, stored: (thumbnail: true, preview: true), previewNewerThanMap: false)
        let stalePayload = PackagePreviews.readPayload(at: stale)
        #expect(stalePayload.thumbnailPNG != nil)
        #expect(!stalePayload.thumbnailFresh)
        #expect(!stalePayload.previewFresh)

        // A missing package reads as everything-stale, never crashes.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope.arbor")
        let missingPayload = PackagePreviews.readPayload(at: missing)
        #expect(missingPayload.thumbnailPNG == nil)
        #expect(!missingPayload.thumbnailFresh)
    }

    // MARK: the stored-vs-render decision

    @Test func thumbnailSourceDecision() {
        // A fresh stored 512 px thumbnail covers ordinary Finder sizes.
        #expect(
            PackagePreviews.thumbnailSource(storedFresh: true, requestedLongEdgePixels: 128)
                == .stored)
        #expect(
            PackagePreviews.thumbnailSource(storedFresh: true, requestedLongEdgePixels: 512)
                == .stored)
        // Bigger than the stored raster, or stale/missing: re-render at
        // the requested size.
        #expect(
            PackagePreviews.thumbnailSource(storedFresh: true, requestedLongEdgePixels: 1024)
                == .render(1024))
        #expect(
            PackagePreviews.thumbnailSource(storedFresh: false, requestedLongEdgePixels: 128)
                == .render(128))
        #expect(
            PackagePreviews.thumbnailSource(storedFresh: false, requestedLongEdgePixels: 0)
                == .render(1))
    }

    // MARK: the image the Quick Look extension returns

    @Test func thumbnailImageUsesStoredWhenFresh() throws {
        let model = fixtureModel()
        let url = try writePackage(
            model: model, stored: (thumbnail: true, preview: false))
        // A small request downscales the stored 512 px PNG.
        let image = ArborPreviewRenderer.thumbnailImage(
            at: url, maximumPixelSize: CGSize(width: 128, height: 128), scale: 2)
        #expect(image != nil)
        #expect(max(image!.width, image!.height) <= 256)
    }

    @Test func thumbnailImageRendersWhenMissingOrStale() throws {
        let model = fixtureModel()
        // No stored payload, but a valid map.json: renders on the fly.
        let bare = try writePackage(model: model)
        let rendered = ArborPreviewRenderer.thumbnailImage(
            at: bare, maximumPixelSize: CGSize(width: 640, height: 640), scale: 1)
        #expect(rendered != nil)
        #expect(max(rendered!.width, rendered!.height) <= 640)

        // A stale stored thumbnail (older save than map.json) also
        // re-renders rather than showing outdated content.
        let stale = try writePackage(
            model: model, stored: (thumbnail: true, preview: false), previewNewerThanMap: false)
        let refreshed = ArborPreviewRenderer.thumbnailImage(
            at: stale, maximumPixelSize: CGSize(width: 64, height: 64), scale: 1)
        #expect(refreshed != nil)

        // A package with no map.json at all cannot render.
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-\(UUID().uuidString).arbor")
        try FileManager.default.createDirectory(
            at: broken, withIntermediateDirectories: true)
        #expect(
            ArborPreviewRenderer.thumbnailImage(
                at: broken, maximumPixelSize: CGSize(width: 128, height: 128), scale: 1) == nil)
    }

    @Test func previewPDFPrefersFreshStoredFile() throws {
        let model = fixtureModel()
        let fresh = try writePackage(
            model: model, stored: (thumbnail: false, preview: true), previewNewerThanMap: true)
        let stored = try #require(ArborPreviewRenderer.previewPDF(at: fresh))
        // The stored file is the PDFExporter's own output: a 1-page
        // whole-map PDF.
        #expect(PDFDocument(data: stored)?.pageCount == 1)

        // Stale or missing: re-rendered from map.json.
        let stale = try writePackage(
            model: model, stored: (thumbnail: false, preview: true), previewNewerThanMap: false)
        #expect(ArborPreviewRenderer.previewPDF(at: stale) != nil)
        let bare = try writePackage(model: model)
        #expect(ArborPreviewRenderer.previewPDF(at: bare) != nil)
    }

    // MARK: payloads the save path writes

    @Test func renderedPayloadsMatchTheSaveContract() throws {
        let model = fixtureModel()
        let payloads = try ArborPreviewRenderer.renderPayloads(model: model, variant: .light)
        // Thumbnail: PNG, 512 px on the long edge.
        let source = try #require(
            CGImageSourceCreateWithData(payloads.thumbnail as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == 512)
        // Preview: a 1-page vector PDF of the whole map.
        let document = try #require(PDFDocument(data: payloads.preview))
        #expect(document.pageCount == 1)
    }

    @Test func titleAndVariantDerivations() {
        var model = fixtureModel()
        #expect(ArborPreviewRenderer.displayTitle(for: model) == "Trip")
        model.title = "Holiday 2026"
        #expect(ArborPreviewRenderer.displayTitle(for: model) == "Holiday 2026")
        model.title = nil
        // The root's first line, trimmed.
        #expect(ArborPreviewRenderer.displayTitle(for: model) == "Trip")

        // Appearance: an explicit dark document renders dark in the
        // extensions; everything else light (no window to follow).
        #expect(ArborPreviewRenderer.effectiveVariant(for: model) == .light)
        model.appearance = .dark
        #expect(ArborPreviewRenderer.effectiveVariant(for: model) == .dark)
        model.appearance = .light
        #expect(ArborPreviewRenderer.effectiveVariant(for: model) == .light)

        var empty = MapModel.emptyDocument()
        empty.roots = []
        #expect(ArborPreviewRenderer.displayTitle(for: empty) == "Map")
    }
}
