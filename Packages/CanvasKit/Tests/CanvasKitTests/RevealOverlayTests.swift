import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import MapStudy
import QuartzCore
import Testing

@testable import CanvasKit

/// The presentation overlay in the layer tree (SPEC §10, F-PRE-3):
/// hidden/placeholder/ghost nodes ride opacity only — never a
/// re-raster — branches dim with the weaker end, later-realized
/// layers pick the overlay up, and the reveal build animation (fade +
/// 8 pt slide from the parent, 250 ms, 60 ms stagger) attaches per
/// §7.6, instant under Reduce Motion.
@MainActor
struct RevealOverlayTests {
    private let viewport = CGSize(width: 800, height: 600)
    private var fitCamera: Camera {
        Camera(origin: CGPoint(x: -400, y: -300), scale: 1)
    }

    private func grid(for scene: CanvasScene) -> SpatialGrid {
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        return grid
    }

    private func apply(
        _ tree: CanvasLayerTree, _ scene: CanvasScene, camera: Camera
    ) {
        var context = ApplyContext(
            scene: scene, grid: grid(for: scene), camera: camera, viewport: viewport)
        context.backingScale = 1
        context.animated = false
        tree.apply(context)
    }

    @Test func overlayOpacitiesFollowTheState() {
        let overlay = RevealOverlay(
            states: ["hidden": .hidden, "ph": .placeholder],
            dimmed: ["ghosted", "plain"])
        // Hidden is 0 even when dimmed.
        #expect(overlay.nodeOpacity("hidden") == 0)
        // The ghost dim of focus slides (F-PRE-1: 15%).
        #expect(overlay.nodeOpacity("ghosted") == RevealOverlay.ghostOpacity)
        // Unmanaged ids are visible unless dimmed.
        #expect(overlay.nodeOpacity("plain") == RevealOverlay.ghostOpacity)
        #expect(overlay.nodeOpacity("other") == 1)
        // Placeholders render faintly (refined in M7's recall mode).
        #expect(overlay.nodeOpacity("ph") == RevealOverlay.placeholderOpacity)
    }

    @Test func branchTakesTheWeakerOfItsTwoEnds() {
        let overlay = RevealOverlay(states: ["child": .hidden], dimmed: [])
        #expect(overlay.branchOpacity(parentID: "parent", childID: "child") == 0)
        #expect(overlay.branchOpacity(parentID: "parent", childID: "other") == 1)
        let ghosted = RevealOverlay(states: [:], dimmed: ["child"])
        #expect(abs(ghosted.branchOpacity(parentID: "p", childID: "child") - RevealOverlay.ghostOpacity) < 0.001)
    }

    @Test func overlayDimsLayersWithoutRerastering() throws {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)

        let keyBefore = tree.nodeRasterKey("branch-0")
        let keyBefore1 = tree.nodeRasterKey("branch-1")
        let focus = RevealOverlay(states: ["branch-0": .hidden], dimmed: ["branch-1", "leaf-1-0"])
        tree.setRevealOverlay(focus)

        #expect(tree.nodeLayers["branch-0"]?.opacity == 0)
        #expect(tree.nodeLayers["branch-1"]?.opacity == Float(RevealOverlay.ghostOpacity))
        #expect(abs((tree.nodeLayers["leaf-0-0"]?.opacity ?? 0) - 1) < 0.001)
        // Pan/zoom-style opacity writes never repaint: the raster key
        // is unchanged (SPEC §11.4).
        #expect(tree.nodeRasterKey("branch-0") == keyBefore)
        #expect(tree.nodeRasterKey("branch-1") == keyBefore1)

        // Branches follow: the hidden node's incoming branch is gone.
        let hiddenBranch = scene.branches.first { $0.childID == "branch-0" }
        let key = BranchKey(parentID: hiddenBranch!.parentID, childID: "branch-0")
        #expect(tree.branchLayers[key]?.opacity == 0)

        // Clearing the overlay restores everything.
        tree.setRevealOverlay(nil)
        #expect(tree.nodeLayers["branch-0"]?.opacity == 1)
        #expect(tree.branchLayers[key]?.opacity == 1)
    }

    @Test func lateRealizedLayersPickUpTheOverlay() throws {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        // Park the camera where nothing is visible, install the
        // overlay, then pan the map in: realization must honor it.
        apply(tree, scene, camera: Camera(origin: CGPoint(x: 100_000, y: 100_000), scale: 1))
        tree.setRevealOverlay(RevealOverlay(states: ["branch-0": .hidden], dimmed: ["branch-1"]))
        tree.updateCamera(camera: fitCamera, viewport: viewport, backingScale: 1)
        #expect(tree.nodeLayers["branch-0"]?.opacity == 0)
        #expect(tree.nodeLayers["branch-1"]?.opacity == Float(RevealOverlay.ghostOpacity))
        #expect(tree.nodeLayers["leaf-0-0"]?.opacity == 1)
    }

    @Test func revealAnimationAttachesPerMotionTable() throws {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)

        tree.revealNodes(["branch-0", "branch-1"], camera: fitCamera, reduceMotion: false)
        for id in ["branch-0", "branch-1"] {
            let layer = try #require(tree.nodeLayers[id])
            let fade = try #require(layer.animation(forKey: "reveal-opacity") as? CABasicAnimation)
            #expect(abs(fade.duration - 0.25) < 0.001)
            let slide = try #require(layer.animation(forKey: "reveal-position") as? CABasicAnimation)
            #expect(abs(slide.duration - 0.25) < 0.001)
        }
        // The second id's step staggers by 60 ms (§7.6).
        let first =
            tree.nodeLayers["branch-0"]?.animation(forKey: "reveal-opacity") as? CABasicAnimation
        let second =
            tree.nodeLayers["branch-1"]?.animation(forKey: "reveal-opacity") as? CABasicAnimation
        #expect(abs(((second?.beginTime ?? 0) - (first?.beginTime ?? 0)) - CanvasLayerTree.revealStagger) < 0.001)
        // The branch to the revealed node fades with it.
        let branchLayer = try #require(
            tree.branchLayers[BranchKey(parentID: "root", childID: "branch-0")])
        #expect(branchLayer.animation(forKey: "reveal-branch") != nil)
    }

    @Test func reduceMotionRevealsInstantly() throws {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)

        tree.revealNodes(["branch-0"], camera: fitCamera, reduceMotion: true)
        #expect(tree.nodeLayers["branch-0"]?.opacity == 1)
        #expect(tree.nodeLayers["branch-0"]?.animation(forKey: "reveal-opacity") == nil)
        #expect(tree.nodeLayers["branch-0"]?.animation(forKey: "reveal-position") == nil)
    }

    @Test func revealSlideStartsEightPointsTowardTheParent() throws {
        let scene = SceneGeometry.build(
            model: sceneModel(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let tree = CanvasLayerTree()
        apply(tree, scene, camera: fitCamera)

        let childFrame = try #require(scene.nodes["leaf-0-0"]?.frame)
        let parentAnchor = try #require(
            scene.branches.first { $0.childID == "leaf-0-0" }?.from)
        let to = fitCamera.screenPoint(for: childFrame.origin)
        let from = fitCamera.screenPoint(for: parentAnchor)
        let slide = CanvasLayerTree.revealSlide(to: to, from: from, delay: 0)

        let start = try #require(slide.fromValue as? NSValue).pointValue
        let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
        let length = hypot(delta.dx, delta.dy)
        let expected = CGPoint(
            x: to.x - delta.dx / length * CanvasLayerTree.revealSlideDistance,
            y: to.y - delta.dy / length * CanvasLayerTree.revealSlideDistance)
        #expect(abs(start.x - expected.x) < 0.001)
        #expect(abs(start.y - expected.y) < 0.001)
        // The slide is exactly 8 pt long.
        let distance = hypot(to.x - start.x, to.y - start.y)
        #expect(abs(distance - CanvasLayerTree.revealSlideDistance) < 0.001)
    }
}

/// The §7.6 camera tween: 600 ms ease-in-out, endpoint-exact.
struct SlideCameraEasingTests {
    @Test func endpointsAndMidpoint() {
        let from = Camera(origin: CGPoint(x: 0, y: 0), scale: 1)
        let to = Camera(origin: CGPoint(x: 100, y: 40), scale: 2)
        #expect(CameraEasing.interpolate(from: from, to: to, progress: 0) == from)
        #expect(CameraEasing.interpolate(from: from, to: to, progress: 1) == to)
        // The cubic ease at the midpoint is exactly halfway.
        let middle = CameraEasing.interpolate(from: from, to: to, progress: 0.5)
        #expect(abs(middle.origin.x - 50) < 0.001)
        #expect(abs(middle.origin.y - 20) < 0.001)
        #expect(abs(middle.scale - 1.5) < 0.001)
    }

    @Test func easeInOutCubicIsSmoothAndMonotonic() {
        #expect(CameraEasing.easeInOutCubic(0) == 0)
        #expect(CameraEasing.easeInOutCubic(1) == 1)
        #expect(abs(CameraEasing.easeInOutCubic(0.25) - 0.0625) < 0.000001)
        var previous = 0.0
        for step in stride(from: 0.1, through: 1.0, by: 0.1) {
            let eased = CameraEasing.easeInOutCubic(step)
            #expect(eased >= previous)
            previous = eased
        }
        // Out-of-range progress clamps.
        #expect(CameraEasing.easeInOutCubic(2) == 1)
        #expect(CameraEasing.easeInOutCubic(-1) == 0)
    }

    @Test func durationsHonorReduceMotion() {
        #expect(CameraEasing.slideDuration(reduceMotion: false) == 0.6)
        #expect(CameraEasing.slideDuration(reduceMotion: true) == 0)
    }
}

/// The slide geometry helpers (M6): fold state on a derived model,
/// authored-slide resolution and the camera fit.
struct PresentationGeometryTests {
    @Test func foldStateAppliesToADerivedModelOnly() {
        var model = MapModel.emptyDocument(docID: "fold")
        model.nodes["r"] = Node(id: "r", title: NodeTitle(text: "r"))
        model.roots = ["r"]
        model.nodes["a"] = Node(id: "a", parent: "r", title: NodeTitle(text: "a"))
        model.nodes["r"]?.children = ["a"]
        model.nodes["a"]?.folded = true

        // The slide's list is the complete fold state: listed ids fold,
        // everything else unfolds.
        var derived = PresentationGeometry.applyingFoldState(["a"], to: model)
        #expect(derived.nodes["a"]?.folded == true)
        derived = PresentationGeometry.applyingFoldState([], to: model)
        #expect(derived.nodes["a"]?.folded == false)
        // The source model is never touched.
        #expect(model.nodes["a"]?.folded == true)
    }

    @Test func authoredSlidesResolveAgainstTheScene() throws {
        var model = sceneModel()
        let slide = Slide(
            id: "s1", title: "One",
            camera: SlideCamera(x: 0, y: 0, scale: 1),
            focus: ["root", "branch-0"],
            dimOthers: true,
            build: ["branch-0"],
            notes: "hello")
        model.presentations = [Presentation(id: "d", name: "Deck", slides: [slide, Slide(id: "s2")])]

        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let resolved = PresentationGeometry.resolve(
            presentation: model.presentations![0], scene: scene)
        #expect(resolved.count == 2)
        #expect(resolved[0].kind == .authored)
        #expect(resolved[0].title == "One")
        #expect(resolved[0].focus == ["root", "branch-0"])
        #expect(resolved[0].build == ["branch-0"])
        #expect(resolved[0].notes == "hello")
        // Missing titles get numbered; a missing camera resolves to a
        // whole-scene fit at present time (nil here, so any viewport
        // fits).
        #expect(resolved[1].title == "Slide 2")
        #expect(resolved[1].camera == nil)
        let fallback = resolved[1].camera(for: CGSize(width: 800, height: 600), scene: scene, margin: 40)
        #expect(fallback.scale > 0)
        #expect(resolved[1].dimOthers)  // the schema default
    }

    @Test func staleSlideIdsDegradeGracefully() throws {
        var model = sceneModel()
        let slide = Slide(
            id: "s1", focus: ["root", "deleted"], dimOthers: true, build: ["deleted"])
        model.presentations = [Presentation(id: "d", name: "Deck", slides: [slide])]
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let resolved = PresentationGeometry.resolve(
            presentation: model.presentations![0], scene: scene)
        #expect(resolved[0].focus == ["root"])
        #expect(resolved[0].build.isEmpty)
    }

    @Test func managedIDsAreFocusPlusBuild() {
        let slide = ResolvedSlide(kind: .authored, title: "s", focus: ["a", "b"], build: ["b", "c"])
        #expect(PresentationGeometry.managedIDs(of: slide) == ["a", "b", "c"])
    }

    @Test func cameraFitIsAspectCorrect() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let camera = CameraFit.camera(fitting: rect, in: CGSize(width: 800, height: 600), margin: 50)
        // Content 300×200: width limits → 800/300.
        #expect(abs(camera.scale - 800.0 / 300.0) < 0.001)
        // The content is centered.
        let visible = camera.visibleRect(viewportSize: CGSize(width: 800, height: 600))
        #expect(abs(visible.midX - rect.midX) < 0.001)
        #expect(abs(visible.midY - rect.midY) < 0.001)
    }
}
