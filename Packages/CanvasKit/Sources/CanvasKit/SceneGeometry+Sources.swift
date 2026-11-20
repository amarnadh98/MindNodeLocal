import CoreGraphics
import MapCore
import MapLayout
import MapRender

/// The scene build's *inputs* half (SPEC §11.3), split out of
/// `SceneGeometry` to keep the enum body under the lint budgets (the
/// per-node measurement source lives in `SceneGeometry+Media`): the
/// fold-count helpers, the depth/level-1 ancestry walk and the
/// manual-offset accumulation.
extension SceneGeometry {
    /// Same count from just the folded node's child list — the assembly
    /// loop's form: only folded nodes (rare) pay the walk, and the
    /// §11.8 fast path never copies the big `Node` value to ask "is this
    /// node folded?".
    static func foldedDescendantCount(ofChildren children: [String], in model: MapModel) -> Int {
        var count = 0
        var stack = children
        while let current = stack.popLast() {
            guard let child = model.nodes[current] else { continue }
            count += 1
            stack.append(contentsOf: child.children)
        }
        return count
    }

    /// The structure of a root's tree: the root's own override, else the
    /// document default (SPEC §5.3: structure is inherited until
    /// overridden; the canvas default is the balanced mind map).
    static func rootStructure(_ model: MapModel, rootID: String) -> LayoutStructure {
        guard let raw = model.nodes[rootID]?.structure,
            let structure = LayoutStructure(rawValue: raw)
        else {
            return .mindmapBalanced
        }
        return structure
    }

    /// Depth from the root and the level-1 ancestor that colors this
    /// node's branch, for every node the scene can show (folded subtrees
    /// pruned) — one walk, no ancestor chains per node.
    static func ancestryMap(model: MapModel, rootID: String) -> [String: AncestryInfo] {
        var result: [String: AncestryInfo] = [:]
        func walk(_ id: String, depth: Int, level1: String) {
            guard let node = model.nodes[id] else { return }
            result[id] = AncestryInfo(
                depth: depth,
                // The level-1 ancestor of a root (depth 0) and of a
                // first-level node is the node itself.
                level1AncestorID: depth <= 1 ? id : level1)
            guard !node.folded else { return }
            let childLevel1 = depth == 0 ? id : (depth == 1 ? id : level1)
            for childID in node.children {
                walk(childID, depth: depth + 1, level1: childLevel1)
            }
        }
        walk(rootID, depth: 0, level1: rootID)
        return result
    }

    /// A node's manual offset, plus the accumulated offsets of its
    /// ancestors — the translation applied after auto layout (SPEC §9:
    /// "offset is added after auto layout; descendants move with it").
    static func accumulatedOffsets(model: MapModel, rootID: String) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]

        func walk(_ id: String, inherited: CGPoint) {
            var own = inherited
            if let offset = model.nodes[id]?.offset {
                own = CGPoint(x: own.x + offset.x, y: own.y + offset.y)
            }
            result[id] = own
            for childID in model.nodes[id]?.children ?? [] {
                walk(childID, inherited: own)
            }
        }
        walk(rootID, inherited: .zero)
        return result
    }

    static func side(of node: Node) -> LayoutSide? {
        guard let sidePin = node.side else { return nil }
        return sidePin == .left ? .left : .right
    }
}
