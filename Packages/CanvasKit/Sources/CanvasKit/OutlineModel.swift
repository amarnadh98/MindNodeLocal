import Foundation
import MapCore

/// One displayed outline row: the node id plus its nesting level
/// (0 = root section header). Pure data — the outline view, the tests
/// and any future projection all agree on this value.
public struct OutlineRow: Equatable, Sendable {
    public let id: String
    public let depth: Int

    public init(id: String, depth: Int) {
        self.id = id
        self.depth = depth
    }
}

/// Pure, headless model → outline projection (F-OUT, SPEC §5.9): the
/// row order, the displayed children of every item, and the row list a
/// fresh rebuild must produce. The `NSOutlineView` datasource calls
/// these; the randomized consistency test re-derives them through an
/// independent walk and demands agreement after every store change.
///
/// No AppKit, no state: everything is a function of the model (plus a
/// side resolver the host supplies from the live scene, see
/// `displayedChildren`). Folding is NOT separate state — disclosure
/// mirrors `node.folded` (one source of truth, F-LAY-14): a folded
/// node's children simply never enter the projection.
public enum OutlineModel {
    /// The rows a fresh outline displays for `model`: roots in creation
    /// order, then a depth-first walk where a node's children appear
    /// iff it is not folded.
    public static func rows(in model: MapModel, sideOf: (String) -> SidePin?) -> [OutlineRow] {
        var result: [OutlineRow] = []

        func walk(_ id: String, depth: Int) {
            result.append(OutlineRow(id: id, depth: depth))
            guard let node = model.nodes[id], !node.folded else { return }
            for child in displayedChildren(of: id, in: model, sideOf: sideOf) {
                walk(child, depth: depth + 1)
            }
        }

        for root in model.roots {
            walk(root, depth: 0)
        }
        return result
    }

    /// The children of `parent` (nil = the root list) as the outline
    /// displays them.
    ///
    /// **Clockwise rule (first level only).** On a balanced mind map
    /// the root's children fan out on both sides. Reading them
    /// "clockwise" — the eye's path around the root, starting at
    /// 12 o'clock — means: the **right side top→bottom** (1 → 3 → 5
    /// o'clock), then the **left side bottom→top** (7 → 9 → 11
    /// o'clock). That reading order keeps the outline contiguous with
    /// the map: the last right-side child is followed by the left-side
    /// child that visually sits right under it, and the walk ends at
    /// the left side's topmost child, next to the first right one.
    ///
    /// When all children sit on one side (a one-sided map, an org
    /// chart, or a balanced map that partitioned every child onto one
    /// side) there is nothing to reorder: the visual order IS the model
    /// order, top→bottom, on either side. Deeper levels are never
    /// permuted — a subtree renders its children in model order.
    public static func displayedChildren(
        of parent: String?, in model: MapModel, sideOf: (String) -> SidePin?
    ) -> [String] {
        guard let parent else { return model.roots }
        let children = model.nodes[parent]?.children ?? []
        // Only a root's children (first level) can straddle both sides.
        guard model.nodes[parent]?.parent == nil else { return children }
        let right = children.filter { sideOf($0) != .left }
        guard !right.isEmpty, right.count != children.count else { return children }
        let left = children.filter { sideOf($0) == .left }
        return right + left.reversed()
    }

    /// The row displayed directly above `id` (nil when `id` is the very
    /// first row). Pure walk of `rows(in:)`.
    public static func previousRow(
        before id: String, in model: MapModel, sideOf: (String) -> SidePin?
    ) -> OutlineRow? {
        let all = rows(in: model, sideOf: sideOf)
        guard let index = all.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return all[index - 1]
    }

    /// The previous sibling of `id` **in displayed order** (nil when the
    /// row is the first of its group). On the left side of a balanced
    /// root this differs from the model's previous child — the outline
    /// user's "up" is the displayed one.
    public static func previousDisplayedSibling(
        of id: String, in model: MapModel, sideOf: (String) -> SidePin?
    ) -> String? {
        let parent = model.nodes[id]?.parent
        let siblings = displayedChildren(of: parent, in: model, sideOf: sideOf)
        guard let slot = siblings.firstIndex(of: id), slot > 0 else { return nil }
        return siblings[slot - 1]
    }

    /// The next/previous displayed row (F-OUT-3 arrow navigation),
    /// bounded by the row list.
    public static func adjacentRow(
        to id: String, downward: Bool, in model: MapModel, sideOf: (String) -> SidePin?
    ) -> String? {
        let all = rows(in: model, sideOf: sideOf)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        let target = downward ? index + 1 : index - 1
        guard all.indices.contains(target) else { return nil }
        return all[target].id
    }

    /// The model-side resolver when no scene exists: a pinned
    /// `node.side` wins, free children default to the right side. The
    /// host replaces this with scene-derived sides (`CanvasScene`
    /// branches) so the outline follows what the map actually shows.
    public static func modelSides(in model: MapModel) -> (String) -> SidePin? {
        { id in model.nodes[id]?.side ?? SidePin.right }
    }

    /// Every strict descendant of `ids`, breadth-safe. Cycle-guarded
    /// (the validator rejects cycles; this is defensive only).
    public static func descendantIDs(of ids: [String], in model: MapModel) -> Set<String> {
        var result: Set<String> = []
        var stack = ids
        var visited: Set<String> = []
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            for child in model.nodes[current]?.children ?? [] {
                result.insert(child)
                stack.append(child)
            }
        }
        return result
    }
}
