import AppKit
import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import CanvasKit

// MARK: - fixtures

/// A balanced four-branch map with pinned sides: c0/c3 right, c1/c2
/// left, every branch carrying one leaf.
private func balancedModel() -> MapModel {
    var model = MapModel.emptyDocument(docID: "balanced")
    func node(_ id: String, parent: String?, side: SidePin?) -> Node {
        var node = Node(id: id, parent: parent, title: NodeTitle(text: id))
        node.side = side
        node.created = sceneDate
        node.modified = sceneDate
        return node
    }
    model.nodes["root"] = node("root", parent: nil, side: nil)
    model.roots = ["root"]
    for (id, pin) in [("c0", SidePin.right), ("c1", .left), ("c2", .left), ("c3", .right)] {
        model.nodes[id] = node(id, parent: "root", side: pin)
        model.nodes["root"]?.children.append(id)
        let leafID = "\(id)-leaf"
        model.nodes[leafID] = node(leafID, parent: id, side: nil)
        model.nodes[id]?.children.append(leafID)
    }
    return model
}

/// `root` → [x, d, y], `d` → [d1].
private func chainModel() -> MapModel {
    var model = MapModel.emptyDocument(docID: "chain")
    func node(_ id: String, parent: String?) -> Node {
        var node = Node(id: id, parent: parent, title: NodeTitle(text: id))
        node.created = sceneDate
        node.modified = sceneDate
        return node
    }
    model.nodes["root"] = node("root", parent: nil)
    model.roots = ["root"]
    for id in ["x", "d", "y"] {
        model.nodes[id] = node(id, parent: "root")
        model.nodes["root"]?.children.append(id)
    }
    model.nodes["d1"] = node("d1", parent: "d")
    model.nodes["d"]?.children.append("d1")
    return model
}

/// An org chart whose child row is narrower than the wide root, so
/// hovering inside the root's frame precedes (left edge) or follows
/// (right edge) both children. Internal: shared with the root-move
/// tests.
func orgModel() -> MapModel {
    var model = MapModel.emptyDocument(docID: "org")
    var root = Node(id: "root", title: NodeTitle(text: "Central Idea Text"))
    root.structure = "orgchart.down"
    root.created = sceneDate
    root.modified = sceneDate
    model.nodes["root"] = root
    model.roots = ["root"]
    for id in ["a", "b"] {
        var node = Node(id: id, parent: "root", title: NodeTitle(text: id))
        node.created = sceneDate
        node.modified = sceneDate
        model.nodes[id] = node
        model.nodes["root"]?.children.append(id)
    }
    return model
}

func buildScene(_ model: MapModel) -> CanvasScene {
    SceneGeometry.build(model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
}

// MARK: - resolver

/// F-EDT-5 drop-target resolution: hover → reparent with the right slot,
/// gap → insertBetween with drawable line, own subtree → none, empty
/// canvas → newRoot, balanced roots side-aware.
struct DropTargetResolverTests {
    @Test func hoveringNodeReparentsAtTheNearestSlot() throws {
        let model = sceneModel()
        let scene = buildScene(model)
        let branch = try #require(scene.nodes["branch-0"]?.frame)

        // The grabbed leaf-1-0 hovers the top of branch-0: it lands
        // before branch-0's only child.
        let target = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["leaf-1-0"],
            point: CGPoint(x: branch.midX, y: branch.minY + 1))
        #expect(target == .reparent(parent: "branch-0", index: 0))

        // A node with no visible children (its child is folded away)
        // appends at the end of its children.
        var folded = model
        folded.nodes["branch-1"]?.folded = true
        let foldedScene = buildScene(folded)
        let b1 = try #require(foldedScene.nodes["branch-1"]?.frame)
        let appended = DropTargetResolver.resolve(
            model: folded, scene: foldedScene, dragged: ["leaf-0-0"],
            point: CGPoint(x: b1.midX, y: b1.midY))
        #expect(appended == .reparent(parent: "branch-1", index: 1))
    }

    @Test func hoveringTheRootPicksTheSideSlot() throws {
        let model = sceneModel()
        let scene = buildScene(model)
        let root = try #require(scene.nodes["root"]?.frame)

        // The left side is [branch-0 (top), branch-2 (bottom)], centered
        // on the root: hovering the root's left half anchors between
        // them. (Exactly at the center-x the tie goes to the right side,
        // so the probe stays clear of it.)
        let target = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["leaf-1-0"],
            point: CGPoint(x: root.midX - 1, y: root.midY))
        #expect(target == .reparent(parent: "root", index: 2))
    }

    @Test func balancedRootIsSideAware() throws {
        let model = balancedModel()
        let scene = buildScene(model)
        let root = try #require(scene.nodes["root"]?.frame)

        // Hovering the root's left half anchors on the left children:
        // between c1 (top) and c2 (bottom), never on the right side.
        let left = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["c0-leaf"],
            point: CGPoint(x: root.midX - 1, y: root.midY))
        #expect(left == .reparent(parent: "root", index: 2))

        // The right half anchors between c0 (top) and c3 (bottom).
        let right = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["c0-leaf"],
            point: CGPoint(x: root.midX + 1, y: root.midY))
        #expect(right == .reparent(parent: "root", index: 3))

        // The left-side mirroring shows in the scene itself.
        #expect(try #require(scene.nodes["c1"]?.frame).maxX <= root.minX)
        #expect(try #require(scene.nodes["c2"]?.frame).maxX <= root.minX)
        #expect(try #require(scene.nodes["c0"]?.frame).minX >= root.maxX)
    }

    @Test func hoveringTheGapInsertsBetweenSiblings() throws {
        let model = balancedModel()
        let scene = buildScene(model)
        let root = try #require(scene.nodes["root"]?.frame)
        let c1 = try #require(scene.nodes["c1"]?.frame)
        let c2 = try #require(scene.nodes["c2"]?.frame)

        // In the branch corridor between c1 and c2, left of the root.
        let point = CGPoint(x: root.minX - 10, y: (c1.maxY + c2.minY) / 2)
        let target = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["c0-leaf"], point: point)
        guard case .insertBetween(let parent, let index, let line) = target else {
            Issue.record("expected insertBetween, got \(target)")
            return
        }
        #expect(parent == "root")
        #expect(index == 2)
        // The insertion line spans the corridor at the boundary: from
        // the root's left edge to the children's inner edge.
        #expect(abs(line.start.y - point.y) < 0.5)
        #expect(line.start.x == root.minX)
        #expect(line.end.x < root.minX)
        #expect(line.end.x >= max(c1.maxX, c2.maxX) - 0.5)
    }

    @Test func ownSubtreeIsNeverATarget() throws {
        let model = sceneModel()
        let scene = buildScene(model)
        let branch = try #require(scene.nodes["branch-0"]?.frame)
        let leaf = try #require(scene.nodes["leaf-0-0"]?.frame)

        // Hovering the dragged node itself…
        let overSelf = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["branch-0"],
            point: CGPoint(x: branch.midX, y: branch.midY))
        #expect(overSelf == .none)

        // …or any node inside its subtree.
        let overChild = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["branch-0"],
            point: CGPoint(x: leaf.midX, y: leaf.midY))
        #expect(overChild == .none)

        // The parent behind it is still a legal target (hovering the
        // root's left half anchors between the remaining left children).
        let root = try #require(scene.nodes["root"]?.frame)
        let overParent = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["branch-0"],
            point: CGPoint(x: root.midX - 1, y: root.midY))
        #expect(overParent == .reparent(parent: "root", index: 2))
    }

    @Test func emptyCanvasMakesNewRoots() throws {
        let model = sceneModel()
        let scene = buildScene(model)
        let point = CGPoint(x: scene.bounds.maxX + 300, y: scene.bounds.maxY + 300)
        let target = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["leaf-0-0"], point: point)
        #expect(target == .newRoot(at: point))
    }

    @Test func nestedDraggedIdsExcludeTheirWholeSubtree() throws {
        let model = balancedModel()
        let scene = buildScene(model)
        let leaf = try #require(scene.nodes["c1-leaf"]?.frame)

        // Dragging c1 together with its own child: the union subtree is
        // excluded, so hovering the child never targets.
        let overChild = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["c1", "c1-leaf"],
            point: CGPoint(x: leaf.midX, y: leaf.midY))
        #expect(overChild == .none)
        #expect(DragCommands.topmost(["c1", "c1-leaf"], in: model) == ["c1"])

        // Hovering an unrelated node still resolves.
        let c2 = try #require(scene.nodes["c2"]?.frame)
        let target = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["c1", "c1-leaf"],
            point: CGPoint(x: c2.midX, y: c2.minY + 1))
        #expect(target == .reparent(parent: "c2", index: 0))
    }

    @Test func orgChartHoverPicksTheSlotAlongX() throws {
        let model = orgModel()
        let scene = buildScene(model)
        let root = try #require(scene.nodes["root"]?.frame)

        // Siblings stack horizontally below: hovering the root's left
        // edge inserts before both children, the right edge after them.
        let before = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["b"],
            point: CGPoint(x: root.minX + 2, y: root.midY))
        #expect(before == .reparent(parent: "root", index: 0))
        let after = DropTargetResolver.resolve(
            model: model, scene: scene, dragged: ["a"],
            point: CGPoint(x: root.maxX - 2, y: root.midY))
        #expect(after == .reparent(parent: "root", index: 2))
    }
}

// MARK: - command building

/// A drag is exactly one command (F-EDT-5): slot → post-removal index
/// mapping, one group for multi-selection, and no-op suppression.
struct DragCommandsTests {
    @Test func sameParentSlotAdjustsForTheLeavingSibling() throws {
        let model = chainModel()
        // "Insert before y" (model index 2): d currently occupies index
        // 1, so after its own removal the landing index is 1 — its own
        // slot. A drop right back where it came from is a no-op.
        let command = try #require(
            DragCommands.reparent(model: model, dragged: ["d"], parent: "root", slot: 2))
        #expect(command == .moveNode(id: "d", parent: "root", index: 1))
        #expect(DragCommands.isNoOp(command, in: model))
    }

    @Test func crossParentDropKeepsAnchorOrder() throws {
        var model = chainModel()
        model.nodes["p"] = Node(id: "p", parent: "root", title: NodeTitle(text: "p"))
        model.nodes["c0"] = Node(id: "c0", parent: "p", title: NodeTitle(text: "c0"))
        model.nodes["c1"] = Node(id: "c1", parent: "p", title: NodeTitle(text: "c1"))
        model.nodes["p"]?.children = ["c0", "c1"]

        // d (child of root) lands between p's children: before c1.
        let command = try #require(
            DragCommands.reparent(model: model, dragged: ["d"], parent: "p", slot: 1))
        #expect(command == .moveNode(id: "d", parent: "p", index: 1))
        #expect(!DragCommands.isNoOp(command, in: model))
    }

    @Test func multiDragLandsAdjacentInStackingOrder() throws {
        let model = chainModel()
        // Two dragged nodes land consecutively starting at the slot.
        let command = try #require(
            DragCommands.reparent(model: model, dragged: ["d", "y"], parent: "x", slot: 0))
        guard case .group(_, let commands) = command else {
            Issue.record("expected a group, got \(command)")
            return
        }
        #expect(commands == [.moveNode(id: "d", parent: "x", index: 0), .moveNode(id: "y", parent: "x", index: 1)])
    }

    @Test func nestedSelectionReducesToTopmost() {
        var model = chainModel()
        model.nodes["d2"] = Node(id: "d2", parent: "d1", title: NodeTitle(text: "d2"))
        model.nodes["d1"]?.children.append("d2")

        #expect(DragCommands.topmost(["d", "d1", "d2"], in: model) == ["d"])
        #expect(DragCommands.topmost(["x", "y"], in: model) == ["x", "y"])
        #expect(DragCommands.topmost(["y", "d1"], in: model) == ["d1", "y"])
    }

    @Test func detachSkipsRoots() throws {
        let model = chainModel()
        let command = try #require(
            DragCommands.detach(model: model, dragged: ["d", "root"]))
        #expect(command == .detach(id: "d"))
    }

    @Test func offsetsAccumulateAndSnapBack() throws {
        var model = chainModel()
        model.nodes["x"]?.offset = ModelOffset(x: 20, y: 0)

        // An existing offset accumulates; drifting back inside the
        // 24 pt snap radius clears it (F-LAY-11).
        let snapBack = try #require(
            DragCommands.offsets(model: model, dragged: ["x"], delta: CGPoint(x: -10, y: 0)))
        #expect(snapBack == .setOffset(id: "x", offset: nil))

        let moved = try #require(
            DragCommands.offsets(model: model, dragged: ["x"], delta: CGPoint(x: 30, y: 0)))
        #expect(moved == .setOffset(id: "x", offset: ModelOffset(x: 50, y: 0)))

        let fresh = try #require(
            DragCommands.offsets(model: model, dragged: ["y"], delta: CGPoint(x: 2, y: 3)))
        #expect(fresh == .setOffset(id: "y", offset: nil))
    }

    @Test func noOpGroupsSuppress() {
        let model = chainModel()
        let group = MapCommand.group(
            name: "Move Node",
            commands: [
                .moveNode(id: "x", parent: "root", index: 0),
                .moveNode(id: "d", parent: "root", index: 1),
            ])
        #expect(DragCommands.isNoOp(group, in: model))
        #expect(!DragCommands.isNoOp(.moveNode(id: "y", parent: "root", index: 0), in: model))
    }
}

// MARK: - scene manual offsets

/// F-LAY-11: a manual offset moves the node and its subtree, and a
/// descendant's own offset accumulates on top.
struct SceneManualOffsetTests {
    @Test func offsetMovesTheWholeSubtree() throws {
        var model = sceneModel()
        model.nodes["branch-1"]?.offset = ModelOffset(x: 100, y: 60)

        let plain = try #require(buildScene(sceneModel()).nodes["branch-1"]?.frame)
        let scene = buildScene(model)
        let moved = try #require(scene.nodes["branch-1"]?.frame)
        let leaf = try #require(scene.nodes["leaf-1-0"]?.frame)
        let plainLeaf = try #require(buildScene(sceneModel()).nodes["leaf-1-0"]?.frame)

        #expect(abs(moved.minX - plain.minX - 100) < 0.001)
        #expect(abs(moved.minY - plain.minY - 60) < 0.001)
        // Descendants travel along…
        #expect(abs(leaf.minX - plainLeaf.minX - 100) < 0.001)
        #expect(abs(leaf.minY - plainLeaf.minY - 60) < 0.001)
        // …and untouched branches don't move.
        let other = try #require(scene.nodes["branch-0"]?.frame)
        let plainOther = try #require(buildScene(sceneModel()).nodes["branch-0"]?.frame)
        #expect(other == plainOther)
    }
}

// MARK: - interaction (simulated drags)

/// A canvas with the scene centered at scale 1, like the app's fitted
/// view: drag points stay mid-viewport, so auto-scroll never fires
/// unless a test drives right at an edge. Internal: shared with the
/// root-move tests.
@MainActor
final class DragHarness {
    let view: CanvasView
    let scene: CanvasScene

    init(model: MapModel, width: CGFloat = 1200, height: CGFloat = 900) {
        let scene = buildScene(model)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.scene = scene
        view.dragModel = model
        view.camera = Camera(
            origin: CGPoint(
                x: scene.bounds.midX - width / 2,
                y: scene.bounds.midY - height / 2),
            scale: 1)
        self.view = view
        self.scene = scene
    }

    /// The view-space point under a model-space point.
    func screen(_ modelPoint: CGPoint) -> CGPoint {
        view.camera.screenPoint(for: modelPoint)
    }

    /// The model-space center of a node.
    func center(of id: String) throws -> CGPoint {
        let frame = try #require(scene.nodes[id]?.frame)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// mouseDown on `id` (its center), selecting it — or a larger
    /// selection for multi-drags. `shift` pre-arms the F-REL-1
    /// connection drag (⇧ held at grab time).
    func grab(_ id: String, selection: Set<String>? = nil, shift: Bool = false) throws {
        let point = try center(of: id)
        view.setSelection(selection ?? [id])
        view.drag = .pending(
            PendingDrag(
                grabbedID: id,
                startView: screen(point),
                startModel: point,
                shiftDown: shift))
    }

    func drag(to modelPoint: CGPoint) {
        _ = view.handleMouseDragged(screen(modelPoint))
    }

    func drop(at modelPoint: CGPoint) {
        _ = view.handleMouseUp(screen(modelPoint))
    }
}

/// The whole interaction loop, headless: the 4 pt threshold, ghost
/// resolution, modifier drops and the single-command undo contract.
@MainActor
struct CanvasDragInteractionTests {
    @Test func simulatedDragDropsReparentWithOneExactUndoStep() throws {
        let model = sceneModel()
        let harness = DragHarness(model: model)
        let store = MapStore(model: model, undoManager: Self.freshManager())
        let original = store.model
        var dropped: MapCommand?
        var droppedSelection: Set<String> = []
        harness.view.onDrop = { command, selection in
            if let command {
                dropped = command
                droppedSelection = selection
            }
        }

        // Grab branch-1 and drop it on branch-0.
        let start = try harness.center(of: "branch-1")
        try harness.grab("branch-1")

        // Under the threshold nothing happens…
        harness.drag(to: CGPoint(x: start.x + 2, y: start.y + 2))
        guard case .pending = harness.view.drag else {
            Issue.record("a 2 pt move must stay a click")
            return
        }

        // …and crossing it starts the drag, resolving the hovered parent.
        let end = try harness.center(of: "branch-0")
        harness.drag(to: end)
        guard case .active(let session) = harness.view.drag else {
            Issue.record("a >4 pt move must start a drag")
            return
        }
        #expect(session.target == .reparent(parent: "branch-0", index: 1))

        harness.drop(at: end)
        let command = try #require(dropped)
        #expect(command == .moveNode(id: "branch-1", parent: "branch-0", index: 1))
        #expect(droppedSelection == ["branch-1"])

        // The host performs it: one command, one undo step, and a
        // single undo restores the model exactly.
        try store.perform(command)
        // branch-0's only child is centered on it, so the hover lands
        // after it.
        #expect(store.model.nodes["branch-0"]?.children == ["leaf-0-0", "branch-1"])
        #expect(store.model.nodes["root"]?.children == ["branch-0", "branch-2"])
        // The subtree travelled along and the selection stays.
        #expect(store.model.nodes["leaf-1-0"]?.parent == "branch-1")
        harness.view.setSelection(droppedSelection)
        #expect(harness.view.selection == ["branch-1"])

        store.undoManager.undo()
        #expect(Self.journalNormalized(store.model) == Self.journalNormalized(original))
        #expect(!store.undoManager.canUndo)
    }

    @Test func multiDragDropsOneGroupOneUndoStep() throws {
        let model = sceneModel()
        let harness = DragHarness(model: model)
        let store = MapStore(model: model, undoManager: Self.freshManager())
        let original = store.model
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in
            dropped = command
        }

        // Both top-level branches are selected and dragged onto branch-0.
        try harness.grab("branch-1", selection: ["branch-1", "branch-2"])
        let end = try harness.center(of: "branch-0")
        harness.drag(to: end)
        harness.drop(at: end)

        // One grouped command: two moveNodes, stacking-ordered.
        let command = try #require(dropped)
        guard case .group(_, let commands) = command else {
            Issue.record("expected one group, got \(command)")
            return
        }
        #expect(commands.count == 2)
        #expect(commands.contains(.moveNode(id: "branch-1", parent: "branch-0", index: 1)))
        #expect(commands.contains(.moveNode(id: "branch-2", parent: "branch-0", index: 2)))

        try store.perform(command)
        #expect(store.model.nodes["branch-0"]?.children == ["leaf-0-0", "branch-1", "branch-2"])
        #expect(store.model.nodes["root"]?.children == ["branch-0"])

        store.undoManager.undo()
        #expect(Self.journalNormalized(store.model) == Self.journalNormalized(original))
    }

    @Test func subThresholdMotionStaysAClick() throws {
        let harness = DragHarness(model: sceneModel())
        var dropCount = 0
        harness.view.onDrop = { command, _ in
            if command != nil { dropCount += 1 }
        }

        try harness.grab("branch-1")
        let start = try harness.center(of: "branch-1")
        harness.drag(to: CGPoint(x: start.x + 3, y: start.y - 3))
        harness.drop(at: CGPoint(x: start.x + 3, y: start.y - 3))
        #expect(dropCount == 0)
        #expect(harness.view.selection == ["branch-1"])
    }

    @Test func escapeCancelsTheDrag() throws {
        let harness = DragHarness(model: sceneModel())
        var dropCount = 0
        harness.view.onDrop = { command, _ in
            if command != nil { dropCount += 1 }
        }

        try harness.grab("branch-1")
        let start = try harness.center(of: "branch-1")
        let far = CGPoint(x: start.x + 200, y: start.y + 200)
        harness.drag(to: far)
        #expect(harness.view.handleDragKey("\u{1b}", down: true))
        if case .active = harness.view.drag {
            Issue.record("Esc must cancel the drag")
            return
        }
        harness.drop(at: far)
        #expect(dropCount == 0)
    }

    @Test func optionDropFreePositionsViaOffset() throws {
        let model = sceneModel()
        let harness = DragHarness(model: model)
        let store = MapStore(model: model, undoManager: Self.freshManager())
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in
            dropped = command
        }

        // ⌥ held during the drag: keep the parent, set a manual offset.
        try harness.grab("branch-1")
        let start = try harness.center(of: "branch-1")
        harness.drag(to: CGPoint(x: start.x + 5, y: start.y + 5))
        harness.view.handleFlagsChanged(.option)
        let end = CGPoint(x: start.x + 200, y: start.y)
        harness.drag(to: end)
        harness.drop(at: end)

        let command = try #require(dropped)
        #expect(command == .setOffset(id: "branch-1", offset: ModelOffset(x: 200, y: 0)))

        // The offset survives the round-trip and moves the scene subtree.
        try store.perform(command)
        #expect(store.model.nodes["branch-1"]?.offset == ModelOffset(x: 200, y: 0))
        let moved = buildScene(store.model)
        #expect(try #require(moved.nodes["branch-1"]?.frame).midX > start.x + 100)
    }

    @Test func detachKeyDropsDetachedRoots() throws {
        let model = sceneModel()
        let harness = DragHarness(model: model)
        let store = MapStore(model: model, undoManager: Self.freshManager())
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in
            dropped = command
        }

        // "D" held during the drag: detach into a new root.
        try harness.grab("branch-1")
        let start = try harness.center(of: "branch-1")
        harness.drag(to: CGPoint(x: start.x + 5, y: start.y + 5))
        #expect(harness.view.handleDragKey("d", down: true))
        let end = CGPoint(x: start.x + 300, y: start.y)
        harness.drag(to: end)
        harness.drop(at: end)

        let command = try #require(dropped)
        #expect(command == .detach(id: "branch-1"))
        try store.perform(command)
        #expect(store.model.roots == ["root", "branch-1"])
        #expect(store.model.nodes["root"]?.children == ["branch-0", "branch-2"])
    }

    @Test func spaceDropCreatesAConnection() throws {
        let harness = DragHarness(model: sceneModel())
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in
            if let command { dropped = command }
        }

        // Space held during the drag (F-REL-1): the drop over another
        // node is ONE addConnection command — one undo step — and the
        // dragged node stays where it was (no reparent).
        try harness.grab("branch-1")
        let start = try harness.center(of: "branch-1")
        harness.drag(to: CGPoint(x: start.x + 5, y: start.y + 5))
        #expect(harness.view.handleDragKey(" ", down: true))
        let end = try harness.center(of: "branch-0")
        harness.drag(to: end)
        harness.drop(at: end)

        var store = MapStore(model: harness.view.dragModel ?? sceneModel())
        let before = store.model
        if let command = dropped {
            try store.perform(command)
        }
        guard case .addConnection(let connection)? = dropped else {
            Issue.record("expected an addConnection drop, got \(String(describing: dropped))")
            return
        }
        #expect(Set([connection.from, connection.to]) == Set(["branch-1", "branch-0"]))
        #expect(store.model.connections?.count == 1)
        // One undo step back to the pre-drop model.
        store.undoManager.undo()
        #expect(store.model == before)

        // Dropping on the dragged node itself (or empty canvas) still
        // performs nothing.
        dropped = nil
        try harness.grab("branch-1")
        harness.drag(to: CGPoint(x: start.x + 5, y: start.y + 5))
        #expect(harness.view.handleDragKey(" ", down: true))
        harness.drag(to: start)
        harness.drop(at: start)
        #expect(dropped == nil)
    }

    @Test func shiftDragDropsAConnection() throws {
        let harness = DragHarness(model: sceneModel())
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in
            if let command { dropped = command }
        }

        // ⇧ held from the grab (F-REL-1): node-to-node drop connects.
        try harness.grab("branch-1", shift: true)
        let start = try harness.center(of: "branch-1")
        harness.drag(to: CGPoint(x: start.x + 5, y: start.y + 5))
        let end = try harness.center(of: "branch-0")
        harness.drag(to: end)
        harness.drop(at: end)
        guard case .addConnection(let connection)? = dropped else {
            Issue.record("expected an addConnection drop, got \(String(describing: dropped))")
            return
        }
        #expect(Set([connection.from, connection.to]) == Set(["branch-1", "branch-0"]))

        // Already connected: the same drop performs nothing. Apply the
        // first command to the drag model first.
        var model = try #require(harness.view.dragModel)
        try MapCommand.addConnection(connection).apply(to: &model)
        harness.view.dragModel = model
        dropped = nil
        try harness.grab("branch-1", shift: true)
        harness.drag(to: end)
        harness.drop(at: end)
        #expect(dropped == nil)
    }

    @Test func draggingNearTheEdgeAutoScrolls() throws {
        let harness = DragHarness(model: sceneModel(), width: 800, height: 600)

        // Dragging toward the right edge pans the camera with it.
        try harness.grab("branch-1")
        let start = try harness.center(of: "branch-1")
        harness.drag(to: start)
        let originBefore = harness.view.camera.origin.x
        _ = harness.view.handleMouseDragged(CGPoint(x: 790, y: 300))
        #expect(harness.view.camera.origin.x > originBefore)
        // The ghost's model delta follows the panned cursor: without the
        // pan it would be exactly the (790 − 710) screen move.
        guard case .active(let session) = harness.view.drag else {
            Issue.record("expected an active drag")
            return
        }
        #expect(session.deltaModel.x > 80)
    }

    // MARK: store helpers

    /// The manager with event grouping off, so one `undo()` undoes
    /// exactly one store step.
    private static func freshManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }

    /// Zeroes the journal fields the store stamps on every touch.
    private static func journalNormalized(_ model: MapModel) -> MapModel {
        var copy = model
        for (id, _) in copy.nodes {
            copy.nodes[id]?.modified = Date(timeIntervalSince1970: 0)
            copy.nodes[id]?.modifiedBy = .user
        }
        return copy
    }
}

// MARK: - reordering and the Node Well "+"

/// `sceneModel` with every branch fanned to the right, so siblings stack
/// in one column.
private func rightModel() -> MapModel {
    var model = sceneModel()
    model.nodes["root"]?.structure = "mindmap.right"
    return model
}

@MainActor
struct SiblingReorderTests {
    private func command(
        dragging id: String, to point: (CanvasScene) throws -> CGPoint
    ) throws -> (MapCommand?, DropTarget?) {
        let harness = DragHarness(model: rightModel())
        var dropped: MapCommand?
        harness.view.onDrop = { command, _ in dropped = command }
        try harness.grab(id)
        let start = try harness.center(of: id)
        harness.drag(to: CGPoint(x: start.x + 6, y: start.y + 6))
        let end = try point(harness.scene)
        harness.drag(to: end)
        var target: DropTarget?
        if case .active(let session) = harness.view.drag { target = session.target }
        harness.drop(at: end)
        return (dropped, target)
    }

    @Test func dragBelowTheLastSiblingMovesItToTheEnd() throws {
        let (dropped, target) = try command(dragging: "branch-0") { scene in
            let last = try #require(scene.nodes["branch-2"]?.frame)
            return CGPoint(x: last.midX, y: last.maxY + 120)
        }
        guard case .insertBetween(let parent, let index, _)? = target else {
            Issue.record("expected an insertion slot, got \(String(describing: target))")
            return
        }
        #expect(parent == "root")
        #expect(index == 3)
        #expect(dropped == .moveNode(id: "branch-0", parent: "root", index: 2))
    }

    @Test func dragAboveTheFirstSiblingMovesItToTheFront() throws {
        let (dropped, _) = try command(dragging: "branch-2") { scene in
            let first = try #require(scene.nodes["branch-0"]?.frame)
            return CGPoint(x: first.midX, y: first.minY - 120)
        }
        #expect(dropped == .moveNode(id: "branch-2", parent: "root", index: 0))
    }

    @Test func letGoOnEmptyCanvasSnapsBackInsteadOfDetaching() throws {
        let (dropped, target) = try command(dragging: "branch-1") { scene in
            CGPoint(x: scene.bounds.maxX + 400, y: scene.bounds.minY - 400)
        }
        guard case .newRoot? = target else {
            Issue.record("far from everything should resolve to empty canvas, got \(String(describing: target))")
            return
        }
        #expect(dropped == nil)
    }
}

@MainActor
struct NodeWellHandleTests {
    @Test func aChildNodeOffersOnePlusOnItsOuterEdge() throws {
        let scene = buildScene(rightModel())
        let handles = AddHandleResolver.handles(for: "branch-1", in: scene)
        #expect(handles.map(\.side) == [.right])
        let frame = try #require(scene.nodes["branch-1"]?.frame)
        #expect(handles.first?.anchor == CGPoint(x: frame.maxX, y: frame.midY))
    }

    @Test func aBalancedRootOffersBothSides() throws {
        let scene = buildScene(sceneModel())
        let handles = AddHandleResolver.handles(for: "root", in: scene)
        #expect(Set(handles.map(\.side)) == [.left, .right])
    }

    @Test func aOneSidedRootOffersOnlyItsSide() throws {
        let scene = buildScene(rightModel())
        #expect(
            AddHandleResolver.handles(for: "root", in: scene, rootStructure: .mindmapRight)
                .map(\.side) == [.right])
    }

    // MARK: a root's sides come from its declared structure (SPEC §6.2)

    /// A balanced root always offers both sides — even when every
    /// existing child sits on the right (the layout may look one-sided,
    /// but a left child stays legal), and when it has no children.
    @Test func aBalancedRootOffersBothSidesWhateverItsChildrenDo() throws {
        let both = buildScene(sceneModel())
        #expect(
            Set(
                AddHandleResolver.handles(for: "root", in: both, rootStructure: nil)
                    .map(\.side)) == [.left, .right])

        var pinnedRight = sceneModel()
        for id in pinnedRight.nodes["root"]?.children ?? [] {
            pinnedRight.nodes[id]?.side = .right
        }
        let right = buildScene(pinnedRight)
        #expect(
            Set(
                AddHandleResolver.handles(for: "root", in: right, rootStructure: .mindmapBalanced)
                    .map(\.side)) == [.left, .right],
            "children all pinned right must not hide the left plus")

        var childless = sceneModel()
        childless.nodes["root"]?.children = []
        for id in ["branch-0", "branch-1", "branch-2"] {
            childless.nodes.removeValue(forKey: id)
        }
        let empty = buildScene(childless)
        #expect(
            Set(
                AddHandleResolver.handles(for: "root", in: empty, rootStructure: nil)
                    .map(\.side)) == [.left, .right])
    }

    @Test func oneSidedStructuresRestrictToTheirSide() {
        #expect(AddHandleResolver.rootSides(structure: .mindmapRight) == [.right])
        #expect(AddHandleResolver.rootSides(structure: .mindmapLeft) == [.left])
        #expect(AddHandleResolver.rootSides(structure: .logicChartRight) == [.right])
        #expect(AddHandleResolver.rootSides(structure: .mindmapBalanced) == [.left, .right])
    }

    @Test func orgChartsGrowVertically() throws {
        let scene = buildScene(orgModel())
        #expect(
            AddHandleResolver.handles(for: "root", in: scene, rootStructure: .orgDown)
                .map(\.side) == [.below])
        #expect(AddHandleResolver.rootSides(structure: .orgUp) == [.above])
        // A child of a vertical chart grows away from its parent: the
        // outer edge is below the parent's.
        #expect(
            AddHandleResolver.handles(for: "a", in: scene).map(\.side) == [.below])
    }

    @Test func aLeftBranchPutsItsPlusOnTheLeft() throws {
        var model = sceneModel()
        model.nodes["root"]?.structure = "mindmap.left"
        let scene = buildScene(model)
        #expect(AddHandleResolver.handles(for: "branch-1", in: scene).map(\.side) == [.left])
    }

    @Test func selectingANodeShowsItsPlusAndClickingAddsAChild() throws {
        let harness = DragHarness(model: rightModel())
        harness.view.setSelection(["branch-1"])
        let handle = try #require(harness.view.layerTree.addHandles.first)
        #expect(harness.view.layerTree.addHandleLayers.count == 1)

        var added: (String, AddHandleSide)?
        harness.view.onAddChildAtHandle = { added = ($0, $1) }
        let center = handle.center(camera: harness.view.camera)
        #expect(harness.view.addHandle(at: center)?.nodeID == "branch-1")
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        harness.view.mouseDown(with: event)
        #expect(added?.0 == "branch-1")
        #expect(added?.1 == .right)

        // Nothing selected, or several: no plus.
        harness.view.setSelection([])
        #expect(harness.view.layerTree.addHandles.isEmpty)
        harness.view.setSelection(["branch-0", "branch-1"])
        #expect(harness.view.layerTree.addHandles.isEmpty)
    }

    @Test func plusHidesWhileEditing() throws {
        let harness = DragHarness(model: rightModel())
        harness.view.setSelection(["branch-1"])
        #expect(!harness.view.layerTree.addHandles.isEmpty)
        harness.view.beginEditing(nodeID: "branch-1")
        #expect(harness.view.layerTree.addHandles.isEmpty)
    }

    @Test func deleteKeyDeletesTheSelectionAndOptionDeleteTheNodeOnly() throws {
        let harness = DragHarness(model: rightModel())
        var calls: [Bool] = []
        harness.view.onDeleteSelection = { calls.append($0) }
        func key(_ character: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: 51))
        }
        harness.view.setSelection(["branch-1"])
        harness.view.keyDown(with: try key("\u{7f}", []))
        harness.view.keyDown(with: try key("\u{f728}", []))
        harness.view.keyDown(with: try key("\u{7f}", [.option]))
        #expect(calls == [false, false, true])
    }
}
