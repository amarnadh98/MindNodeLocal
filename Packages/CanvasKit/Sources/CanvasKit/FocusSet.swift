import Foundation
import MapCore

/// Pure focus-set computation for Focus and Zen modes (F-FOC-1/2): the
/// set of node ids that stay fully opaque while everything else dims
/// to 15% — the anchor's whole subtree plus its ancestor path to the
/// root (so the branch stays readable in context). Read from the
/// model; the view intersects it with whatever the scene actually
/// shows (folded-away ids simply have no layer to undim).
public enum FocusSet {
    /// The anchor's subtree plus every ancestor up to (and including)
    /// its root.
    public static func ids(around anchorID: String, in model: MapModel) -> Set<String> {
        guard model.nodes[anchorID] != nil else { return [] }
        var result = subtree(of: anchorID, in: model)
        for ancestor in ancestorPath(of: anchorID, in: model) {
            result.insert(ancestor)
        }
        return result
    }

    /// The anchor and all its descendants.
    public static func subtree(of anchorID: String, in model: MapModel) -> Set<String> {
        guard model.nodes[anchorID] != nil else { return [] }
        var result: Set<String> = [anchorID]
        var stack = model.nodes[anchorID]?.children ?? []
        while let id = stack.popLast() {
            guard model.nodes[id] != nil, result.insert(id).inserted else { continue }
            stack.append(contentsOf: model.nodes[id]?.children ?? [])
        }
        return result
    }

    /// The ancestor path, root first; the anchor itself is not
    /// included. Cycle-guarded (the validator rejects cycles; the
    /// guard is defensive).
    public static func ancestorPath(of anchorID: String, in model: MapModel) -> [String] {
        var path: [String] = []
        var seen = Set([anchorID])
        var current = model.nodes[anchorID]?.parent
        while let ancestorID = current, seen.insert(ancestorID).inserted {
            path.append(ancestorID)
            current = model.nodes[ancestorID]?.parent
        }
        return path.reversed()
    }
}
