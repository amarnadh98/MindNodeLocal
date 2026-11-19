import AppKit
import CoreGraphics
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// F-AI-2's ghost overlay: dashed, 50%-opacity suggestions that are pure
/// view state — never model nodes, never dirty, invisible to the grid,
/// undo stack and accessibility tree. Headless.
@MainActor
struct GhostOverlayTests {
    private func presentation(count: Int = 2) -> GhostPresentation {
        var items: [GhostPresentation.Item] = []
        for index in 0..<count {
            items.append(
                GhostPresentation.Item(
                    id: "ghost-\(index)",
                    node: SceneNode(
                        id: "ghost-\(index)",
                        frame: CGRect(x: 100, y: CGFloat(40 * index), width: 120, height: 30),
                        style: PaperTheme.reference.resolvedStyle(level: 2, level1Index: 0, variant: .light),
                        title: NodeTitle(text: "Idea \(index)"),
                        level: 2,
                        level1Index: 0)))
        }
        let branch = SceneBranch(
            parentID: "root", childID: "ghost-0",
            from: CGPoint(x: 50, y: 40), to: CGPoint(x: 100, y: 40),
            direction: .right, axis: .horizontal,
            startWidth: 3, endWidth: 2,
            color: CGColor(gray: 0.5, alpha: 1), tapered: false)
        return GhostPresentation(parentID: "root", items: items, branches: [branch])
    }

    private func overlay() -> GhostOverlay {
        GhostOverlay()
    }

    @Test func presentingBuildsDashedHalfOpacityLayers() {
        let ghostOverlay = overlay()
        ghostOverlay.update(presentation(), camera: Camera(), backingScale: 1, measurer: TextMeasurer())
        #expect(ghostOverlay.presentedIDs == ["ghost-0", "ghost-1"])
        #expect(ghostOverlay.isPresented)
        #expect(abs(ghostOverlay.container.opacity - GhostPresentation.ghostOpacity) < 0.001)

        // Every item carries a dashed border; the branch is dashed too.
        for sublayer in ghostOverlay.container.sublayers ?? [] {
            if let border = sublayer as? CAShapeLayer, sublayer.bounds.width == 0 {
                #expect(border.lineDashPattern != nil)
            }
        }
        let shapes = (ghostOverlay.container.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        #expect(shapes.contains { $0.lineDashPattern != nil })
    }

    @Test func clearingRemovesAllLayers() {
        let ghostOverlay = overlay()
        ghostOverlay.update(presentation(), camera: Camera(), backingScale: 1, measurer: TextMeasurer())
        ghostOverlay.update(nil, camera: Camera(), backingScale: 1, measurer: TextMeasurer())
        #expect(!ghostOverlay.isPresented)
        #expect(ghostOverlay.presentedIDs.isEmpty)
        #expect((ghostOverlay.container.sublayers ?? []).isEmpty)
    }

    @Test func hitTestMapsModelPointsToGhostIDs() {
        let ghostOverlay = overlay()
        ghostOverlay.update(presentation(), camera: Camera(), backingScale: 1, measurer: TextMeasurer())
        // Camera at identity: view point == model point. ghost-0 spans
        // y 0…30, ghost-1 y 40…70.
        #expect(ghostOverlay.ghostID(at: CGPoint(x: 120, y: 15)) == "ghost-0")
        #expect(ghostOverlay.ghostID(at: CGPoint(x: 120, y: 55)) == "ghost-1")
        #expect(ghostOverlay.ghostID(at: CGPoint(x: 150, y: 80)) == nil)
        #expect(ghostOverlay.ghostID(at: CGPoint(x: 10, y: 10)) == nil)
    }

    @Test func hitTestIsModelSpace() {
        let ghostOverlay = overlay()
        ghostOverlay.update(presentation(), camera: Camera(), backingScale: 1, measurer: TextMeasurer())
        ghostOverlay.updateCamera(camera: Camera(origin: .zero, scale: 2))
        // The overlay hit-tests in model space regardless of camera:
        // the camera only re-pins rendered placements.
        #expect(ghostOverlay.ghostID(at: CGPoint(x: 120, y: 15)) == "ghost-0")
    }

    @Test func hitTestPrefersTheInnermostGhost() {
        let ghostOverlay = overlay()
        // Overlapping ghosts: the smaller frame wins (topmost feel).
        var big = presentation(count: 1)
        big = GhostPresentation(
            parentID: big.parentID,
            items: big.items
                + [
                    GhostPresentation.Item(
                        id: "small",
                        node: SceneNode(
                            id: "small",
                            frame: CGRect(x: 110, y: 5, width: 40, height: 12),
                            style: big.items[0].node.style,
                            title: NodeTitle(text: "inner"),
                            level: 2,
                            level1Index: 0))
                ],
            branches: big.branches)
        ghostOverlay.update(big, camera: Camera(), backingScale: 1, measurer: TextMeasurer())
        #expect(ghostOverlay.ghostID(at: CGPoint(x: 115, y: 10)) == "small")
    }

    // MARK: view wiring

    @Test func canvasExposesGhostsAndForwardsClicks() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.scene = SceneGeometry.build(
            model: MapModel.emptyDocument(), variant: .light, measurer: TextMeasurer())
        canvas.ghosts = presentation(count: 1)
        #expect(canvas.isPresentingGhosts)

        var accepted: [String] = []
        canvas.onGhostAccept = { accepted.append($0) }
        // Camera identity: the ghost frame at (100,0,120,30) sits in view
        // space at the same coordinates.
        let hit = canvas.ghostID(at: CGPoint(x: 120, y: 5))
        #expect(hit == "ghost-0")
        canvas.onGhostAccept?(hit ?? "")
        #expect(accepted == ["ghost-0"])

        // The view-level hit converts through the camera: at 2× the same
        // ghost sits at doubled view coordinates.
        canvas.camera = Camera(origin: .zero, scale: 2)
        #expect(canvas.ghostID(at: CGPoint(x: 240, y: 30)) == "ghost-0")
        #expect(canvas.ghostID(at: CGPoint(x: 120, y: 15)) == nil)

        canvas.ghosts = nil
        #expect(!canvas.isPresentingGhosts)
        #expect(canvas.ghostID(at: CGPoint(x: 120, y: 5)) == nil)
    }

    @Test func presentingGhostsNeverTouchesTheDocumentState() throws {
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var model = MapModel.emptyDocument()
        let root = Node(id: "root", title: NodeTitle(text: "Root"))
        model.nodes[root.id] = root
        model.roots = [root.id]
        canvas.scene = SceneGeometry.build(model: model, variant: .light, measurer: TextMeasurer())
        let before = model

        canvas.ghosts = presentation()
        // The ghost ids are not in the scene or the grid; the model and
        // its one real node are exactly as before.
        #expect(canvas.scene?.nodes["ghost-0"] == nil)
        let gridIDs = canvas.grid.ids(intersecting: CGRect(x: 0, y: 0, width: 10_000, height: 10_000))
        #expect(!gridIDs.contains("ghost-0"))
        #expect(gridIDs.contains("root"))
        #expect(model == before)
    }
}

private enum PaperTheme {
    static let reference = MapRender.BuiltInThemes.theme(id: MapRender.BuiltInThemes.defaultID)
}
