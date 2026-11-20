import CanvasKit
import MapCore
import MapRender

/// The Box|Line control's host side (ADR-0034): the one selection
/// action the contextual bar and the inspector both funnel through,
/// and the creation-default hooks every create path consults (F-EDT-1/
/// F-EDT-3) — pure rules in `NodeCreationShape` (MapCore), model
/// lookups here.
@MainActor
extension DocumentWindowController {
    // MARK: the selection action

    /// The Box|Line segmented control's action: ONE `setStyle` command
    /// over the whole selection (F-EDT-12, one undo step). Box stores a
    /// background shape — the theme's own box look resolves around it
    /// (F-STY-3); Line stores `.underline` — text on a line in the
    /// branch color. The class-flip look lives in the theme resolver
    /// (`Theme.shapeDonor`, ADR-0034), never in a stored hex, so it
    /// respects light/dark and survives theme changes.
    func setNodeShapeClass(box: Bool) {
        performStyleCommandOnSelection {
            .setStyle(ids: $0, patch: NodeStylePatch(shape: box ? .roundedRect : .underline))
        }
    }

    // MARK: the control's state

    /// The Box|Line state of one node: its stored shape override's
    /// class, else the theme's level shape. `nil` for an unknown id.
    /// The contextual bar and the inspector read the same rule, so
    /// they can never disagree.
    func nodeIsBox(_ id: String) -> Bool? {
        guard let store, let node = store.model.nodes[id] else { return nil }
        let theme = ThemeCatalog.shared.theme(for: store.model)
        let shape =
            node.style?.shape
            ?? theme.scheme(for: currentVariant()).levels.style(forLevel: level(of: id)).shape
        return shape.drawsBackground
    }

    /// The whole selection's Box|Line state: `nil` when the selection
    /// is mixed or empty (the control shows no lit segment).
    func selectionShapeClass() -> Bool? {
        var classes: Set<Bool> = []
        for id in canvas.selection {
            guard let isBox = nodeIsBox(id) else { return nil }
            classes.insert(isBox)
        }
        return classes.count == 1 ? classes.first : nil
    }

    // MARK: creation defaults (ADR-0034)

    /// The shape a new sibling beside `anchor` stores: the anchor's
    /// own shape when it has an explicit override, else nothing (the
    /// theme's level style decides).
    func siblingCreationShape(anchor: String) -> NodeShape? {
        guard let store else { return nil }
        return NodeCreationShape.sibling(anchorStyle: store.model.nodes[anchor]?.style)
    }

    /// The shape a new child of `parent` stores: the last sibling with
    /// an explicit shape, else nothing (the theme's level style
    /// decides) — so lines stay lines and boxes stay boxes.
    func childCreationShape(parent: String) -> NodeShape? {
        guard let store, let node = store.model.nodes[parent] else { return nil }
        let siblings = node.children.map { store.model.nodes[$0]?.style }
        return NodeCreationShape.child(existingSiblings: siblings)
    }

    /// The level (depth) of `id` in its root tree — the theme's level
    /// style lookup for `nodeIsBox`.
    private func level(of id: String) -> Int {
        guard let store else { return 0 }
        var level = 0
        var cursor = store.model.nodes[id]?.parent
        while let parent = cursor {
            level += 1
            cursor = store.model.nodes[parent]?.parent
        }
        return level
    }
}
