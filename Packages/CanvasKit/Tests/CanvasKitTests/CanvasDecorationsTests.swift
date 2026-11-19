import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

/// M3 decorations end to end in the canvas: scene build (task marks,
/// badges, pills — sizes included), the raster key picking decoration
/// changes up, hit-testing the drawn regions, highlight dimming, hover
/// text and the VoiceOver row values (SPEC §11.6).
@MainActor
struct CanvasDecorationsTests {
    private func contentModel() -> MapModel {
        var model = MapModel.emptyDocument(docID: "decorated")
        let date = sceneDate
        for id in ["root", "chore", "done", "child"] {
            model.nodes[id] = Node(
                id: id, title: NodeTitle(text: id), created: date, modified: date)
        }
        model.roots = ["root"]
        model.nodes["root"]?.children = ["chore", "done"]
        model.nodes["chore"]?.parent = "root"
        model.nodes["done"]?.parent = "root"
        model.nodes["chore"]?.children = ["child"]
        model.nodes["child"]?.parent = "chore"

        model.nodes["chore"]?.task = NodeTask()
        model.nodes["child"]?.task = NodeTask(done: false)
        model.nodes["done"]?.task = NodeTask(done: true)
        model.nodes["done"]?.note = "Read this first\nsecond line"
        model.nodes["done"]?.link = "https://example.com"
        model.tags = [Tag(id: "t-exam", name: "exam", color: "#E5484D")]
        model.nodes["chore"]?.tags = ["t-exam"]
        return model
    }

    @Test func sceneBuildsDecorationsAndSizesGrow() {
        let model = contentModel()
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)

        // The parent sees a ring (1 of 2), the leaf and the done task
        // see checkboxes (F-TSK-1/2).
        guard case .progress(let completed, let total)? = scene.nodes["root"]?.decorations?.task else {
            Issue.record("root lacks a progress ring")
            return
        }
        #expect(completed == 1)
        #expect(total == 2)
        #expect(scene.nodes["chore"]?.decorations?.task == .progress(completed: 0, total: 1))
        #expect(scene.nodes["child"]?.decorations?.task == .checkbox(done: false))
        #expect(scene.nodes["done"]?.decorations?.task == .checkbox(done: true))
        #expect(scene.nodes["done"]?.decorations?.hasNote == true)
        #expect(scene.nodes["done"]?.decorations?.linkURL == "https://example.com")
        #expect(scene.nodes["chore"]?.decorations?.tags == [TagPill(name: "exam", colorHex: "#E5484D")])

        // Sizes: a decorated node is strictly larger than its plain
        // text would need, and the same title without decorations is
        // smaller.
        let plainScene = SceneGeometry.build(
            model: { () -> MapModel in
                var plain = contentModel()
                for id in ["chore", "done", "child"] {
                    plain.nodes[id]?.task = nil
                    plain.nodes[id]?.note = nil
                    plain.nodes[id]?.link = nil
                    plain.nodes[id]?.tags = nil
                }
                return plain
            }(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        #expect(
            scene.nodes["done"]!.frame.width > plainScene.nodes["done"]!.frame.width,
            "badges grew the frame")
        #expect(
            scene.nodes["chore"]!.frame.height > plainScene.nodes["chore"]!.frame.height,
            "pills grew the frame")

        // The pill toggle (View ▸ Show Tag Pills) drops only the pills.
        let noPills = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer, showsTagPills: false)
        #expect(noPills.nodes["chore"]?.decorations?.tags.isEmpty == true)
        #expect(noPills.nodes["chore"]?.decorations?.task != nil)
    }

    @Test func sceneBuildIsDeterministicWithDecorations() {
        let model = contentModel()
        let first = SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let second = SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        #expect(first.nodes.count == second.nodes.count)
        for (id, node) in first.nodes {
            #expect(node.frame == second.nodes[id]?.frame, "\(id) frame differs between builds")
            #expect(node.decorations == second.nodes[id]?.decorations, "\(id) decorations differ")
        }
    }

    @Test func rasterKeyChangesOnDecorationChange() throws {
        let model = contentModel()
        var scene = SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        let camera = Camera(origin: CGPoint(x: -200, y: -200), scale: 1)

        func apply(_ built: CanvasScene) {
            var context = ApplyContext(
                scene: built, grid: grid, camera: camera, viewport: CGSize(width: 900, height: 600))
            context.animated = false
            context.reduceMotion = true
            tree.apply(context)
        }

        apply(scene)
        let before = tree.nodeRasterKey("child")
        let doneKey = tree.nodeRasterKey("done")

        // A note appearing: the raster key must differ (re-raster),
        // while the untouched sibling's key is stable — only affected
        // nodes re-measure (the incremental path stays intact).
        var edited = model
        edited.nodes["child"]?.note = "a new note"
        scene = SceneGeometry.build(model: edited, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        apply(scene)
        #expect(tree.nodeRasterKey("child") != before, "a note change must re-raster")
        #expect(tree.nodeRasterKey("done") == doneKey, "no decoration change, no key change")

        // A tag assignment change re-rasters too.
        var retagged = model
        retagged.nodes["done"]?.tags = ["t-exam"]
        scene = SceneGeometry.build(model: retagged, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        apply(scene)
        #expect(tree.nodeRasterKey("done")?.decorations != doneKey?.decorations)
    }

    @Test func decorationHitLandsInTheDrawnRegions() {
        let model = contentModel()
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        view.scene = scene
        view.dragModel = model
        view.camera = Camera(origin: CGPoint(x: -200, y: -200), scale: 1)

        func hit(_ id: String, at local: CGPoint) -> DecorationHit? {
            guard let node = scene.nodes[id] else { return nil }
            let point = CGPoint(
                x: (node.frame.minX + local.x + 200), y: (node.frame.minY + local.y + 200))
            return view.decorationHit(at: point)
        }

        func layout(of id: String) -> NodeDecorationLayout {
            let node = scene.nodes[id]!
            return NodeRenderer.decorationLayout(
                style: node.style, decorations: node.decorations,
                frame: CGRect(origin: .zero, size: node.frame.size))
        }

        let doneLeading = layout(of: "done").leadingRect!
        #expect(
            hit("done", at: CGPoint(x: doneLeading.midX, y: doneLeading.midY)) == .checkbox(id: "done"))
        let doneLayout = layout(of: "done")
        let linkCenter = CGPoint(x: doneLayout.linkBadgeRect!.midX, y: doneLayout.linkBadgeRect!.midY)
        let noteCenter = CGPoint(x: doneLayout.noteBadgeRect!.midX, y: doneLayout.noteBadgeRect!.midY)
        #expect(hit("done", at: linkCenter) == .linkBadge(id: "done"))
        #expect(hit("done", at: noteCenter) == .noteBadge(id: "done"))
        // The title area is no decoration.
        let doneNode = scene.nodes["done"]!
        #expect(
            hit("done", at: CGPoint(x: doneLayout.titleRow.midX, y: doneLayout.titleRow.midY)) == nil)
        let childLeading = layout(of: "child").leadingRect!
        #expect(
            hit("child", at: CGPoint(x: childLeading.midX, y: childLeading.midY)) == .checkbox(id: "child"))
        let rootLayout = layout(of: "root")
        let ringCenter = CGPoint(x: rootLayout.leadingRect!.midX, y: rootLayout.leadingRect!.midY)
        #expect(hit("root", at: ringCenter) == .progressRing(id: "root"))
    }

    @Test func hoverTextForRingAndNote() {
        let model = contentModel()
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        view.scene = scene
        view.dragModel = model
        view.camera = Camera(origin: CGPoint(x: -200, y: -200), scale: 1)

        let root = scene.nodes["root"]!
        let layout = NodeRenderer.decorationLayout(
            style: root.style, decorations: root.decorations,
            frame: CGRect(origin: .zero, size: root.frame.size))
        let ringPoint = CGPoint(
            x: root.frame.minX + layout.leadingRect!.midX + 200,
            y: root.frame.minY + layout.leadingRect!.midY + 200)
        #expect(view.decorationHoverText(at: ringPoint) == "1 of 2 · 50%")

        let done = scene.nodes["done"]!
        let doneLayout = NodeRenderer.decorationLayout(
            style: done.style, decorations: done.decorations,
            frame: CGRect(origin: .zero, size: done.frame.size))
        let notePoint = CGPoint(
            x: done.frame.minX + doneLayout.noteBadgeRect!.midX + 200,
            y: done.frame.minY + doneLayout.noteBadgeRect!.midY + 200)
        #expect(view.decorationHoverText(at: notePoint) == "Read this first\nsecond line")

        // A long note previews at most three lines.
        var longModel = model
        longModel.nodes["done"]?.note = "one\ntwo\nthree\nfour"
        #expect(
            CanvasView.notePreview(of: "done", in: longModel) == "one\ntwo\nthree",
            "the hover preview caps at 3 lines")
        #expect(CanvasView.notePreview(of: "chore", in: longModel) == nil)
    }

    @Test func highlightModeDimsNonMatchingLayers() {
        let model = contentModel()
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        let camera = Camera(origin: CGPoint(x: -200, y: -200), scale: 1)
        var context = ApplyContext(
            scene: scene, grid: grid, camera: camera, viewport: CGSize(width: 900, height: 600))
        context.animated = false
        context.reduceMotion = true
        context.highlightedIDs = ["chore", "child"]
        tree.apply(context)

        #expect(tree.nodeLayerOpacity("chore") == 1)
        #expect(tree.nodeLayerOpacity("child") == 1)
        #expect(abs(tree.nodeLayerOpacity("done") - 0.25) < 0.001)
        #expect(abs(tree.nodeLayerOpacity("root") - 0.25) < 0.001)

        // Leaving highlight mode restores full opacity.
        context.highlightedIDs = nil
        tree.apply(context)
        #expect(tree.nodeLayerOpacity("done") == 1)
    }

    @Test func accessibilityRowsReadDecorations() throws {
        let model = contentModel()
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let value = CanvasAccessibilityElement.valueText(
            nodeID: "done", model: model, taskText: nil,
            decorations: scene.nodes["done"]?.decorations)
        #expect(value.contains("task, done"))
        #expect(value.contains("has note"))
        #expect(value.contains("has link"))

        let ring = CanvasAccessibilityElement.valueText(
            nodeID: "root", model: model, taskText: nil,
            decorations: scene.nodes["root"]?.decorations)
        #expect(ring.contains("task 1 of 2 done"))

        let tagged = CanvasAccessibilityElement.valueText(
            nodeID: "chore", model: model, taskText: nil,
            decorations: scene.nodes["chore"]?.decorations)
        #expect(tagged.contains("tags exam"))
        #expect(tagged.contains("task 0 of 1 done"))
    }
}
