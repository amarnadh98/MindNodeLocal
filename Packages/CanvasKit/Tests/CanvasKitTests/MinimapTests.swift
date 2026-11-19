import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// F-CAN-6's geometry, headless: the scene→minimap fit transform, the
/// viewport-rect mapping, click-point → camera-centre, and the auto-hide
/// predicate.
struct MinimapProjectionTests {
    @Test func fitScalesTheSceneIntoTheContentArea() throws {
        let projection = try #require(
            MinimapProjection.fit(
                sceneBounds: CGRect(x: -100, y: -25, width: 200, height: 50),
                in: CGSize(width: 200, height: 120),
                padding: 10))

        // The fit scale is limited by the tighter axis: the content area
        // is 180×100 points for a 200×50 scene → 0.9.
        #expect(abs(projection.scale - 0.9) < 1e-9)

        // The scene's centre lands on the minimap's centre.
        let centre = projection.point(for: CGPoint(x: 0, y: 0))
        #expect(abs(centre.x - 100) < 1e-9)
        #expect(abs(centre.y - 60) < 1e-9)

        // The mapped scene sits inside the padded content rect.
        let mapped = projection.rect(for: CGRect(x: -100, y: -25, width: 200, height: 50))
        #expect(mapped.minX >= 10 - 1e-9)
        #expect(mapped.maxX <= 190 + 1e-9)
        #expect(mapped.minY >= 10 - 1e-9)
        #expect(mapped.maxY <= 110 + 1e-9)
    }

    @Test func fitRejectsEmptyScenesAndTinyMinimaps() {
        #expect(
            MinimapProjection.fit(
                sceneBounds: .null, in: CGSize(width: 200, height: 120), padding: 10) == nil)
        #expect(
            MinimapProjection.fit(
                sceneBounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                in: CGSize(width: 15, height: 120),
                padding: 10) == nil)
    }

    @Test func projectionRoundTripsModelPoints() throws {
        let projection = try #require(
            MinimapProjection.fit(
                sceneBounds: CGRect(x: 0, y: 0, width: 1000, height: 500),
                in: CGSize(width: 180, height: 128),
                padding: 8))
        for x in stride(from: CGFloat(0), through: 1000, by: 250) {
            for y in stride(from: CGFloat(0), through: 500, by: 125) {
                let model = CGPoint(x: x, y: y)
                let roundTrip = projection.modelPoint(for: projection.point(for: model))
                #expect(abs(roundTrip.x - model.x) < 1e-6)
                #expect(abs(roundTrip.y - model.y) < 1e-6)
            }
        }
    }

    @Test func viewportRectMapsThroughTheProjection() throws {
        let camera = Camera(origin: CGPoint(x: 10, y: 5), scale: 2)
        let viewport = CGSize(width: 50, height: 40)
        let visible = camera.visibleRect(viewportSize: viewport)
        #expect(visible == CGRect(x: 10, y: 5, width: 25, height: 20))

        let projection = try #require(
            MinimapProjection.fit(
                sceneBounds: CGRect(x: 0, y: 0, width: 100, height: 80),
                in: CGSize(width: 180, height: 128),
                padding: 8))
        let rect = projection.rect(for: visible)
        #expect(rect.origin == projection.point(for: visible.origin))
        #expect(rect.size == CGSize(width: 25 * projection.scale, height: 20 * projection.scale))
    }
}

struct MinimapGeometryTests {
    @Test func clickPointBecomesTheCameraCentre() throws {
        let projection = try #require(
            MinimapProjection.fit(
                sceneBounds: CGRect(x: 0, y: 0, width: 1000, height: 500),
                in: CGSize(width: 180, height: 128),
                padding: 8))
        // A click at the minimap's (60, 70) pans so that point's model
        // position sits at the viewport centre, zoom untouched.
        let clicked = projection.modelPoint(for: CGPoint(x: 60, y: 70))
        let viewport = CGSize(width: 800, height: 600)
        let camera = MinimapGeometry.camera(centeringOn: clicked, scale: 2, viewportSize: viewport)
        let screen = camera.screenPoint(for: clicked)
        #expect(abs(screen.x - viewport.width / 2) < 1e-9)
        #expect(abs(screen.y - viewport.height / 2) < 1e-9)
        #expect(abs(camera.scale - 2) < 1e-9)
    }

    @Test func autoHidePredicateOnlyHidesAFullyVisibleMap() {
        let sceneBounds = CGRect(x: -50, y: -25, width: 100, height: 50)
        let viewport = CGSize(width: 200, height: 120)
        // The whole scene inside the visible rect → the minimap hides.
        let fitting = Camera(origin: CGPoint(x: -60, y: -30), scale: 1)
        #expect(MinimapGeometry.mapFitsViewport(camera: fitting, viewportSize: viewport, sceneBounds: sceneBounds))
        // Only part of the scene visible → shown.
        let partial = Camera(origin: .zero, scale: 1)
        #expect(!MinimapGeometry.mapFitsViewport(camera: partial, viewportSize: viewport, sceneBounds: sceneBounds))
        // Tolerance: a map that spills under a point still counts as
        // fitting, so a just-fitted view doesn't strobe.
        let almost = Camera(origin: CGPoint(x: -49.5, y: -24.75), scale: 1)
        #expect(
            MinimapGeometry.mapFitsViewport(
                camera: almost, viewportSize: viewport, sceneBounds: sceneBounds, tolerance: 1))
        // An empty scene or viewport has nothing to show → hidden.
        #expect(MinimapGeometry.mapFitsViewport(camera: partial, viewportSize: viewport, sceneBounds: .null))
        #expect(MinimapGeometry.mapFitsViewport(camera: partial, viewportSize: .zero, sceneBounds: sceneBounds))
    }
}

/// The view shell over the pure geometry: the auto-hide wiring, the
/// click→camera path, the cheap-draw cache and the VoiceOver press.
@MainActor
struct MinimapViewTests {
    private func makeMinimap() throws -> (MinimapView, CanvasScene) {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let minimap = MinimapView(
            frame: NSRect(
                x: 0, y: 0,
                width: MinimapView.defaultSize.width,
                height: MinimapView.defaultSize.height))
        minimap.viewportSize = CGSize(width: 900, height: 600)
        minimap.scene = scene
        return (minimap, scene)
    }

    @Test func minimapPointDrivesTheCamera() throws {
        let (minimap, _) = try makeMinimap()
        minimap.camera = Camera(origin: CGPoint(x: 100, y: 100), scale: 1)
        let clicked = CGPoint(x: 40, y: 30)

        let camera = try #require(minimap.camera(forMinimapPoint: clicked))
        let model = try #require(minimap.projection).modelPoint(for: clicked)
        let screen = camera.screenPoint(for: model)
        #expect(abs(screen.x - 450) < 1e-6)
        #expect(abs(screen.y - 300) < 1e-6)
        // Panning keeps the zoom (F-CAN-6: the minimap never zooms).
        #expect(abs(camera.scale - 1) < 1e-9)
    }

    @Test func autoHidesOnlyWhileTheWholeMapFits() throws {
        let (minimap, scene) = try makeMinimap()
        // Panned away: part of the map off-screen → shown.
        minimap.camera = Camera(origin: CGPoint(x: 100_000, y: 100_000), scale: 1)
        #expect(!minimap.isHidden)

        // Whole map inside the viewport → hidden (F-CAN-6).
        let bounds = scene.bounds
        minimap.camera = Camera(
            origin: CGPoint(x: bounds.minX - 50, y: bounds.minY - 50), scale: 0.25)
        #expect(minimap.isHidden)

        // The user's preference wins even when the map overflows.
        minimap.preferredVisible = false
        minimap.camera = Camera(origin: CGPoint(x: 100_000, y: 100_000), scale: 1)
        #expect(minimap.isHidden)
        minimap.preferredVisible = true
        #expect(!minimap.isHidden)
    }

    @Test func snapshotRebuildsOnlyWhenTheSceneChanges() throws {
        let (minimap, _) = try makeMinimap()
        #expect(minimap.sceneImage != nil)
        let afterScene = minimap.snapshotRebuildCount

        // Camera moves only re-stroke the viewport rect — no re-render.
        minimap.camera = Camera(origin: CGPoint(x: 500, y: 500), scale: 1)
        minimap.camera = Camera(origin: CGPoint(x: 600, y: 600), scale: 2)
        #expect(minimap.snapshotRebuildCount == afterScene)

        // A scene change re-renders the downscaled image.
        let rebuilt = SceneGeometry.build(
            model: sceneModel(rootText: "A second, wider root title"),
            variant: .dark,
            measurer: SceneRenderer.sharedMeasurer)
        minimap.scene = rebuilt
        #expect(minimap.snapshotRebuildCount == afterScene + 1)
        #expect(minimap.sceneImage != nil)
    }

    @Test func voiceOverPressCentresTheCameraOnTheMap() throws {
        let (minimap, scene) = try makeMinimap()
        var received: Camera?
        minimap.onCameraChange = { received = $0 }
        #expect(minimap.accessibilityPerformPress())
        let camera = try #require(received)
        let screen = camera.screenPoint(
            for: CGPoint(x: scene.bounds.midX, y: scene.bounds.midY))
        #expect(abs(screen.x - 450) < 1e-6)
        #expect(abs(screen.y - 300) < 1e-6)
    }
}

/// Hosted pixel test for the overlay's drawing path (the pattern of
/// `CanvasRenderingTests`): the minimap paints the simplified scene and
/// the viewport rect over a deterministic solid background.
@MainActor
struct MinimapDrawingTests {
    @Test func hostedMinimapDrawsSceneRectsAndViewport() throws {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.scene = scene

        let minimap = MinimapView(
            frame: NSRect(
                x: 800 - MinimapView.defaultSize.width - MinimapView.canvasMargin,
                y: 600 - MinimapView.defaultSize.height - MinimapView.canvasMargin,
                width: MinimapView.defaultSize.width,
                height: MinimapView.defaultSize.height))
        minimap.autoresizingMask = [.minXMargin, .minYMargin]
        canvas.addSubview(minimap)
        minimap.viewportSize = CGSize(width: 800, height: 600)
        minimap.scene = scene

        // Zoomed well past the map: the auto-hide rule must keep the
        // minimap up, and the precondition makes that expectation loud.
        minimap.camera = Camera(
            origin: CGPoint(
                x: scene.bounds.midX - 100, y: scene.bounds.midY - 75),
            scale: 4)
        #expect(
            !MinimapGeometry.mapFitsViewport(
                camera: minimap.camera, viewportSize: minimap.viewportSize, sceneBounds: scene.bounds))
        #expect(!minimap.isHidden)

        // Force the Reduce Transparency fallback so the background the
        // pixels are compared against is a deterministic solid fill.
        minimap.effectView.isHidden = true
        minimap.displayIfNeeded()

        guard
            let image = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(MinimapView.defaultSize.width),
                pixelsHigh: Int(MinimapView.defaultSize.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            Issue.record("no bitmap for cacheDisplay")
            return
        }
        minimap.cacheDisplay(in: minimap.bounds, to: image)

        // The padding corner is pure background; every pixel that
        // differs is scene or viewport ink.
        guard
            let background = image.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB),
            let backgroundComponents = background.cgColor.components,
            backgroundComponents.count >= 3
        else {
            Issue.record("no background pixel")
            return
        }
        var inkPixels = 0
        for x in 0..<Int(MinimapView.defaultSize.width) {
            for y in 0..<Int(MinimapView.defaultSize.height) {
                guard
                    let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    let components = color.cgColor.components, components.count >= 3
                else { continue }
                let differs = (0..<3).contains { channel in
                    abs(components[channel] - backgroundComponents[channel]) > 0.03
                }
                if differs {
                    inkPixels += 1
                }
            }
        }
        #expect(inkPixels > 30, "expected scene + viewport ink, found \(inkPixels)")
    }
}
