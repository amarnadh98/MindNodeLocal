import AppKit
import CoreGraphics
import MapCore
import Testing

@testable import CanvasKit

/// Headless tests for the canvas's accessibility surface (SPEC §11.6,
/// M1 slice 7c): one outline row per visible node with label, value,
/// hierarchy and custom actions; frames that follow the camera; the
/// container's selected children; and custom actions routed through the
/// host-set closures.
@MainActor
struct CanvasAccessibilityTests {
    @Test func exposesOneRowPerVisibleNode() throws {
        let view = Self.makeCanvas()

        // The canvas is a labelled container, not an element itself.
        #expect(view.isAccessibilityElement() == false)
        #expect(view.accessibilityRole() == .group)
        #expect(view.accessibilityLabel() == "Test Map")

        let children = try #require(view.accessibilityChildren())
        #expect(children.count == 7)
        let rows = children.compactMap { $0 as? CanvasAccessibilityElement }
        #expect(rows.count == 7)
        #expect(rows.count == view.dragModel?.nodes.count)
        for row in rows {
            #expect(row.accessibilityRole() == .row)
            #expect(row.accessibilityParent() as? CanvasView === view)
        }
        #expect(
            rows.map(\.nodeID)
                == ["root", "branch-0", "leaf-0-0", "branch-1", "leaf-1-0", "branch-2", "leaf-2-0"])
    }

    @Test func labelsReadTitlesAndEmptyNodesSaySo() throws {
        var model = sceneModel()
        model.nodes["branch-0"]?.title = NodeTitle(text: "  ")
        let view = Self.makeCanvas(model: model)

        let row = try #require(Self.row("root", in: view))
        #expect(row.accessibilityLabel() == "Central Idea")
        // Whitespace-only titles read as empty (F-CAN-3's placeholder is
        // a hint, never text).
        #expect(try Self.row("branch-0", in: view)?.accessibilityLabel() == "Empty node")
        #expect(try Self.row("leaf-0-0", in: view)?.accessibilityLabel() == "leaf 0")
    }

    @Test func valuesDescribeSubtreesAndFolding() throws {
        let view = Self.makeCanvas()

        #expect(try Self.value("root", in: view) == "3 children, expanded")
        #expect(try Self.value("branch-0", in: view) == "1 child, expanded")
        #expect(try Self.value("leaf-0-0", in: view) == "leaf")

        // Task-progress hook text (SPEC §11.6; tasks themselves land in
        // M3, so only the hook is exercised here).
        view.accessibility.taskProgressText = { id in id == "leaf-0-0" ? "task 1 of 3 done" : nil }
        view.accessibility.needsRebuild = true
        #expect(try Self.value("leaf-0-0", in: view) == "leaf, task 1 of 3 done")
        #expect(try Self.value("leaf-1-0", in: view) == "leaf")

        // Folding prunes the subtree from the scene (F-LAY-14): its row
        // disappears and the folded parent reports "collapsed".
        var folded = sceneModel()
        folded.nodes["branch-0"]?.folded = true
        let foldedView = Self.makeCanvas(model: folded)
        #expect(foldedView.accessibilityChildren()?.count == 6)
        #expect(try Self.value("branch-0", in: foldedView) == "1 child, collapsed")
        #expect(try Self.row("branch-0", in: foldedView)?.isAccessibilityDisclosed() == false)
        #expect(try Self.row("branch-1", in: foldedView)?.isAccessibilityDisclosed() == true)
        // The folded node's child is gone from the canvas's rows.
        #expect(
            foldedView.accessibilityChildren()?.contains {
                ($0 as? CanvasAccessibilityElement)?.nodeID == "leaf-0-0"
            } == false)
    }

    @Test func rowsLinkParentsAndChildren() throws {
        let view = Self.makeCanvas()

        let root = try #require(Self.row("root", in: view))
        let branch0 = try #require(Self.row("branch-0", in: view))
        let leaf = try #require(Self.row("leaf-0-0", in: view))

        // Disclosed rows: the visible children, in model order.
        let rootChildren = try #require(root.accessibilityChildren())
        #expect(
            rootChildren.compactMap { ($0 as? CanvasAccessibilityElement)?.nodeID }
                == ["branch-0", "branch-1", "branch-2"])
        let disclosed = try #require(root.accessibilityDisclosedRows() as? [Any])
        #expect(
            disclosed.compactMap { ($0 as? CanvasAccessibilityElement)?.nodeID }
                == ["branch-0", "branch-1", "branch-2"])

        // Disclosed by row: the parent, roots have none.
        #expect(
            (branch0.accessibilityDisclosedByRow() as? CanvasAccessibilityElement)?.nodeID == "root")
        #expect((leaf.accessibilityDisclosedByRow() as? CanvasAccessibilityElement)?.nodeID == "branch-0")
        #expect(root.accessibilityDisclosedByRow() == nil)

        // A folded parent discloses nothing.
        var folded = sceneModel()
        folded.nodes["branch-0"]?.folded = true
        let foldedView = Self.makeCanvas(model: folded)
        #expect(try Self.row("branch-0", in: foldedView)?.accessibilityChildren()?.isEmpty == true)
    }

    @Test func framesFollowTheCamera() throws {
        let view = Self.makeCanvas()
        let row = try #require(Self.row("root", in: view))

        let before = row.frameInView()
        #expect(before.width > 0)
        #expect(before.height > 0)

        // Panning moves the frame by the scaled delta, zoom scales it.
        view.camera = Camera(origin: CGPoint(x: 40, y: 20), scale: 1)
        let panned = row.frameInView()
        #expect(abs(panned.minX - (before.minX - 40)) < 0.001)
        #expect(abs(panned.minY - (before.minY - 20)) < 0.001)

        view.camera = Camera(origin: .zero, scale: 2)
        let zoomed = row.frameInView()
        #expect(abs(zoomed.width - 2 * before.width) < 0.001)
        #expect(abs(zoomed.height - 2 * before.height) < 0.001)
        #expect(abs(zoomed.minX - 2 * before.minX) < 0.001)
    }

    @Test func selectionMarksRowsAndContainerSelectedChildren() throws {
        let view = Self.makeCanvas()

        let root = try #require(Self.row("root", in: view))
        #expect(root.isAccessibilitySelected() == false)

        view.setSelection(["root"])
        #expect(root.isAccessibilitySelected() == true)
        let selected = try #require(view.accessibilitySelectedChildren())
        #expect(selected.count == 1)
        #expect((selected.first as? CanvasAccessibilityElement)?.nodeID == "root")

        // Selection flags refresh on every change, without a rebuild.
        view.setSelection(["root", "branch-0"])
        #expect(root.isAccessibilitySelected() == true)
        #expect(try Self.row("branch-0", in: view)?.isAccessibilitySelected() == true)
        #expect(try Self.row("branch-1", in: view)?.isAccessibilitySelected() == false)
        #expect(view.accessibilitySelectedChildren()?.count == 2)

        view.setSelection([])
        #expect(root.isAccessibilitySelected() == false)
        #expect(view.accessibilitySelectedChildren()?.isEmpty == true)
    }

    @Test func customActionsMatchNodeType() throws {
        let view = Self.makeCanvas()

        func names(_ id: String) throws -> [String] {
            try #require(Self.row(id, in: view)?.accessibilityCustomActions()).map(\.name)
        }
        // Nodes with children offer Fold, folded nodes offer Unfold,
        // leaves offer neither.
        #expect(try names("root") == ["Add Child", "Add Sibling", "Fold", "Edit"])
        #expect(try names("leaf-0-0") == ["Add Child", "Add Sibling", "Edit"])

        var folded = sceneModel()
        folded.nodes["branch-0"]?.folded = true
        let foldedView = Self.makeCanvas(model: folded)
        let actions = try #require(Self.row("branch-0", in: foldedView)?.accessibilityCustomActions())
        #expect(actions.map(\.name) == ["Add Child", "Add Sibling", "Unfold", "Edit"])
    }

    @Test func customActionsRouteThroughTheHostClosures() throws {
        let view = Self.makeCanvas()

        var addChild: [String] = []
        var addSibling: [String] = []
        var fold: [String] = []
        var edit: [String] = []
        view.accessibility.onAddChild = { addChild.append($0) }
        view.accessibility.onAddSibling = { addSibling.append($0) }
        view.accessibility.onToggleFold = { fold.append($0) }
        view.accessibility.onEdit = { edit.append($0) }

        // VoiceOver performs actions through the handler — the exact path
        // AppKit invokes.
        let row = try #require(Self.row("branch-1", in: view))
        let actions = try #require(row.accessibilityCustomActions())
        #expect(actions.count == 4)
        #expect(actions[0].name == "Add Child")
        #expect(actions[0].handler?() == true)
        #expect(addChild == ["branch-1"])
        #expect(actions[1].handler?() == true)
        #expect(addSibling == ["branch-1"])
        #expect(actions[2].handler?() == true)
        #expect(fold == ["branch-1"])
        #expect(actions[3].handler?() == true)
        #expect(edit == ["branch-1"])
        #expect(addChild.count == 1 && addSibling.count == 1 && fold.count == 1 && edit.count == 1)
    }

    @Test func sceneChangesRebuildTheRows() throws {
        let view = Self.makeCanvas()

        var renamed = sceneModel()
        renamed.nodes["root"]?.title = NodeTitle(text: "Renamed")
        renamed.nodes["branch-1"]?.children.append("fresh")
        renamed.nodes["fresh"] = Node(
            id: "fresh", parent: "branch-1", title: NodeTitle(text: "new leaf"),
            created: sceneDate, modified: sceneDate)
        let scene = SceneGeometry.build(
            model: renamed, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        view.dragModel = renamed
        view.scene = scene

        #expect(view.accessibilityChildren()?.count == 8)
        #expect(try Self.row("root", in: view)?.accessibilityLabel() == "Renamed")
        #expect(try Self.value("branch-1", in: view) == "2 children, expanded")
    }

    @Test func containerLabelFallsBackWithoutTheHostClosure() throws {
        let view = Self.makeCanvas()
        view.accessibility.containerLabel = nil
        #expect(view.accessibilityLabel() == "Mind Map")
    }

    // MARK: helpers

    private static func makeCanvas(model: MapModel = sceneModel()) -> CanvasView {
        let scene = SceneGeometry.build(
            model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.accessibility.containerLabel = { "Test Map" }
        view.dragModel = model
        view.scene = scene
        return view
    }

    private static func row(_ id: String, in view: CanvasView) -> CanvasAccessibilityElement? {
        view.accessibilityChildren()?.first { ($0 as? CanvasAccessibilityElement)?.nodeID == id }
            as? CanvasAccessibilityElement
    }

    private static func value(_ id: String, in view: CanvasView) -> String? {
        row(id, in: view)?.accessibilityValue() as? String
    }
}
