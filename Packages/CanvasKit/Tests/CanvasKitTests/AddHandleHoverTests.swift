import AppKit
import CoreGraphics
import Foundation
import MapCore
import Testing

@testable import CanvasKit

// MARK: - fixtures

/// A balanced root with one pinned child on each side, nothing else —
/// lots of empty canvas around every node, so hover probes can't
/// accidentally hit a neighbour.
private func hoverModel() -> MapModel {
    var model = MapModel.emptyDocument(docID: "hover")
    var root = Node(id: "root", title: NodeTitle(text: "Central Idea"))
    root.created = sceneDate
    root.modified = sceneDate
    model.nodes["root"] = root
    model.roots = ["root"]
    for (id, pin) in [("solo-right", SidePin.right), ("solo-left", .left)] {
        var node = Node(id: id, parent: "root", title: NodeTitle(text: id))
        node.side = pin
        node.created = sceneDate
        node.modified = sceneDate
        model.nodes[id] = node
        model.nodes["root"]?.children.append(id)
    }
    return model
}

// MARK: - tests

/// The hover half of the Node Well (SPEC §6.2), headless: the "+"
/// shows for the node under the pointer without a click, a grace band
/// keeps it alive while the pointer travels out to the button, and the
/// editing, drag, ⌘L and Space-pan gates hide it.
@MainActor
struct AddHandleHoverTests {
    private func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func hoveringANodeShowsItsPlusWithoutSelectingIt() throws {
        let harness = DragHarness(model: hoverModel())
        #expect(harness.view.layerTree.addHandles.isEmpty, "idle canvas shows no plus")

        let center = try harness.center(of: "solo-right")
        harness.view.mouseMoved(with: try event(.mouseMoved, at: harness.screen(center)))
        #expect(harness.view.selection.isEmpty)
        #expect(harness.view.layerTree.addHandles.map(\.nodeID) == ["solo-right"])
        #expect(harness.view.layerTree.addHandles.map(\.side) == [.right])

        // Clicking the hover plus adds a child on that side — the node
        // never has to be selected first.
        var added: (String, AddHandleSide)?
        harness.view.onAddChildAtHandle = { added = ($0, $1) }
        let handle = try #require(harness.view.layerTree.addHandles.first)
        harness.view.mouseDown(with: try event(.leftMouseDown, at: handle.center(camera: harness.view.camera)))
        #expect(added?.0 == "solo-right")
        #expect(added?.1 == .right)
    }

    @Test func theGraceBandKeepsThePlusAliveUntilThePointerReachesIt() throws {
        let harness = DragHarness(model: hoverModel())
        let frame = try #require(harness.scene.nodes["solo-right"]?.frame)
        let edge = harness.screen(CGPoint(x: frame.maxX, y: frame.midY))

        // Hover the node first, then travel out towards its "+" (the
        // button center sits 18 pt from the edge): the hover holds all
        // the way to the button.
        let center = harness.screen(CGPoint(x: frame.midX, y: frame.midY))
        harness.view.mouseMoved(with: try event(.mouseMoved, at: center))
        for distance: CGFloat in [6, 18, 28] {
            harness.view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: edge.x + distance, y: edge.y)))
            #expect(harness.view.hoverNodeID == "solo-right", "grace band holds at +\(distance)")
            #expect(!harness.view.layerTree.addHandles.isEmpty)
        }

        // Past the band, with no node under the pointer, the plus goes.
        harness.view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: edge.x + 60, y: edge.y)))
        #expect(harness.view.hoverNodeID == nil)
        #expect(harness.view.layerTree.addHandles.isEmpty)
    }

    @Test func aBalancedRootHoversBothPlusesEvenWhenChildrenAllSitRight() throws {
        var model = sceneModel()
        for id in model.nodes["root"]?.children ?? [] {
            model.nodes[id]?.side = .right
        }
        let harness = DragHarness(model: model)
        let center = try harness.center(of: "root")
        harness.view.mouseMoved(with: try event(.mouseMoved, at: harness.screen(center)))
        #expect(
            Set(harness.view.layerTree.addHandles.map(\.side)) == [.left, .right],
            "a balanced root must offer the left plus even when every child sits right")

        // The left button is real: it hit-tests where it is drawn.
        let root = try #require(harness.scene.nodes["root"]?.frame)
        let leftPlus = harness.screen(CGPoint(x: root.minX, y: root.midY))
        let handle = try #require(
            harness.view.layerTree.addHandles.first { $0.side == .left })
        #expect(harness.view.addHandle(at: leftPlus)?.side == nil)
        #expect(
            harness.view.addHandle(at: handle.center(camera: harness.view.camera))?.side == .left)
    }

    @Test func thePlusHidesWhileEditingDraggingConnectingOrSpacePanning() throws {
        let harness = DragHarness(model: hoverModel())
        let center = try harness.center(of: "solo-right")
        harness.view.mouseMoved(with: try event(.mouseMoved, at: harness.screen(center)))
        #expect(!harness.view.layerTree.addHandles.isEmpty)

        // An open editing session (F-EDT-1): hidden.
        harness.view.beginEditing(nodeID: "solo-right")
        #expect(harness.view.layerTree.addHandles.isEmpty)
        harness.view.commitEditing()
        #expect(!harness.view.layerTree.addHandles.isEmpty, "committing brings the hover plus back")

        // ⌘L's next-click connection mode (F-REL-1): hidden.
        harness.view.pendingConnectionSource = "root"
        #expect(harness.view.layerTree.addHandles.isEmpty)
        harness.view.pendingConnectionSource = nil
        #expect(!harness.view.layerTree.addHandles.isEmpty)

        // A node drag (F-EDT-5): hidden while the state is live.
        try harness.grab("solo-right")
        #expect(harness.view.layerTree.addHandles.isEmpty)
        harness.view.drag = nil
        #expect(!harness.view.layerTree.addHandles.isEmpty)

        // Space-drag pan mode (ADR-0033): hidden while armed. (No
        // selection, so the Space tap's replace-edit can't fire and
        // re-hide the plus on keyUp.)
        harness.view.setSelection([])
        func spaceKey(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: " ",
                    charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        }
        harness.view.keyDown(with: try spaceKey(.keyDown))
        #expect(harness.view.layerTree.addHandles.isEmpty)
        harness.view.keyUp(with: try spaceKey(.keyUp))
        #expect(!harness.view.layerTree.addHandles.isEmpty, "disarming brings the hover plus back")
    }

    @Test func hoveringTheRootAndAChildShowsBothPlusesAtOnce() throws {
        let harness = DragHarness(model: hoverModel())
        let root = try harness.center(of: "root")
        let child = try harness.center(of: "solo-right")

        // The selected node keeps its plus while the pointer hovers
        // another node: two nodes, three buttons.
        harness.view.setSelection(["root"])
        harness.view.mouseMoved(with: try event(.mouseMoved, at: harness.screen(child)))
        #expect(harness.view.layerTree.addHandles.count == 3)
        #expect(
            Set(harness.view.layerTree.addHandles.map(\.nodeID)) == ["root", "solo-right"])
        #expect(
            Set(harness.view.layerTree.addHandles.map(\.side))
                == [.left, .right])

        // Pointer back on empty canvas: only the selection's plus.
        harness.view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 40, y: 40)))
        #expect(harness.view.layerTree.addHandles.count == 2)
        #expect(harness.view.layerTree.addHandles.allSatisfy { $0.nodeID == "root" })
    }
}
