import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// The F-PRE-1 auto presentation: slide order (the clockwise rule the
/// outline view also uses), the ghosting set, the level-2 sub-slide
/// threshold and the camera fit per slide.
struct AutoPresentationTests {
    /// root with pinned sides: right → r1 (upper), r2 (lower); left →
    /// l1 (upper), l2 (lower). r1 grows beyond the sub-slide threshold.
    private func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "auto")
        let root = Node(id: "root", title: NodeTitle(text: "root"), created: sceneDate, modified: sceneDate)
        model.nodes[root.id] = root
        model.roots = [root.id]

        func add(_ id: String, parent: String, side: SidePin?, title: String, note: String? = nil) {
            var node = Node(
                id: id, title: NodeTitle(text: title), created: sceneDate, modified: sceneDate)
            node.side = side
            node.parent = parent
            node.note = note
            model.nodes[id] = node
            model.nodes[parent]?.children.append(id)
        }

        add("r1", parent: "root", side: .right, title: "right one", note: "branch note")
        add("r2", parent: "root", side: .right, title: "right two")
        add("l1", parent: "root", side: .left, title: "left one")
        add("l2", parent: "root", side: .left, title: "left two")

        // r1's subtree: 3 level-2 children with their own leaves — more
        // than the default threshold of 12 nodes.
        for index in 0..<3 {
            let child = "r1-\(index)"
            add(child, parent: "r1", side: nil, title: "sub \(index)")
            for leaf in 0..<4 {
                add("\(child)-\(leaf)", parent: child, side: nil, title: "leaf")
            }
        }
        // r2's subtree stays small (1 child): no sub-slides.
        add("r2-0", parent: "r2", side: nil, title: "only child")
        return model
    }

    private func scene() -> CanvasScene {
        SceneGeometry.build(
            model: model(), variant: .light, measurer: SceneRenderer.sharedMeasurer)
    }

    @Test func clockwiseOrderIsRightTopToBottomThenLeftBottomToTop() throws {
        let subject = model()
        let built = scene()
        let order = AutoPresentation.clockwiseLevelOneIDs(model: subject, scene: built, rootID: "root")
        #expect(order.count == 4)
        #expect(order.first == "r1")
        #expect(order[1] == "r2")
        // The left side walks bottom→top.
        #expect(order[2] == "l2")
        #expect(order.last == "l1")
    }

    @Test func deckIsOverviewBranchesInClockwiseOrderThenOverview() throws {
        let slides = AutoPresentation.slides(model: model(), scene: scene())
        #expect(slides.first?.kind == .overview)
        #expect(slides.last?.kind == .overview)
        let branchSlides = slides.filter { $0.kind == .branch }
        #expect(branchSlides.map(\.title) == ["right one", "right two", "left two", "left one"])
        // r1 exceeds the sub-slide threshold, so its sub-slides follow
        // its branch slide directly.
        #expect(slides[1].kind == .branch)
        #expect(slides[2].kind == .sub)
        #expect(slides[3].kind == .sub)
        #expect(slides[4].kind == .sub)
        #expect(slides[5].kind == .branch)  // r2, below threshold
    }

    @Test func branchSlideGhostsEverythingOutsideTheFocusSet() throws {
        let slides = AutoPresentation.slides(model: model(), scene: scene())
        let firstBranch = slides.first { $0.kind == .branch }!
        #expect(firstBranch.dimOthers)
        #expect(firstBranch.focus.contains("root"))
        #expect(firstBranch.focus.contains("r1"))
        #expect(firstBranch.focus.contains("r1-0"))
        #expect(!firstBranch.focus.contains("r2"))
        #expect(!firstBranch.focus.contains("l1"))

        // The F-PRE-1 ghost set: every scene node outside focus.
        let dimmed = PresentationGeometry.dimmedIDs(of: firstBranch, scene: scene())
        #expect(dimmed.contains("r2"))
        #expect(dimmed.contains("l2"))
        #expect(!dimmed.contains("r1"))
        // An overview manages nothing and dims nothing.
        #expect(PresentationGeometry.dimmedIDs(of: slides.first!, scene: scene()).isEmpty)
    }

    @Test func cameraFitCoversTheFocusSetWithMargin() throws {
        let built = scene()
        let slides = AutoPresentation.slides(model: model(), scene: built)
        let branchSlide = slides.first { $0.kind == .branch }!

        // The fit rect contains every focus frame (edges inclusive —
        // union bounds sit exactly on the frames' edges).
        let fit = try #require(branchSlide.cameraFit)
        for id in branchSlide.focus {
            let frame = try #require(built.nodes[id]?.frame)
            #expect(fit.union(frame) == fit)
        }
        // The camera derived from it centers the focus set with the
        // F-PRE-1 margin.
        let viewport = CGSize(width: 1280, height: 720)
        let camera = branchSlide.camera(for: viewport, scene: built, margin: 80)
        let visible = camera.visibleRect(viewportSize: viewport)
        #expect(visible.contains(fit.insetBy(dx: 80, dy: 80)))

        // Overview fits the whole map.
        let overview = slides.first!
        let overviewFit = try #require(overview.cameraFit)
        #expect(overviewFit.contains(built.bounds))
    }

    @Test func subSlidesAppearOnlyBeyondTheThreshold() throws {
        // Default threshold (12): r1's subtree has 15 nodes → 3
        // level-2 sub-slides; r2's has 2 → none.
        let slides = AutoPresentation.slides(model: model(), scene: scene())
        let subs = slides.filter { $0.kind == .sub }
        #expect(subs.count == 3)
        #expect(subs.map(\.title).contains { $0.contains("sub 0") })
        let r2Subs = subs.filter { $0.title.contains("right two") }
        #expect(r2Subs.isEmpty)

        // A high threshold removes them entirely.
        var options = AutoPresentation.Options()
        options.subSlideThreshold = 100
        let strict = AutoPresentation.slides(model: model(), scene: scene(), options: options)
        #expect(strict.filter { $0.kind == .sub }.isEmpty)
    }

    @Test func subSlideFocusCarriesTheAncestorPath() throws {
        let slides = AutoPresentation.slides(model: model(), scene: scene())
        let sub = slides.first { $0.kind == .sub }!
        #expect(sub.focus.contains("root"))
        #expect(sub.focus.contains("r1"))
        #expect(sub.focus.contains { $0.hasPrefix("r1-0") })
        #expect(!sub.focus.contains("r1-1"))
    }

    @Test func branchNotesComeFromTheFocusedNode() throws {
        let slides = AutoPresentation.slides(model: model(), scene: scene())
        let r1Slide = slides.first { $0.title == "right one" }
        #expect(r1Slide?.notes == "branch note")
    }

    @Test func emptySceneProducesNoSlides() {
        #expect(
            AutoPresentation.slides(
                model: MapModel.emptyDocument(),
                scene: CanvasScene(nodes: [:], branches: [], canvasColor: NSColor.black.cgColor)
            ).isEmpty)
    }
}
