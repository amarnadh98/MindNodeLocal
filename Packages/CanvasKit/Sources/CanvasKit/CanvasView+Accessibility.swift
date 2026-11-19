import AppKit
import CoreGraphics
import MapCore

/// Host-facing accessibility configuration (SPEC §11.6), owned by
/// `CanvasView.accessibility`. The host sets the closures — it owns the
/// model, so it performs the `MapStore` commands; the view only
/// forwards node ids and never mutates the model (SPEC §11.3).
@MainActor
public final class CanvasAccessibility {
    /// The canvas group's label (the document/map name), queried lazily
    /// so it always reflects the current display name.
    public var containerLabel: (() -> String?)?

    /// Custom actions exposed per node row (SPEC §11.6), performed on
    /// the given node id.
    public var onAddChild: ((String) -> Void)?
    public var onAddSibling: ((String) -> Void)?
    public var onToggleFold: ((String) -> Void)?
    public var onEdit: ((String) -> Void)?

    /// Extra value text such as "task 2 of 5 done" (SPEC §11.6). Tasks
    /// land in M3, so this hook stays unset until then.
    public var taskProgressText: ((String) -> String?)?

    /// The per-node row elements, rebuilt lazily after scene or source
    /// model changes; frames stay live through the camera, so no
    /// rebuild is needed for pan or zoom.
    var elements: [String: CanvasAccessibilityElement] = [:]
    /// The elements in outline (creation) order — VoiceOver's linear
    /// navigation order.
    var order: [CanvasAccessibilityElement] = []
    var needsRebuild = true
}

/// The canvas as an accessibility container (SPEC §11.6): the view
/// itself is a group labelled with the document name; its children are
/// one `CanvasAccessibilityElement` (outline row) per *visible* scene
/// node — folded subtrees are absent from the scene, so they are never
/// exposed (F-LAY-14). When the selection changes, VoiceOver follows
/// via selected-rows-changed / focused-changed notifications; while a
/// node is being edited, the overlay's text view is the focused
/// element (announced from `NodeTextEditor`).
extension CanvasView {
    /// The canvas is a container, not an element itself.
    public override func isAccessibilityElement() -> Bool { false }

    public override func accessibilityRole() -> NSAccessibility.Role? { .group }

    public override func accessibilityLabel() -> String? {
        accessibility.containerLabel?() ?? "Mind Map"
    }

    /// One row per visible scene node, in outline order.
    public override func accessibilityChildren() -> [Any]? {
        ensureAccessibilityElements()
        return accessibility.order
    }

    public override func accessibilitySelectedChildren() -> [Any]? {
        ensureAccessibilityElements()
        return selection.compactMap { accessibility.elements[$0] }
    }

    // MARK: element cache

    /// (Re)builds the row elements when the scene or the source model
    /// changed (`needsRebuild` is set by their `didSet`s). Hierarchy
    /// wiring prefers the source model — the scene's branch edges only
    /// cover *visible* children, and a folded node needs its real
    /// children count and folded flag for its value and Fold action.
    func ensureAccessibilityElements() {
        guard accessibility.needsRebuild else { return }
        accessibility.needsRebuild = false
        guard let scene else {
            accessibility.elements = [:]
            accessibility.order = []
            return
        }
        let model = dragModel

        var elements: [String: CanvasAccessibilityElement] = [:]
        for node in scene.nodes.values {
            elements[node.id] = CanvasAccessibilityElement(canvas: self, nodeID: node.id)
        }
        for node in scene.nodes.values {
            elements[node.id]?.configure(
                node: node, model: model, hooks: accessibility,
                isSelected: selection.contains(node.id))
        }
        for (id, element) in elements {
            let children: [CanvasAccessibilityElement]
            if let model {
                children = (model.nodes[id]?.children ?? []).compactMap { elements[$0] }
            } else {
                children = scene.branches
                    .filter { $0.parentID == id }
                    .compactMap { branch in elements[branch.childID] }
            }
            let parent = model?.nodes[id]?.parent.flatMap { elements[$0] }
            element.setHierarchy(children: children, parent: parent)
        }

        accessibility.elements = elements
        accessibility.order = navigationOrder(scene: scene, model: model)
            .compactMap { elements[$0] }
    }

    /// Outline order (roots in creation order, depth-first within a
    /// tree, folded subtrees skipped); scene-geometry order as the
    /// fallback when the source model is unavailable.
    private func navigationOrder(scene: CanvasScene, model: MapModel?) -> [String] {
        guard let model else {
            return scene.nodes.values
                .sorted {
                    ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
                }
                .map(\.id)
        }
        var order: [String] = []
        func visit(_ id: String) {
            guard scene.nodes[id] != nil else { return }
            order.append(id)
            for child in model.nodes[id]?.children ?? [] {
                visit(child)
            }
        }
        for root in model.roots {
            visit(root)
        }
        return order
    }

    // MARK: VoiceOver notifications

    /// Called from `selection.didSet`: refreshes the rows' selected
    /// flags and makes VoiceOver follow (SPEC §11.6) — the container
    /// posts selected-rows-changed, and a single newly selected row
    /// also becomes the focused element so the cursor tracks arrow-key
    /// navigation.
    func accessibilitySelectionDidChange(from oldSelection: Set<String>) {
        guard selection != oldSelection else { return }
        ensureAccessibilityElements()
        for id in oldSelection {
            accessibility.elements[id]?.setAccessibilitySelected(false)
        }
        for id in selection {
            accessibility.elements[id]?.setAccessibilitySelected(true)
        }
        NSAccessibility.post(element: self, notification: .selectedRowsChanged)
        if selection.count == 1, let id = selection.first, let element = accessibility.elements[id] {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    /// Announces the inline editing overlay as the focused element, so
    /// VoiceOver reads the node's text field while its title is being
    /// edited (called by `NodeTextEditor` once the text view is first
    /// responder).
    func announceEditingFocus(to view: NSView) {
        NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
    }
}
