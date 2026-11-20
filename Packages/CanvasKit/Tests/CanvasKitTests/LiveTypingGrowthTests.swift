import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// Live typing growth (F-EDT-8) through the REAL replace-edit flow
/// (F-EDT-2: typing over a selected node, exactly the user report): the
/// node box, its selection ring and the editing overlay must track
/// every keystroke from the very first one — nothing defers to the
/// Return commit. Regression: the prefill keystroke used to publish no
/// draft, so the box and ring kept the replaced title's geometry while
/// the typed text ran past them.
@MainActor
struct LiveTypingGrowthTests {
    private func makeHostedCanvas(
        rootText: String
    ) throws -> (canvas: CanvasView, window: NSWindow) {
        let model = sceneModel(rootText: rootText)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let store = MapStore(model: model, undoManager: manager)
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        let cache = SceneBuildCache(variant: .light, spacing: .default)
        canvas.dragModel = model
        // DocumentWindowController.updateDraftScene's wiring: every
        // draft rebuilds the scene through the incremental path.
        canvas.onEditingDraftChange = { id, title in
            canvas.scene = SceneGeometry.update(
                model: store.model, cache: cache, variant: .light,
                measurer: SceneRenderer.sharedMeasurer, dirty: [id],
                editingTitle: (id, title))
        }
        // handleEditingCommit's wiring: one editText command, then the
        // scene rebuild without the draft.
        canvas.onEditingCommit = { id, title, _ in
            if store.model.nodes[id]?.title != title {
                try? store.perform(.editText(id: id, title: title))
            }
            store.closeEditSession()
            canvas.scene = SceneGeometry.update(
                model: store.model, cache: cache, variant: .light,
                measurer: SceneRenderer.sharedMeasurer, dirty: [id])
        }
        canvas.scene = SceneGeometry.build(
            model: store.model, cache: cache, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        canvas.zoomToFit()
        canvas.displayIfNeeded()
        return (canvas, window)
    }

    @Test func typingOverASelectionGrowsTheBoxAndRingFromTheFirstKeystroke() throws {
        let (canvas, window) = try makeHostedCanvas(rootText: "An existing title")
        defer { window.orderOut(nil) }
        let rootID = "root"

        let oldWidth = try #require(canvas.scene?.nodes[rootID]?.frame.width)
        canvas.setSelection([rootID])

        // F-EDT-2: the first typed character replaces the title.
        canvas.beginEditing(nodeID: rootID, prefill: "1")

        // The prefill draft must publish with the same keystroke — the
        // host's draft count is the observable wiring.
        let draftText = try #require(canvas.editingDraftTitle?.text)
        #expect(draftText == "1")

        // The scene, the node layer and the ring must already measure
        // the prefill text — a from-scratch build is the oracle.
        let oracle = SceneGeometry.build(
            model: sceneModel(rootText: "An existing title"), variant: .light,
            measurer: SceneRenderer.sharedMeasurer,
            editingTitle: (rootID, NodeTitle(text: "1")))
        let expectedWidth = try #require(oracle.nodes[rootID]?.frame.width)
        #expect(expectedWidth < oldWidth, "the oracle must actually shrink the node")
        #expect(
            abs((canvas.scene?.nodes[rootID]?.frame.width ?? -1) - expectedWidth) < 0.001,
            "the scene lags the first keystroke")
        #expect(
            abs((canvas.layerTree.nodeLayers[rootID]?.bounds.width ?? -1) - expectedWidth) < 0.5,
            "the node layer lags the first keystroke")
        let ring = try #require(canvas.layerTree.selectionRingBounds(rootID))
        #expect(
            abs(ring.width - (expectedWidth + 6)) < 1.5,
            "the selection ring lags the first keystroke")

        // The rendered pixels agree from this very keystroke: the box
        // fill spans the new frame's edge, and the stale old-title box
        // is gone — the band past the new width shows background, not
        // fill.
        try expectFillAtRightEdge(
            canvas: canvas, nodeID: rootID, width: expectedWidth,
            staleWidth: oldWidth)

        // Every later keystroke keeps the lockstep (F-EDT-8): the box
        // never waits for the commit.
        for character in "st thought live typing" {
            canvas.nodeTextEditor.insertText(String(character))
            let typed = try #require(canvas.editingDraftTitle?.text)
            let built = SceneGeometry.build(
                model: sceneModel(rootText: "An existing title"), variant: .light,
                measurer: SceneRenderer.sharedMeasurer,
                editingTitle: (rootID, NodeTitle(text: typed)))
            let target = try #require(built.nodes[rootID]?.frame.width)
            #expect(
                abs((canvas.scene?.nodes[rootID]?.frame.width ?? -1) - target) < 0.001)
            #expect(
                abs((canvas.layerTree.nodeLayers[rootID]?.bounds.width ?? -1) - target) < 0.5)
        }

        // Nothing animates mid-session: typing must never ride a CA
        // action (no crossfade, no spring).
        #expect((canvas.layerTree.nodeLayers[rootID]?.animationKeys() ?? []).isEmpty == true)
    }

    @Test func committingUnchangedTextDoesNotResizeOrJumpTheNode() throws {
        let (canvas, window) = try makeHostedCanvas(rootText: "An existing title")
        defer { window.orderOut(nil) }
        let rootID = "root"
        canvas.setSelection([rootID])
        canvas.beginEditing(nodeID: rootID, prefill: "1")
        canvas.nodeTextEditor.insertText("st thought")

        // The pre-commit geometry …
        let draftFrame = try #require(canvas.scene?.nodes[rootID]?.frame)
        let style = try #require(canvas.scene?.nodes[rootID]?.style)
        // … is exactly what the committed model renders: the commit
        // must not resize, re-layout or re-style anything.
        canvas.commitEditing()
        let committedFrame = try #require(canvas.scene?.nodes[rootID]?.frame)
        let committedStyle = try #require(canvas.scene?.nodes[rootID]?.style)
        #expect(draftFrame == committedFrame)
        #expect(SceneDiffer.sameStyle(style, committedStyle))
        // No animation rides the layer after the commit either — the
        // title reveal must snap, not crossfade.
        #expect((canvas.layerTree.nodeLayers[rootID]?.animationKeys() ?? []).isEmpty == true)
    }

    /// Samples the rendered pixels around the right edge of a frame of
    /// `width` (in model space): inside the edge must be the node's
    /// fill, the band just past it must be the canvas background — a
    /// stale, wider box (the replaced title's) would leave fill there.
    private func expectFillAtRightEdge(
        canvas: CanvasView, nodeID: String, width: CGFloat, staleWidth: CGFloat
    ) throws {
        let node = try #require(canvas.scene?.nodes[nodeID])
        let origin = node.frame.origin
        let frame = CGRect(
            origin: origin, size: CGSize(width: width, height: node.frame.height))
        guard staleWidth > width + 12 else {
            // The pixel band needs room; the model assertions already
            // cover this size class.
            return
        }
        let fill = try #require(node.style.fillColor)
        // Sample off the node's vertical center: the branch connectors
        // exit there, and the ring's corners curve away from this row.
        let inside = canvas.camera.screenPoint(
            for: CGPoint(x: frame.maxX - 6, y: frame.midY - 14))
        let past = canvas.camera.screenPoint(
            for: CGPoint(x: frame.maxX + 5, y: frame.minY + 7))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            Issue.record("no bitmap for cacheDisplay")
            return
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let insideSample = bitmap.colorAt(
            x: Int(inside.x), y: Int(600 - inside.y))?.usingColorSpace(.deviceRGB)
        let pastSample = bitmap.colorAt(
            x: Int(past.x), y: Int(600 - past.y))?.usingColorSpace(.deviceRGB)
        let gotInside = insideSample?.cgColor.components ?? []
        let wantFill = fill.components ?? []
        #expect(gotInside.count >= 3 && wantFill.count >= 3)
        if gotInside.count >= 3, wantFill.count >= 3 {
            #expect(
                zip(gotInside, wantFill).allSatisfy { abs($0 - $1) < 0.02 },
                "the box fill does not span the first keystroke's frame edge")
        }
        let gotPast = pastSample?.cgColor.components ?? []
        let staleFill = fill.components ?? []
        #expect(gotPast.count >= 3 && staleFill.count >= 3)
        if gotPast.count >= 3, staleFill.count >= 3 {
            // The band just past the new width must NOT be the box fill:
            // a stale, wider box (the replaced title's) would show fill
            // there (background, ring or shadow tint are all fine).
            #expect(
                zip(gotPast, staleFill).contains { abs($0 - $1) > 0.04 },
                "the replaced title's stale box still shows past the new edge")
        }
    }
}
