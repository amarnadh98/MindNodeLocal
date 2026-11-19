import MapCore

/// Pure fold-command builders for the Fold menu (F-LAY-14, SPEC §6.1):
/// each call returns ONE command — a bare `setFolded`, or a `.group` of
/// them — so the store registers exactly one undo step, or nil when the
/// map is already in the requested state (a no-op must not register an
/// undo step). Structure is read from the model only; the scene needs
/// no part in the decision.
public enum Folding {
    /// ⌃1–⌃5 / ⌃0 ("Show Levels", §6.1 Fold): show levels `1...levels`
    /// by folding every inner node at depth ≥ `levels` (depth 1 = roots)
    /// and unfolding everything shallower. `levels <= 0` unfolds all.
    public static func showLevelsCommand(levels: Int, in model: MapModel) -> MapCommand? {
        var commands: [MapCommand] = []
        for id in model.nodes.keys.sorted() {
            guard let node = model.nodes[id], !node.children.isEmpty else { continue }
            let shouldFold = levels >= 1 && depth(of: id, in: model) >= levels
            if shouldFold != node.folded {
                commands.append(.setFolded(id: id, folded: shouldFold))
            }
        }
        return grouped(commands)
    }

    /// ⌥⌘.: every sibling group touched by the selection flips together —
    /// any unfolded foldable sibling folds the whole group; a fully folded
    /// group unfolds. Leaves are never folded (nothing to hide).
    public static func toggleWithSiblingsCommand(
        selection: [String], in model: MapModel
    ) -> MapCommand? {
        guard !selection.isEmpty else { return nil }
        var visited: Set<String> = []
        var commands: [MapCommand] = []
        for id in selection.sorted() {
            guard model.nodes[id] != nil else { continue }
            // Siblings of a root are the roots; group key = parent id
            // ("" for roots), so a multi-selection inside one group only
            // visits it once.
            let groupKey = model.nodes[id]?.parent ?? ""
            guard visited.insert(groupKey).inserted else { continue }
            let siblings = siblingGroup(of: id, in: model)
            let foldable = siblings.filter { !(model.nodes[$0]?.children.isEmpty ?? true) }
            let shouldFold = foldable.contains { model.nodes[$0]?.folded != true }
            for sibling in siblings {
                guard let node = model.nodes[sibling] else { continue }
                if shouldFold {
                    guard !node.children.isEmpty, !node.folded else { continue }
                    commands.append(.setFolded(id: sibling, folded: true))
                } else {
                    guard node.folded else { continue }
                    commands.append(.setFolded(id: sibling, folded: false))
                }
            }
        }
        return grouped(commands)
    }

    /// ⌃⌥.: unfold each selected node that is currently folded — one
    /// level of the hidden subtree reappears per press; it never folds.
    public static func unfoldOneLevelCommand(
        selection: [String], in model: MapModel
    ) -> MapCommand? {
        let commands =
            selection
            .sorted()
            .filter { model.nodes[$0]?.folded == true }
            .map { MapCommand.setFolded(id: $0, folded: false) }
        return grouped(commands)
    }

    // MARK: helpers

    /// One grouped command from `commands`, or nil when empty — a single
    /// command stays bare so the undo name reads "Fold Node" either way.
    private static func grouped(_ commands: [MapCommand]) -> MapCommand? {
        switch commands.count {
        case 0:
            nil
        case 1:
            commands[0]
        default:
            .group(name: "Fold Node", commands: commands)
        }
    }

    /// The children of the node's parent, or the root list for a root.
    private static func siblingGroup(of id: String, in model: MapModel) -> [String] {
        guard let parent = model.nodes[id]?.parent else { return model.roots }
        return model.nodes[parent]?.children ?? [id]
    }

    /// 1 for roots, one more per parent step. The cycle guard is only
    /// defensive (the validator rejects cycles).
    private static func depth(of id: String, in model: MapModel) -> Int {
        var depth = 1
        var current = id
        var seen: Set<String> = [id]
        while let parent = model.nodes[current]?.parent, parent != current,
            seen.insert(parent).inserted
        {
            depth += 1
            current = parent
        }
        return depth
    }
}
