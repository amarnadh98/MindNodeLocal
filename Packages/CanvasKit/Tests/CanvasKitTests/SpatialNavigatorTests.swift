import CoreGraphics
import Foundation
import MapCore
import MapLayout
import MapRender
import Testing

@testable import CanvasKit

private let navDate = Date(timeIntervalSince1970: 1_800_000_000)

/// A root with three branches ("b0"…"b2"), each carrying one leaf
/// ("l0"…"l2"); root structure and branch side pins configurable.
private func branchyModel(
    rootStructure: String? = nil, pins: [String: SidePin] = [:]
) -> MapModel {
    var model = MapModel.emptyDocument(docID: "nav")
    let root = "root"
    model.nodes[root] = Node(
        id: root, title: NodeTitle(text: "Central Idea"), structure: rootStructure,
        created: navDate, modified: navDate)
    model.roots = [root]
    for index in 0..<3 {
        let branch = "b\(index)"
        model.nodes[branch] = Node(
            id: branch, parent: root, title: NodeTitle(text: "branch \(index)"),
            created: navDate, modified: navDate)
        if let pin = pins[branch] {
            model.nodes[branch]?.side = pin
        }
        model.nodes[root]?.children.append(branch)
        let leaf = "l\(index)"
        model.nodes[leaf] = Node(
            id: leaf, parent: branch, title: NodeTitle(text: "leaf \(index)"),
            created: navDate, modified: navDate)
        model.nodes[branch]?.children.append(leaf)
    }
    return model
}

private func buildScene(for model: MapModel) -> CanvasScene {
    SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
}

/// A scene with explicit frames and no branches — full control over
/// geometry-fallback scoring.
private func handScene(_ placed: [(String, CGRect)]) -> CanvasScene {
    let style = PaperTheme.resolvedStyle(level: 0, level1Index: 0, variant: .light)
    var nodes: [String: SceneNode] = [:]
    for (id, frame) in placed {
        nodes[id] = SceneNode(
            id: id, frame: frame, style: style, title: NodeTitle(text: id), level: 0,
            level1Index: 0)
    }
    return CanvasScene(
        nodes: nodes, branches: [],
        canvasColor: CGColor(srgbRed: 0.98, green: 0.97, blue: 0.97, alpha: 1))
}

private func navigate(
    _ direction: Direction, from id: String, scene: CanvasScene, model: MapModel
) -> String? {
    SpatialNavigator.target(from: id, direction: direction, scene: scene, model: model)
}

// MARK: mind map, right side

struct SpatialNavigatorRightSideTests {
    @Test func diveClimbAndVerticalSteps() throws {
        let model = branchyModel(rootStructure: "mindmap.right")
        let scene = buildScene(for: model)

        // → from the root: the child nearest vertically (the middle
        // branch, the root being centred on its children).
        #expect(navigate(.right, from: "root", scene: scene, model: model) == "b1")
        // → from a branch dives to its child; ← climbs to the parent.
        #expect(navigate(.right, from: "b0", scene: scene, model: model) == "l0")
        #expect(navigate(.left, from: "b0", scene: scene, model: model) == "root")
        #expect(navigate(.left, from: "l0", scene: scene, model: model) == "b0")
        // ↓/↑ step to the nearest sibling branch.
        #expect(navigate(.down, from: "b0", scene: scene, model: model) == "b1")
        #expect(navigate(.up, from: "b2", scene: scene, model: model) == "b1")
        // A right-side leaf has nothing further right: geometry finds
        // no candidate and the move stops at the map's edge.
        #expect(navigate(.right, from: "l0", scene: scene, model: model) == nil)
    }

    @Test func extendSelectionAddsTheTarget() throws {
        let model = branchyModel(rootStructure: "mindmap.right")
        let scene = buildScene(for: model)

        var selection: Set<String> = ["b0"]
        selection = SpatialNavigator.extendSelection(
            selection, from: "b0", direction: .down, scene: scene, model: model)
        #expect(selection == ["b0", "b1"])
        // No target at the map edge: unchanged.
        selection = SpatialNavigator.extendSelection(
            selection, from: "l0", direction: .right, scene: scene, model: model)
        #expect(selection == ["b0", "b1"])
    }
}

// MARK: balanced mind map, left side

struct SpatialNavigatorLeftSideTests {
    @Test func leftSideMirrorsRightAndRootPicksItsSide() throws {
        let model = branchyModel(pins: ["b0": .left, "b1": .left, "b2": .right])
        let scene = buildScene(for: model)

        // On the left side ← descends to the child and → climbs to
        // the parent (F-CAN-4's explicit mirroring rule).
        #expect(navigate(.left, from: "b0", scene: scene, model: model) == "l0")
        #expect(navigate(.right, from: "b0", scene: scene, model: model) == "root")
        #expect(navigate(.right, from: "l0", scene: scene, model: model) == "b0")
        // The root dives into the subtree on the pressed side only.
        #expect(navigate(.right, from: "root", scene: scene, model: model) == "b2")
        // b0 and b1 mirror b2's height symmetrically, so ← from the
        // root lands on whichever left child is nearest — the tie is
        // broken by branch order (b0 first).
        let leftDive = try #require(navigate(.left, from: "root", scene: scene, model: model))
        #expect(["b0", "b1"].contains(leftDive))
    }
}

// MARK: org chart (down)

struct SpatialNavigatorOrgChartTests {
    @Test func diveClimbAndRowSteps() throws {
        let model = branchyModel(rootStructure: "orgchart.down")
        let scene = buildScene(for: model)

        // ↓ dives to the child nearest horizontally; ↑ climbs.
        #expect(navigate(.down, from: "root", scene: scene, model: model) == "b1")
        #expect(navigate(.down, from: "b0", scene: scene, model: model) == "l0")
        #expect(navigate(.up, from: "l0", scene: scene, model: model) == "b0")
        // ←/→ step between siblings of the same row.
        #expect(navigate(.right, from: "b0", scene: scene, model: model) == "b1")
        #expect(navigate(.left, from: "b1", scene: scene, model: model) == "b0")
        // Past the last branch the move stops at the map's edge.
        #expect(navigate(.right, from: "b2", scene: scene, model: model) == nil)
    }
}

// MARK: folded subtrees

struct SpatialNavigatorFoldingTests {
    @Test func foldedSubtreeIsNeverATarget() throws {
        var model = branchyModel(rootStructure: "mindmap.right")
        model.nodes["b1"]?.folded = true
        let scene = buildScene(for: model)
        #expect(scene.nodes["l1"] == nil)

        // The folded node itself stays visible and reachable…
        #expect(navigate(.down, from: "b0", scene: scene, model: model) == "b1")
        // …but the geometry fallback from the top leaf must skip its
        // hidden children entirely and still land on a real node.
        let down = try #require(navigate(.down, from: "l0", scene: scene, model: model))
        #expect(down != "l1")
        #expect(scene.nodes[down] != nil)
    }
}

// MARK: geometry fallback

struct SpatialNavigatorGeometryTests {
    @Test func conePenaltyPrefersStraightAhead() {
        // "near" is closer in pure distance but 140 pt off-axis; the
        // cone penalty hands the move to the straight-ahead candidate.
        let scene = handScene([
            ("me", CGRect(x: 0, y: 0, width: 100, height: 40)),
            ("straight", CGRect(x: 10, y: 200, width: 100, height: 40)),
            ("near", CGRect(x: -150, y: 150, width: 100, height: 40)),
        ])
        let model = MapModel.emptyDocument(docID: "nav")
        #expect(navigate(.down, from: "me", scene: scene, model: model) == "straight")
    }

    @Test func onlyLooksInDirection() {
        let scene = handScene([
            ("me", CGRect(x: 0, y: 0, width: 100, height: 40)),
            ("above", CGRect(x: 0, y: -300, width: 100, height: 40)),
            ("below", CGRect(x: 0, y: 400, width: 100, height: 40)),
        ])
        let model = MapModel.emptyDocument(docID: "nav")
        #expect(navigate(.down, from: "me", scene: scene, model: model) == "below")
        #expect(navigate(.up, from: "me", scene: scene, model: model) == "above")
        #expect(navigate(.left, from: "me", scene: scene, model: model) == nil)
    }

    @Test func fallsBackAcrossSubtrees() {
        // A right-side leaf's ↓: no siblings, so the nearest node
        // below wins by geometry — here the next branch's leaf,
        // straight below, not the nearer-in-distance branch column.
        let scene = handScene([
            ("leaf-a", CGRect(x: 300, y: 0, width: 90, height: 30)),
            ("branch-b", CGRect(x: 60, y: 100, width: 90, height: 30)),
            ("leaf-b", CGRect(x: 300, y: 130, width: 90, height: 30)),
        ])
        let model = MapModel.emptyDocument(docID: "nav")
        #expect(navigate(.down, from: "leaf-a", scene: scene, model: model) == "leaf-b")
    }
}

// MARK: roots

struct SpatialNavigatorRootTests {
    @Test func nextAndPreviousRootWalkTheRootList() throws {
        var model = MapModel.emptyDocument(docID: "nav")
        let first = "root-1"
        let second = "root-2"
        let child = "child-2"
        model.nodes[first] = Node(
            id: first, title: NodeTitle(text: "One"), created: navDate, modified: navDate)
        model.nodes[second] = Node(
            id: second, title: NodeTitle(text: "Two"), created: navDate, modified: navDate)
        model.nodes[child] = Node(
            id: child, parent: second, title: NodeTitle(text: "Child"),
            created: navDate, modified: navDate)
        model.nodes[second]?.children.append(child)
        model.roots = [first, second]

        // Works from anywhere inside the tree, and stops at the ends.
        #expect(SpatialNavigator.nextRoot(after: "root-1", model: model) == second)
        #expect(SpatialNavigator.nextRoot(after: child, model: model) == nil)
        #expect(SpatialNavigator.previousRoot(before: child, model: model) == first)
        #expect(SpatialNavigator.previousRoot(before: first, model: model) == nil)
        // An unknown id has no tree to walk from.
        #expect(SpatialNavigator.nextRoot(after: "nope", model: model) == nil)
    }
}

// MARK: scroll-into-view

struct ScrollIntoViewTests {
    private let viewport = CGSize(width: 800, height: 600)

    @Test func alreadyVisibleFrameIsUnchanged() {
        let camera = Camera()
        #expect(
            SpatialNavigator.scrollIntoView(
                camera: camera, viewport: viewport,
                frame: CGRect(x: 100, y: 100, width: 100, height: 50))
                == camera)
        // Hugging the viewport edge still counts as visible: no jitter.
        #expect(
            SpatialNavigator.scrollIntoView(
                camera: camera, viewport: viewport,
                frame: CGRect(x: 690, y: 550, width: 100, height: 40))
                == camera)
    }

    @Test func movesMinimallyPerAxis() {
        let camera = Camera()
        // maxX deficit: 1000 needs to reach 800 - 40; y already fits.
        let moved = SpatialNavigator.scrollIntoView(
            camera: camera, viewport: viewport,
            frame: CGRect(x: 900, y: 100, width: 100, height: 50))
        #expect(moved.origin == CGPoint(x: 240, y: 0))
        #expect(moved.scale == camera.scale)
        // Above the viewport: y shifts by its own deficit, x stays.
        // frame.minY must land 40 above-visible-top → -300 to -340.
        let up = SpatialNavigator.scrollIntoView(
            camera: camera, viewport: viewport,
            frame: CGRect(x: 100, y: -300, width: 100, height: 50))
        #expect(up.origin == CGPoint(x: 0, y: -340))
    }

    @Test func movesBothAxesWhenBothOverflow() {
        let moved = SpatialNavigator.scrollIntoView(
            camera: Camera(), viewport: viewport,
            frame: CGRect(x: 900, y: 700, width: 100, height: 50))
        #expect(moved.origin == CGPoint(x: 240, y: 190))
    }

    @Test func marginIsInScreenPointsAtAnyZoom() {
        let camera = Camera(origin: CGPoint(x: 0, y: 0), scale: 2)
        // Visible model width is 400; the 40 pt margin is 20 in model
        // space: the frame's maxX must reach 480 - (400 - 20).
        let moved = SpatialNavigator.scrollIntoView(
            camera: camera, viewport: viewport,
            frame: CGRect(x: 380, y: 100, width: 100, height: 40))
        #expect(moved.origin == CGPoint(x: 100, y: 0))
        let visible = moved.visibleRect(viewportSize: viewport)
        #expect(visible.maxX - 480 == 20)  // 40 screen points
    }

    @Test func frameWiderThanViewportAlignsLeadingEdge() {
        let moved = SpatialNavigator.scrollIntoView(
            camera: Camera(), viewport: viewport,
            frame: CGRect(x: -1000, y: 100, width: 2000, height: 50))
        #expect(moved.origin == CGPoint(x: -1040, y: 0))
    }

    @Test func degenerateInputReturnsCameraUnchanged() {
        let camera = Camera(origin: CGPoint(x: 5, y: 5), scale: 2)
        #expect(
            SpatialNavigator.scrollIntoView(
                camera: camera, viewport: .zero, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
                == camera)
        #expect(
            SpatialNavigator.scrollIntoView(
                camera: camera, viewport: viewport, frame: .null) == camera)
    }
}
