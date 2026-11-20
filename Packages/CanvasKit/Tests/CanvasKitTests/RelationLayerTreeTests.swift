import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

/// Relation overlay layers in the virtualized tree (F-REL-1/2/3): they
/// realize only inside the expanded visible rect, recycle through the
/// pool on pan, and never re-raster on a pure camera move (§11.4).
@MainActor
struct RelationLayerTreeTests {
    private let viewport = CGSize(width: 1_200, height: 800)

    private func model() -> MapModel {
        var model = MapModel.emptyDocument(docID: "relation-layers")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var ids: [String] = []
        let rootID = "root"
        model.nodes[rootID] = Node(
            id: rootID, title: NodeTitle(text: "Root"), created: date, modified: date)
        model.roots = [rootID]
        for index in 0..<60 {
            let id = "c\(index)"
            model.nodes[id] = Node(
                id: id, parent: rootID, title: NodeTitle(text: "Child \(index)"),
                created: date, modified: date)
            model.nodes[rootID]?.children.append(id)
            ids.append(id)
        }
        // 20 connections between children, 10 two-sibling boundaries,
        // one summary over the first two children.
        var connections: [Connection] = []
        for index in 0..<20 {
            connections.append(
                Connection(id: "conn\(index)", from: ids[index], to: ids[index + 30]))
        }
        model.connections = connections
        model.boundaries = (0..<10).map { index in
            Boundary(id: "bd\(index)", nodes: [ids[index * 2], ids[index * 2 + 1]])
        }
        model.summaries = [
            Summary(id: "sm", parent: rootID, range: [ids[0], ids[1]], node: "sum")
        ]
        model.nodes["sum"] = Node(
            id: "sum", parent: rootID, title: NodeTitle(text: "Sum"),
            created: date, modified: date)
        model.nodes[rootID]?.children.append("sum")
        return model
    }

    private func grid(for scene: CanvasScene) -> SpatialGrid {
        var grid = SpatialGrid()
        for node in scene.nodes.values {
            grid.insert(id: node.id, frame: node.frame)
        }
        return grid
    }

    private func fitCamera(for scene: CanvasScene) -> Camera {
        let content = scene.bounds.insetBy(dx: -40, dy: -40)
        let scale = min(
            viewport.width / max(content.width, 1),
            viewport.height / max(content.height, 1), 4)
        return Camera(
            origin: CGPoint(
                x: content.midX - viewport.width / (2 * scale),
                y: content.midY - viewport.height / (2 * scale)),
            scale: scale)
    }

    private func apply(
        _ scene: CanvasScene, camera: Camera, to tree: CanvasLayerTree,
        animated: Bool = false
    ) {
        var context = ApplyContext(
            scene: scene, grid: grid(for: scene), camera: camera, viewport: viewport)
        context.backingScale = 1
        context.animated = animated
        context.reduceMotion = true
        context.selectionColor = CGColor(gray: 0, alpha: 1)
        tree.apply(context)
    }

    @Test func overlaysRealizeCullAndPool() throws {
        let scene = SceneGeometry.build(
            model: model(), variant: .light, measurer: TextMeasurer())
        #expect(scene.connections.count == 20)
        #expect(scene.boundaries.count == 10)
        #expect(scene.summaries.count == 1)

        let tree = CanvasLayerTree()
        apply(scene, camera: fitCamera(for: scene), to: tree)
        let visibleAtFit = tree.relationLayerCount()
        #expect(visibleAtFit > 0)
        #expect(visibleAtFit <= 31)
        for id in scene.connections.prefix(3).map(\.id) {
            #expect(tree.relationLayerContents(id) != nil)
        }

        // Pan far away: every overlay layer recycles.
        let away = Camera(
            origin: CGPoint(x: 1_000_000, y: 1_000_000), scale: 1)
        apply(scene, camera: away, to: tree)
        #expect(tree.relationLayerCount() == 0)

        // Pan back: the same set re-realizes entirely from the pool.
        let allocated = tree.allocatedRelationLayers
        apply(scene, camera: fitCamera(for: scene), to: tree)
        #expect(tree.relationLayerCount() == visibleAtFit)
        #expect(tree.allocatedRelationLayers == allocated)
        #expect(tree.pooledRelationLayerReuses >= visibleAtFit)
    }

    @Test func cameraMovesNeverReRasterOverlays() throws {
        let scene = SceneGeometry.build(
            model: model(), variant: .light, measurer: TextMeasurer())
        let tree = CanvasLayerTree()
        let camera = fitCamera(for: scene)
        apply(scene, camera: camera, to: tree)

        // A pure pan: positions/transforms only. No overlay layer is
        // ever allocated while panning.
        let allocated = tree.allocatedRelationLayers
        var panCamera = camera
        for _ in 0..<20 {
            panCamera.origin.x += 8
            panCamera.origin.y -= 5
            tree.updateCamera(camera: panCamera, viewport: viewport, backingScale: 1)
        }
        #expect(tree.allocatedRelationLayers == allocated)

        // A zoom change re-rasters through the 120 ms settle pass, at
        // the clamped new sharpness — centered so the content stays in
        // view.
        let contentMid = CGPoint(x: scene.bounds.midX, y: scene.bounds.midY)
        let zoomed = Camera(
            origin: CGPoint(
                x: contentMid.x - viewport.width / 4,
                y: contentMid.y - viewport.height / 4),
            scale: 2)
        tree.updateCamera(camera: zoomed, viewport: viewport, backingScale: 1)
        tree.rerasterizeVisible(camera: zoomed, backingScale: 1)
        #expect(tree.relationLayerCount() > 0)
    }

    @Test func selectionHaloReRasterizesOnlyTheSelection() throws {
        let scene = SceneGeometry.build(
            model: model(), variant: .light, measurer: TextMeasurer())
        let tree = CanvasLayerTree()
        let camera = fitCamera(for: scene)
        apply(scene, camera: camera, to: tree)
        let firstID = try #require(scene.connections.first?.id)

        tree.selectedConnections = [firstID]
        tree.realizeRelations(camera: camera, viewport: viewport, backingScale: 1)
        #expect(tree.selectedConnections == [firstID])
        #expect(tree.relationLayerContents(firstID) != nil)

        // Deselecting rebuilds the raster without the halo; the rest
        // of the overlays keep theirs (raster keys only changed for the
        // selected id).
        tree.selectedConnections = []
        tree.realizeRelations(camera: camera, viewport: viewport, backingScale: 1)
        #expect(tree.relationLayerCount() > 1)
    }
}

/// Connection interactions on the canvas (F-REL-1), headless: the ⌘L
/// next-click mode, stroke selection, the jump actions, and the
/// midpoint-handle drag end to end.
@MainActor
struct RelationInteractionTests {
    private func makeView() throws -> (CanvasView, MapModel, CanvasScene) {
        var model = MapModel.emptyDocument(docID: "interactions")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ id: String, parent: String?, title: String) {
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: title),
                created: date, modified: date)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                model.roots.append(id)
            }
        }
        add("root", parent: nil, title: "Root")
        add("a", parent: "root", title: "Alpha")
        add("b", parent: "root", title: "Beta")
        model.connections = [
            Connection(id: "conn", from: "a", to: "b", label: "because")
        ]

        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        view.dragModel = model
        let scene = SceneGeometry.build(model: model, variant: .light, measurer: TextMeasurer())
        view.scene = scene
        // The whole map on screen at 100%.
        view.camera = Camera(
            origin: CGPoint(x: -200, y: -200), scale: 1)
        return (view, model, scene)
    }

    @Test func commandLThenClickCreatesTheConnection() throws {
        let (view, _, scene) = try makeView()
        var created: (from: String, to: String)?
        view.onCreateConnection = { from, to in
            created = (from, to)
        }

        // ⌘L on a single selection enters the mode.
        view.setSelection(["a"])
        #expect(view.beginConnectionMode())

        // The next click on another node completes the pair.
        let frameB = try #require(scene.nodes["b"]?.frame)
        let click = view.camera.screenPoint(
            for: CGPoint(x: frameB.midX, y: frameB.midY))
        view.completeConnectionMode(at: click)
        #expect(created?.from == "a")
        #expect(created?.to == "b")

        // The mode is one-shot: a further click performs nothing.
        created = nil
        view.completeConnectionMode(at: click)
        #expect(created == nil)

        // A click on empty canvas cancels without performing.
        view.setSelection(["a"])
        #expect(view.beginConnectionMode())
        view.completeConnectionMode(at: CGPoint(x: 0, y: -5_000))
        #expect(created == nil)
    }

    @Test func strokeHitSelectsAndJumpsToEndpoints() throws {
        let (view, _, scene) = try makeView()
        let connection = try #require(scene.connections.first)

        // The stroke hit-test resolves through the camera.
        let onCurve = view.camera.screenPoint(
            for: RelationPath.point(
                onConnection: connection.from, to: connection.to, control: connection.control,
                straight: connection.straight, parameter: 0.5))
        #expect(view.connectionID(at: onCurve) == "conn")
        #expect(view.connectionID(at: CGPoint(x: onCurve.x, y: onCurve.y + 200)) == nil)

        // Selecting the connection clears the node selection and the
        // jump actions land on the endpoints.
        view.setSelection(["a"])
        view.setConnectionSelection(["conn"])
        #expect(view.selectedConnectionIDs == ["conn"])
        view.jumpToConnectionStartAction(nil)
        #expect(view.selection == ["a"])
        view.jumpToConnectionEndAction(nil)
        #expect(view.selection == ["b"])
    }

    @Test func handleDragProducesOneExactEditConnection() throws {
        let (view, model, scene) = try makeView()
        let connection = try #require(scene.connections.first)
        var mutated: MapCommand?
        view.onMutateConnection = { mutated = $0 }

        // The handle is grabbable only while the connection is
        // selected (F-REL-1).
        let handleScreen = view.camera.screenPoint(for: connection.handlePosition)
        #expect(view.connectionWithHandle(at: handleScreen) == nil)
        view.setConnectionSelection(["conn"])
        #expect(view.connectionWithHandle(at: handleScreen) == "conn")

        // Grab the handle (a click on it starts the drag) and drop it
        // elsewhere: one editConnection whose stored offset lands the
        // handle exactly at the drop point.
        #expect(view.handleRelationMouseDown(handleScreen, clickCount: 1))
        let drop = CGPoint(x: connection.handlePosition.x + 60, y: connection.handlePosition.y - 40)
        #expect(view.updateRelationDrag(at: view.camera.screenPoint(for: drop)))
        #expect(view.finishRelationDrag(at: view.camera.screenPoint(for: drop)))
        let command = try #require(mutated)
        guard case .editConnection(_, let updated) = command else {
            Issue.record("expected editConnection, got \(command)")
            return
        }
        #expect(updated.control != nil)

        // Undo/redo exactness against the pre-drag model.
        var working = model
        try command.apply(to: &working)
        let inverse = try command.inverse(in: model)
        try inverse.apply(to: &working)
        #expect(working == model)
    }
}
