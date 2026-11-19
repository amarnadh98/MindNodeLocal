import AppKit
import CoreGraphics
import MapCore
import MapRender

/// One VoiceOver row for a visible scene node (SPEC §11.6).
///
/// Role: `.row` (`AXRow`) — the role `NSOutlineView` rows report. macOS
/// has no distinct "outline row" role, so the closest fitting role is
/// the row and the *outline-ness* is carried by the disclosure
/// attributes this element also implements — `disclosedByRow`,
/// `disclosedRows`/children and `disclosed` — exactly how AppKit's own
/// outline conveys hierarchy (ADR-0007).
///
/// The label is the node's title (an empty node reads "Empty node"); the
/// value describes the subtree ("3 children, collapsed" / "1 child,
/// expanded" / "leaf", plus the task-progress hook text once tasks
/// exist). Selection, disclosure and custom actions are set at build
/// time and refreshed when the scene or selection changes; the frame is
/// computed live from the canvas's camera and window so it stays correct
/// through pan and zoom without any invalidation traffic.
///
/// Isolation: `NSAccessibilityElement` is a nonisolated base — its
/// methods satisfy the old protocol's nonisolated requirements — and
/// AppKit invokes all of them on the main thread. This class matches
/// that isolation (it is *not* `@MainActor`), touching `@MainActor`
/// state only inside `MainActor.assumeIsolated`, which is exact here
/// because AppKit never calls accessibility methods off the main
/// thread.
///
/// The element never mutates the model: custom actions forward the node
/// id to the host-set closures on `CanvasAccessibility` (SPEC §11.3 —
/// the host performs the `MapStore` command).
final class CanvasAccessibilityElement: NSAccessibilityElement {
    /// The scene node this row speaks for.
    let nodeID: String

    private weak var canvas: CanvasView?

    init(canvas: CanvasView, nodeID: String) {
        self.canvas = canvas
        self.nodeID = nodeID
        super.init()
        setAccessibilityRole(.row)
        setAccessibilityParent(canvas)
    }

    // MARK: static attributes (set at build time)

    /// Label, value, disclosure, selection and the custom actions for
    /// this row. `model` is the source model the scene was built from
    /// (nil falls back to scene-only knowledge: a node without children
    /// in the scene reads as a leaf).
    @MainActor
    func configure(
        node: SceneNode, model: MapModel?, hooks: CanvasAccessibility, isSelected: Bool
    ) {
        let text = node.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        setAccessibilityLabel(text.isEmpty ? "Empty node" : text)
        setAccessibilityValue(
            Self.valueText(
                nodeID: nodeID, model: model, taskText: hooks.taskProgressText?(nodeID),
                decorations: node.decorations))
        setAccessibilitySelected(isSelected)
        let folded = model?.nodes[nodeID]?.folded ?? false
        setAccessibilityDisclosed(!folded)
        setAccessibilityCustomActions(
            Self.actions(for: nodeID, model: model, canvas: canvas))
    }

    /// Wires the outline hierarchy: a row's disclosed rows are its
    /// visible children; `disclosedByRow` is the parent row (nil at the
    /// roots — the canvas group is their parent).
    func setHierarchy(children: [CanvasAccessibilityElement], parent: CanvasAccessibilityElement?) {
        setAccessibilityChildren(children)
        setAccessibilityDisclosedRows(children)
        setAccessibilityDisclosedByRow(parent)
    }

    /// The row's subtree description (SPEC §11.6: "3 children,
    /// collapsed" — with M3's decorations appended: task state and
    /// progress, the tag names, note/link presence; plus the
    /// task-progress hook for hosts that don't model decorations).
    static func valueText(
        nodeID: String, model: MapModel?, taskText: String?, decorations: NodeDecorations?
    ) -> String {
        let node = model?.nodes[nodeID]
        let base: String
        switch node?.children.count ?? 0 {
        case 0:
            base = "leaf"
        case 1:
            base = "1 child, \(node?.folded == true ? "collapsed" : "expanded")"
        case let count:
            base = "\(count) children, \(node?.folded == true ? "collapsed" : "expanded")"
        }
        var parts = [base]
        if let decorations {
            parts.append(contentsOf: Self.decorationText(decorations))
        } else if let taskText, !taskText.isEmpty {
            parts.append(taskText)
        }
        return parts.joined(separator: ", ")
    }

    /// The VoiceOver text of a node's decorations: "task, done" /
    /// "task, open" / "task 7 of 12 done", the tag names, "has note",
    /// "has link" (SPEC §11.6, minimally extending ADR-0007's row).
    static func decorationText(_ decorations: NodeDecorations) -> [String] {
        var parts: [String] = []
        switch decorations.task {
        case .checkbox(let done):
            parts.append(done ? "task, done" : "task, open")
        case .progress(let completed, let total):
            parts.append("task \(completed) of \(total) done")
        case nil:
            break
        }
        if !decorations.tags.isEmpty {
            parts.append("tags " + decorations.tags.map(\.name).joined(separator: " "))
        }
        if decorations.hasNote {
            parts.append("has note")
        }
        if decorations.linkURL != nil {
            parts.append("has link")
        }
        return parts
    }

    /// The custom actions this row offers (SPEC §11.6): Add Child, Add
    /// Sibling, Fold/Unfold (only nodes with children) and Edit, each
    /// forwarding the node id to the host's closure.
    private static func actions(
        for nodeID: String, model: MapModel?, canvas: CanvasView?
    ) -> [NSAccessibilityCustomAction] {
        var actions: [NSAccessibilityCustomAction] = []
        actions.append(
            NSAccessibilityCustomAction(name: "Add Child") { [weak canvas] in
                MainActor.assumeIsolated {
                    canvas?.accessibility.onAddChild?(nodeID)
                }
                return true
            })
        actions.append(
            NSAccessibilityCustomAction(name: "Add Sibling") { [weak canvas] in
                MainActor.assumeIsolated {
                    canvas?.accessibility.onAddSibling?(nodeID)
                }
                return true
            })
        if model?.nodes[nodeID]?.children.isEmpty == false {
            let foldName = model?.nodes[nodeID]?.folded == true ? "Unfold" : "Fold"
            actions.append(
                NSAccessibilityCustomAction(name: foldName) { [weak canvas] in
                    MainActor.assumeIsolated {
                        canvas?.accessibility.onToggleFold?(nodeID)
                    }
                    return true
                })
        }
        actions.append(
            NSAccessibilityCustomAction(name: "Edit") { [weak canvas] in
                MainActor.assumeIsolated {
                    canvas?.accessibility.onEdit?(nodeID)
                }
                return true
            })
        return actions
    }

    // MARK: live attributes

    /// The row's frame in the canvas's view space — the camera math
    /// alone, testable headlessly. `accessibilityFrame()` converts this
    /// to screen coordinates through the window.
    func frameInView() -> NSRect {
        guard let canvas else { return .zero }
        let nodeID = self.nodeID
        return MainActor.assumeIsolated { Self.viewFrame(of: nodeID, in: canvas) }
    }

    /// Screen-space frame, kept correct through camera pan/zoom and
    /// window moves because it is derived on every query.
    override func accessibilityFrame() -> NSRect {
        let canvas = self.canvas
        let nodeID = self.nodeID
        return MainActor.assumeIsolated {
            guard let canvas else { return .zero }
            let windowFrame = canvas.convert(Self.viewFrame(of: nodeID, in: canvas), to: nil)
            return canvas.window?.convertToScreen(windowFrame) ?? windowFrame
        }
    }

    /// The node's scaled frame in view space (`frameInView`'s math).
    @MainActor
    private static func viewFrame(of nodeID: String, in canvas: CanvasView) -> NSRect {
        guard let node = canvas.scene?.nodes[nodeID] else { return .zero }
        let camera = canvas.camera
        let origin = camera.screenPoint(for: node.frame.origin)
        return NSRect(
            origin: origin,
            size: CGSize(
                width: node.frame.width * camera.scale,
                height: node.frame.height * camera.scale))
    }
}
