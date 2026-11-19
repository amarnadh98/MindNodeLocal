import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import MapStudy
import Testing

@testable import CanvasKit

/// M3 media content (F-CNT-2/3/5/8, F-TAG-3): the image block as a
/// layout input, the marker row, the sticker catalog's contract, the
/// media provider seam (revision-driven re-raster), the filter engine
/// and hide-mode pruning.
@MainActor
struct MediaDecorationTests {
    private func contentModel() -> MapModel {
        let date = Date(timeIntervalSince1970: 1)
        func node(_ id: String, parent: String?) -> Node {
            Node(id: id, parent: parent, title: NodeTitle(text: id), created: date, modified: date)
        }

        var model = MapModel.emptyDocument(docID: "media")
        model.nodes["root"] = node("root", parent: nil)
        model.nodes["a"] = node("a", parent: "root")
        model.nodes["b"] = node("b", parent: "root")
        model.nodes["a1"] = node("a1", parent: "a")
        model.nodes["root"]?.children = ["a", "b"]
        model.nodes["a"]?.children = ["a1"]
        model.roots = ["root"]
        return model
    }

    private func style() -> ResolvedNodeStyle {
        BuiltInThemes.theme(id: BuiltInThemes.defaultID)
            .resolvedStyle(level: 0, level1Index: 0, variant: .light)
    }

    // MARK: content size (F-CNT-2)

    @Test func imageBlockGrowsTheContentSize() {
        let base = CGSize(width: 100, height: 20)
        let above = NodeDecorations(
            image: ImageBlock(asset: "x.png", size: CGSize(width: 120, height: 60), placement: .above))
        let sizeAbove = NodeRenderer.contentSize(textSize: base, style: style(), decorations: above)
        #expect(sizeAbove.width == 120)
        #expect(sizeAbove.height == 20 + NodeDecorationMetrics.imageGap + 60)

        let left = NodeDecorations(
            image: ImageBlock(asset: "x.png", size: CGSize(width: 40, height: 30), placement: .left))
        let sizeLeft = NodeRenderer.contentSize(textSize: base, style: style(), decorations: left)
        #expect(sizeLeft.width == 100 + NodeDecorationMetrics.imageGap + 40)
        #expect(sizeLeft.height == 30)
    }

    @Test func markersGrowTheLeadingColumn() {
        let base = CGSize(width: 100, height: 20)
        let decorations = NodeDecorations(
            task: .checkbox(done: false),
            markers: (0..<3).map { MarkerBadge(token: "sticker:priority-\($0 + 1)") })
        let size = NodeRenderer.contentSize(textSize: base, style: style(), decorations: decorations)
        let expected =
            NodeDecorationMetrics.checkboxSize + NodeDecorationMetrics.leadingGap
            + NodeDecorationMetrics.markerRowWidth(3)
        #expect(size.width == expected + 100)
        #expect(size.height == 20)
    }

    @Test func decorationLayoutPlacesImageMarkersAndBadges() {
        let decorations = NodeDecorations(
            task: .checkbox(done: false),
            tags: [TagPill(name: "exam", colorHex: "#E5484D")],
            markers: [MarkerBadge(token: "sticker:priority-1"), MarkerBadge(token: "emoji:💡")],
            image: ImageBlock(asset: "x.png", size: CGSize(width: 80, height: 40), placement: .above),
            source: "https://example.com",
            attachmentCount: 2)
        let layout = NodeDecorationLayout.layout(
            style: style(), decorations: decorations,
            contentRect: CGRect(x: 0, y: 0, width: 140, height: 92))

        #expect(layout.imageRect?.width == 80)
        #expect(layout.imageRect?.height == 40)
        #expect(layout.imageRect?.minY == 0)
        // The title row sits BELOW the image band.
        #expect(layout.titleRow.minY >= layout.imageRect!.maxY)
        #expect(layout.markerRowRect != nil)
        // The marker row follows the checkbox column.
        #expect(layout.markerRowRect!.minX >= layout.leadingRect!.maxX)
        // The badges live at the trailing edge, the chip innermost.
        #expect(layout.sourceBadgeRect!.maxX < layout.attachmentBadgeRect!.maxX)
        // Nothing overlaps the pill row.
        #expect(layout.titleRow.maxY <= layout.tagRowRect!.minY)
    }

    // MARK: the sticker catalog (F-CNT-3)

    @Test func stickerCatalogHasAtLeast120Originals() {
        #expect(Stickers.all.count >= 120, "SPEC asks for ~120 original stickers")
        #expect(Set(Stickers.all.map(\.id)).count == Stickers.all.count, "ids are unique")
        #expect(
            Set(Stickers.all.map(\.category)) == Set(Stickers.categoryOrder),
            "every category the picker shows has stickers")
    }

    @Test func stickerCatalogCoversSPECsNamedFamilies() {
        // The families SPEC §5.4 names explicitly.
        for index in 1...5 {
            #expect(Stickers.sticker(id: "priority-\(index)") != nil)
        }
        for index in 0...8 {
            #expect(Stickers.sticker(id: "progress-\(index)") != nil)
        }
        #expect(Stickers.sticker(id: "flag-red") != nil)
        #expect(Stickers.sticker(id: "star-full") != nil)
        #expect(Stickers.sticker(id: "arrow-right") != nil)
        #expect(Stickers.sticker(id: "face-happy") != nil)
        #expect(Stickers.sticker(id: "check") != nil)
        #expect(Stickers.sticker(id: "cross") != nil)
        // The learning markers: 💡 idea, ❓ question, ⚠️ pitfall, 📌 key,
        // 🔁 review.
        #expect(Stickers.sticker(id: "idea") != nil)
        #expect(Stickers.sticker(id: "question") != nil)
        #expect(Stickers.sticker(id: "pitfall") != nil)
        #expect(Stickers.sticker(id: "key") != nil)
        #expect(Stickers.sticker(id: "review") != nil)
    }

    @Test func stickerPathsLiveInTheUnitBoxAndRaster() throws {
        for sticker in Stickers.all {
            let box = sticker.path.boundingBox
            #expect(box.width > 0 && box.height > 0, "\(sticker.id) has an empty path")
            #expect(
                box.minX >= -1 && box.minY >= -1 && box.maxX <= 26 && box.maxY <= 26,
                "\(sticker.id) stays in the 24×24 unit box")
        }

        // A raster smoke: every sticker draws without crashing and
        // paints at least one pixel.
        for sticker in Stickers.all {
            let context = CGContext(
                data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.clear(CGRect(x: 0, y: 0, width: 48, height: 48))
            NodeRenderer.drawSticker(
                sticker, in: CGRect(x: 0, y: 0, width: 48, height: 48),
                color: CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1), in: context)
            let image = try #require(context.makeImage())
            #expect(!isFullyTransparent(image), "\(sticker.id) rasters to something")
        }
    }

    /// A cheap "did we paint" check: the alpha channel of any pixel.
    private func isFullyTransparent(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return true
        }
        let byteCount = CFDataGetLength(data)
        for index in 0..<byteCount where bytes[index] != 0 {
            return false
        }
        return true
    }

    // MARK: scene integration

    @Test func sceneCarriesMarkersImageAndBadges() throws {
        var model = contentModel()
        model.nodes["a"]?.markers = ["sf:star.fill", "emoji:💡", "sticker:priority-2"]
        model.nodes["a"]?.image = NodeImage(asset: "aabb.png", size: [80, 40], placement: .below)
        model.nodes["a"]?.source = SourceRef(url: "https://example.com/p", page: 12)
        model.nodes["b"]?.attachments = [Attachment(asset: "ccdd.pdf", name: "Paper.pdf")]

        let scene = SceneGeometry.build(model: model, variant: .light, measurer: TextMeasurer())
        let imageNode = try #require(scene.nodes["a"])
        #expect(imageNode.decorations?.markers.count == 3)
        #expect(imageNode.decorations?.image?.asset == "aabb.png")
        #expect(imageNode.decorations?.source == "https://example.com/p")
        // The image is a layout input: the decorated node is the taller
        // and the wider one (marker row included).
        let attachmentNode = try #require(scene.nodes["b"])
        #expect(attachmentNode.decorations?.attachmentCount == 1)
        #expect(imageNode.frame.height > attachmentNode.frame.height)
        #expect(imageNode.frame.width > attachmentNode.frame.width)
    }

    @Test func mediaProviderResolvesImagesMarkersAndMath() throws {
        var model = contentModel()
        model.nodes["a"]?.image = NodeImage(asset: "aabb.png", size: [60, 30], placement: .above)
        model.nodes["a"]?.markers = ["sf:star.fill"]
        model.nodes["b"]?.math = true
        model.nodes["b"]?.title = NodeTitle(text: "x^2")

        let cache = SceneBuildCache(variant: .light)
        let thumb = try #require(makeSolidImage())
        let glyph = MathGlyph(size: CGSize(width: 42, height: 14)) { _, _ in }
        cache.media = SceneMediaProvider(
            image: { asset in asset == "aabb.png" ? thumb : nil },
            marker: { token, _ in token == "sf:star.fill" ? thumb : nil },
            math: { latex, _, _ in latex == "x^2" ? glyph : nil },
            revision: 3)
        _ = SceneGeometry.build(model: model, cache: cache, variant: .light, measurer: TextMeasurer())

        // A math node measured through the glyph, not the source text.
        let measurer = TextMeasurer()
        let textWidth = measurer.nodeTitleSize(
            model.nodes["b"]!.title, font: style().font, maxWidth: 280
        ).width
        #expect(abs(textWidth - 42) > 0.5, "the glyph size and the plain-text width differ")

        // The same cache reuses the stored size: the math node is
        // exactly 42 (glyph) + padding wide.
        let scene = SceneGeometry.update(
            model: model, cache: cache, variant: .light, measurer: measurer, dirty: [])
        let mathNode = try #require(scene.nodes["b"])
        #expect(abs(mathNode.frame.width - (42 + mathNode.style.paddingWidth * 2)) < 0.001)

        let imageNode = try #require(scene.nodes["a"])
        #expect(imageNode.media?.image === thumb)
        #expect(imageNode.media?.markerImages["sf:star.fill"] === thumb)
        #expect(imageNode.media?.revision == 3)
        // A revision bump re-rasters: the differ sees content change.
        cache.media?.revision = 4
        let bumped = SceneGeometry.update(
            model: model, cache: cache, variant: .light, measurer: measurer, dirty: [])
        let diff = SceneDiffer.diff(old: scene, new: bumped)
        #expect(diff.nodes["a"] != nil, "the image node re-rasters after a revision bump")
        #expect(diff.nodes["root"] == nil, "the plain node is untouched")
    }

    @Test func missingMediaFallsBack() throws {
        var model = contentModel()
        model.nodes["a"]?.math = true
        // No provider: the source text measures and draws (F-CNT-5).
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: TextMeasurer())
        let mathNode = try #require(scene.nodes["a"])
        #expect(mathNode.decorations?.math == true)
        #expect(mathNode.media == nil)
        #expect(mathNode.frame.width > mathNode.style.paddingWidth * 2)
    }

    // MARK: hide-mode pruning (F-TAG-3)

    @Test func prunedIDsLeaveTheScene() {
        var model = contentModel()
        model.nodes["a1"]?.note = "note"
        let filter = NodeFilter(hasNote: true)
        let hidden = FilterEngine.hiddenIDs(
            model: model, filter: filter, mastery: nil, now: Date(timeIntervalSince1970: 0))
        // a1 matches; its ancestors (a, root) stay visible.
        #expect(!hidden.contains("a1"))
        #expect(!hidden.contains("a"))
        #expect(!hidden.contains("root"))
        #expect(hidden.contains("b"))

        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: TextMeasurer(), prunedIDs: hidden)
        #expect(scene.nodes["b"] == nil)
        #expect(scene.nodes["a1"] != nil)
        #expect(scene.nodes["root"] != nil)
        // The branch to the pruned node is gone too.
        #expect(!scene.branches.contains { $0.childID == "b" })
    }

    // MARK: the filter engine (F-TAG-3)

    @Test func filterQueryRoundTrips() {
        let filter = NodeFilter(
            tagIDs: ["t1", "t2"], taskState: .open, hasNote: true, hasImage: false,
            nodeType: "concept", mastery: .forgotten, due: .overdue,
            text: "derivat")
        let parsed = NodeFilter(query: filter.query)
        #expect(parsed == filter)
        #expect(parsed.normalized.query == filter.query)
        // Unknown tokens read as text; nothing fails to load.
        let salvaged = NodeFilter(query: "free word junk:")
        #expect(salvaged.text == "free word junk:")
    }

    @Test func filterEngineMatchesEveryTermKind() throws {
        var model = contentModel()
        let date = Date(timeIntervalSince1970: 1)
        model.tags = [Tag(id: "t1", name: "exam", color: "#E5484D")]
        model.nodes["a"]?.tags = ["t1"]
        model.nodes["a"]?.task = NodeTask(done: false, due: "2020-01-01")
        model.nodes["a"]?.note = "the derivative note"
        model.nodes["a"]?.type = "concept"
        model.nodes["b"]?.image = NodeImage(asset: "x.png", size: [10, 10])
        model.nodes["b"]?.attachments = [Attachment(asset: "y.pdf", name: "Y.pdf")]
        model.nodes["a1"]?.task = NodeTask(done: true)
        // a has a reviewed card: strong mastery.
        model.nodes["a"]?.study = NodeStudy(
            card: .on, fsrs: FSRSState(due: date, stability: 99, difficulty: 1, reps: 5, state: .review))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mastery = MasteryReport.compute(map: model, now: now)
        let node = try #require(model.nodes["a"])
        func matchesA(_ filter: NodeFilter) -> Bool {
            FilterEngine.matches(filter, nodeID: "a", node: node, mastery: mastery, now: now)
        }

        #expect(matchesA(NodeFilter(tagIDs: ["t1"])))
        #expect(!matchesA(NodeFilter(tagIDs: ["nope"])))
        #expect(matchesA(NodeFilter(taskState: .open)))
        #expect(!matchesA(NodeFilter(taskState: .done)))
        #expect(matchesA(NodeFilter(hasNote: true)))
        #expect(!matchesA(NodeFilter(hasImage: true)))
        #expect(matchesA(NodeFilter(nodeType: "Concept")))
        #expect(matchesA(NodeFilter(due: .overdue)))
        #expect(matchesA(NodeFilter(text: "Derivative")))
        #expect(!matchesA(NodeFilter(text: "nomatch")))
        // The card was "reviewed" in 1970 and never again: retrievability
        // has decayed to ~0 → the forgotten bucket (F-STD-6 vocabulary).
        #expect(matchesA(NodeFilter(mastery: .forgotten)))
        #expect(!matchesA(NodeFilter(mastery: .strong)))

        // The empty filter matches everything.
        #expect(
            FilterEngine.matchingIDs(model: model, filter: NodeFilter(), mastery: mastery, now: now)
                .count == model.nodes.count)
    }

    @Test func hiddenIDsKeepAncestorsOfMatches() {
        var model = contentModel()
        model.nodes["a1"]?.note = "x"
        let hidden = FilterEngine.hiddenIDs(
            model: model, filter: NodeFilter(hasNote: true), mastery: nil,
            now: Date(timeIntervalSince1970: 0))
        #expect(hidden == ["b"])
    }

    // MARK: hit-testing (F-CNT-2/3/7/8)

    @Test func decorationHitsCoverMarkersSourceAttachmentAndResize() throws {
        var model = contentModel()
        model.nodes["a"]?.markers = ["sticker:priority-2", "emoji:💡"]
        model.nodes["a"]?.source = SourceRef(url: "https://example.com")
        model.nodes["a"]?.attachments = [Attachment(asset: "y.pdf", name: "Y.pdf")]
        model.nodes["a"]?.image = NodeImage(asset: "x.png", size: [80, 40], placement: .below)

        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: TextMeasurer())
        view.scene = scene
        view.dragModel = model
        view.camera = Camera(origin: CGPoint(x: -200, y: -200), scale: 1)

        let node = try #require(scene.nodes["a"])
        let layout = NodeRenderer.decorationLayout(
            style: node.style, decorations: node.decorations,
            frame: CGRect(origin: .zero, size: node.frame.size))
        func hitPoint(_ local: CGPoint) -> CGPoint {
            CGPoint(x: node.frame.minX + local.x + 200, y: node.frame.minY + local.y + 200)
        }

        let markerRect = try #require(layout.markerRowRect)
        let markerPoint = hitPoint(
            CGPoint(x: markerRect.minX + NodeDecorationMetrics.markerGap + 7, y: markerRect.midY))
        guard case .marker(let id, let token)? = view.decorationHit(at: markerPoint) else {
            Issue.record("the first marker did not hit")
            return
        }
        #expect(id == "a")
        #expect(token == "sticker:priority-2")

        let sourceRect = try #require(layout.sourceBadgeRect)
        guard case .sourceBadge(let sourceID)? = view.decorationHit(at: hitPoint(sourceRect.center)) else {
            Issue.record("the source chip did not hit")
            return
        }
        #expect(sourceID == "a")

        let attachmentRect = try #require(layout.attachmentBadgeRect)
        guard case .attachmentBadge(let attachID)? = view.decorationHit(at: hitPoint(attachmentRect.center)) else {
            Issue.record("the attachment badge did not hit")
            return
        }
        #expect(attachID == "a")

        let imageRect = try #require(layout.imageRect)
        let corner = hitPoint(CGPoint(x: imageRect.maxX - 1, y: imageRect.maxY - 1))
        guard case .imageResize(let resizeID)? = view.decorationHit(at: corner) else {
            Issue.record("the resize corner did not hit")
            return
        }
        #expect(resizeID == "a")

        // The tooltips read the model.
        #expect(view.decorationHoverText(at: hitPoint(sourceRect.center))?.contains("example.com") == true)
        #expect(view.decorationHoverText(at: hitPoint(attachmentRect.center)) == "Y.pdf")
        #expect(view.decorationHoverText(at: markerPoint)?.hasPrefix("→") == true)
    }

    @Test func imageResizeDragCommitsOnce() throws {
        var model = contentModel()
        model.nodes["a"]?.image = NodeImage(asset: "x.png", size: [80, 40], placement: .below)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: TextMeasurer())
        view.scene = scene
        view.dragModel = model
        view.camera = Camera(origin: CGPoint(x: -200, y: -200), scale: 1)

        var committed: [(String, CGSize)] = []
        view.onResizeImage = { id, size in committed.append((id, size)) }

        let node = try #require(scene.nodes["a"])
        let layout = NodeRenderer.decorationLayout(
            style: node.style, decorations: node.decorations,
            frame: CGRect(origin: .zero, size: node.frame.size))
        let imageRect = try #require(layout.imageRect)
        let corner = CGPoint(
            x: node.frame.minX + imageRect.maxX + 200,
            y: node.frame.minY + imageRect.maxY + 200)

        // The drag: right +40 view points, aspect locked (scale 1).
        view.beginImageResize(id: "a", at: corner, aspectLocked: true)
        #expect(view.isResizingImage)
        view.handleImageResizeDragged(to: CGPoint(x: corner.x + 40, y: corner.y + 20))
        view.handleImageResizeDragged(to: CGPoint(x: corner.x + 40, y: corner.y + 20), ending: true)

        #expect(!view.isResizingImage)
        #expect(committed.count == 1)
        #expect(committed[0].0 == "a")
        // 40 model points wider (80 → 120); aspect keeps 60 tall.
        #expect(abs(committed[0].1.width - 120) < 0.001)
        #expect(abs(committed[0].1.height - 60) < 0.001)

        // Esc mid-drag cancels without a command.
        view.beginImageResize(id: "a", at: corner, aspectLocked: true)
        #expect(view.exitHighlightIfActive() == true)
        #expect(committed.count == 1)
    }

    // MARK: helpers

    private func makeSolidImage() -> CGImage? {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context?.makeImage()
    }
}

extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
