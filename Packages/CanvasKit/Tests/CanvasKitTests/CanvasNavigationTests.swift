import AppKit
import CoreGraphics
import Foundation
import MapCore
import MapRender
import Testing

@testable import CanvasKit

private let navDate = Date(timeIntervalSince1970: 1_800_000_000)

/// A root with three branches ("b0"…"b2") on the right, each with one
/// leaf ("l0"…"l2").
private func navigationModel() -> MapModel {
    var model = MapModel.emptyDocument(docID: "navglue")
    let root = "root"
    model.nodes[root] = Node(
        id: root, title: NodeTitle(text: "Central Idea"), structure: "mindmap.right",
        created: navDate, modified: navDate)
    model.roots = [root]
    for index in 0..<3 {
        let branch = "b\(index)"
        model.nodes[branch] = Node(
            id: branch, parent: root, title: NodeTitle(text: "branch \(index)"),
            created: navDate, modified: navDate)
        model.nodes[root]?.children.append(branch)
        let leaf = "l\(index)"
        model.nodes[leaf] = Node(
            id: leaf, parent: branch, title: NodeTitle(text: "leaf \(index)"),
            created: navDate, modified: navDate)
        model.nodes[branch]?.children.append(leaf)
    }
    return model
}

/// A canvas wired like the host wires it: scene + source model.
@MainActor
private func navigationCanvas(model: MapModel) -> CanvasView {
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    canvas.scene = SceneGeometry.build(
        model: model, variant: .light, measurer: SceneRenderer.sharedMeasurer)
    canvas.dragModel = model
    return canvas
}

@MainActor
private func keyDownEvent(_ key: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: key,
        charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
}

/// The view-side navigation glue (F-CAN-4/F-CAN-7): arrow keyDown moves
/// the selection, ⇧-arrows extend it, multi-selections depart from the
/// member furthest along the pressed axis, and the camera follows with
/// the 40 pt scroll-into-view margin. ⌘J centers even when visible.
@MainActor
struct CanvasNavigationTests {
    @Test func arrowKeyDownMovesTheSelectionAndFollowsTheCamera() throws {
        let model = navigationModel()
        let canvas = navigationCanvas(model: model)
        canvas.setSelection(["b0"])
        // Park the camera far from b1 so the follow is observable.
        canvas.camera = Camera(origin: CGPoint(x: 20_000, y: 20_000), scale: 1)

        canvas.keyDown(with: keyDownEvent("\u{f701}"))

        #expect(canvas.selection == ["b1"])
        let frame = try #require(canvas.scene?.nodes["b1"]?.frame)
        let visible = canvas.camera.visibleRect(viewportSize: canvas.bounds.size)
        #expect(visible.contains(frame), "camera must follow the new selection")
    }

    @Test func shiftArrowsExtendTheSelection() throws {
        let model = navigationModel()
        let canvas = navigationCanvas(model: model)
        canvas.setSelection(["b0"])

        canvas.keyDown(with: keyDownEvent("\u{f701}", modifiers: [.shift]))
        #expect(canvas.selection == ["b0", "b1"])
        // A second extend departs from the member furthest down (b1).
        canvas.keyDown(with: keyDownEvent("\u{f701}", modifiers: [.shift]))
        #expect(canvas.selection == ["b0", "b1", "b2"])
    }

    @Test func plainArrowsCollapseAMultiSelection() throws {
        let model = navigationModel()
        let canvas = navigationCanvas(model: model)
        canvas.setSelection(["b0", "b1"])

        canvas.keyDown(with: keyDownEvent("\u{f701}"))
        // ↓ continues past the bottom-most selected node.
        #expect(canvas.selection == ["b2"])
    }

    @Test func alreadyVisibleSelectionLeavesTheCameraUntouched() throws {
        let model = navigationModel()
        let canvas = navigationCanvas(model: model)
        canvas.setSelection(["b0"])
        let before = canvas.camera

        canvas.navigate(.down, extending: false)
        #expect(canvas.selection == ["b1"])
        #expect(canvas.camera == before)
    }

    @Test func menuActionsMatchTheKeys() throws {
        let model = navigationModel()
        let canvas = navigationCanvas(model: model)
        canvas.setSelection(["b0"])

        canvas.navigateDownAction(nil)
        #expect(canvas.selection == ["b1"])
        canvas.extendUpAction(nil)
        #expect(canvas.selection == ["b1", "b0"])
        canvas.navigateLeftAction(nil)
        #expect(canvas.selection == ["root"])
    }

    @Test func nextAndPreviousRootActionsStepTheRootList() throws {
        var model = navigationModel()
        model.roots.append("root-2")
        model.nodes["root-2"] = Node(
            id: "root-2", title: NodeTitle(text: "Second"), created: navDate, modified: navDate)
        let canvas = navigationCanvas(model: model)

        // With nothing selected the step starts at the first root.
        canvas.nextRootAction(nil)
        #expect(canvas.selection == ["root-2"])
        canvas.previousRootAction(nil)
        #expect(canvas.selection == ["root"])
        // From inside a tree it still steps by tree.
        canvas.setSelection(["l0"])
        canvas.nextRootAction(nil)
        #expect(canvas.selection == ["root-2"])
    }

    @Test func jumpToSelectionCentersEvenWhenAlreadyVisible() throws {
        let model = navigationModel()
        let canvas = navigationCanvas(model: model)
        canvas.setSelection(["b1"])

        canvas.jumpToSelectionAction(nil)

        let frame = try #require(canvas.scene?.nodes["b1"]?.frame)
        let center = canvas.camera.screenPoint(for: CGPoint(x: frame.midX, y: frame.midY))
        #expect(abs(center.x - canvas.bounds.midX) < 0.5)
        #expect(abs(center.y - canvas.bounds.midY) < 0.5)
    }

    @Test func clipboardActionsForwardUpTheResponderChain() throws {
        // NSResponder's own copy:/cut:/paste: are no-ops that would
        // swallow the message; the canvas must forward them so the
        // map-level clipboard (F-EDT-9) lives up the chain.
        let model = navigationModel()
        let canvas = navigationCanvas(model: model)
        let stub = ResponderStub()
        canvas.nextResponder = stub

        canvas.copy(nil)
        canvas.cut(nil)
        canvas.paste(nil)

        #expect(stub.copyCount == 1)
        #expect(stub.cutCount == 1)
        #expect(stub.pasteCount == 1)
    }
}

/// Counts the standard clipboard selectors it receives.
private final class ResponderStub: NSResponder {
    var copyCount = 0
    var cutCount = 0
    var pasteCount = 0

    @objc func copy(_ sender: Any?) {
        copyCount += 1
    }

    @objc func cut(_ sender: Any?) {
        cutCount += 1
    }

    @objc func paste(_ sender: Any?) {
        pasteCount += 1
    }
}
