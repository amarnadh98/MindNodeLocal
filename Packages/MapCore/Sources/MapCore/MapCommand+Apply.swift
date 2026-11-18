import Foundation

// Command dispatchers are wide switches by design; the helpers they call stay small.

extension MapCommand {
    // Command dispatchers are wide switches by design; the helpers they call stay small.
    // swiftlint:disable cyclomatic_complexity function_body_length

    /// Applies this command. All-or-nothing: a thrown failure leaves the
    /// model exactly as it was, and on success the structural invariants
    /// (parent/child agreement, no dangling references) hold.
    public func apply(to model: inout MapModel) throws {
        switch self {
        case .addChild(let parentID, let index, let node):
            guard model.nodes[parentID] != nil else {
                throw ArborError.commandFailure("missing parent \(parentID)")
            }
            guard model.nodes[node.id] == nil else {
                throw ArborError.commandFailure("duplicate id \(node.id)")
            }
            var inserted = node
            inserted.parent = parentID
            inserted.children = []
            model.nodes[node.id] = inserted
            let insertion = Self.clampIndex(index, parent: parentID, model: model)
            model.nodes[parentID]?.children.insert(node.id, at: insertion)

        case .addSibling(let anchorID, let before, let node):
            guard let anchor = model.nodes[anchorID] else {
                throw ArborError.commandFailure("missing anchor \(anchorID)")
            }
            guard model.nodes[node.id] == nil else {
                throw ArborError.commandFailure("duplicate id \(node.id)")
            }
            var inserted = node
            inserted.parent = anchor.parent
            inserted.children = []
            model.nodes[node.id] = inserted
            if let parentID = anchor.parent {
                let slot = slotOf(id: anchorID, parent: parentID, model: model)
                model.nodes[parentID]?.children.insert(node.id, at: before ? slot : slot + 1)
            } else {
                let rootIndex = model.roots.firstIndex(of: anchorID) ?? model.roots.count
                model.roots.insert(node.id, at: before ? rootIndex : rootIndex + 1)
            }

        case .insertParent(let anchorID, let node):
            guard let anchor = model.nodes[anchorID] else {
                throw ArborError.commandFailure("missing anchor \(anchorID)")
            }
            guard model.nodes[node.id] == nil else {
                throw ArborError.commandFailure("duplicate id \(node.id)")
            }
            var inserted = node
            inserted.parent = anchor.parent
            inserted.children = [anchorID]
            model.nodes[node.id] = inserted
            if let parentID = anchor.parent {
                let slot = slotOf(id: anchorID, parent: parentID, model: model)
                model.nodes[parentID]?.children[slot] = node.id
            } else if let rootIndex = model.roots.firstIndex(of: anchorID) {
                model.roots[rootIndex] = node.id
            }
            model.nodes[anchorID]?.parent = node.id
            purgeStaleSummaries(in: &model)

        case .addRoot(let index, let node):
            guard model.nodes[node.id] == nil else {
                throw ArborError.commandFailure("duplicate id \(node.id)")
            }
            var inserted = node
            inserted.parent = nil
            inserted.children = []
            inserted.side = nil
            model.nodes[node.id] = inserted
            let insertion = Self.clampIndex(index, parent: nil, model: model)
            model.roots.insert(node.id, at: insertion)

        case .deleteSubtrees(let ids):
            var removed = Set(ids)
            removed.formUnion(Set(descendants(of: ids, in: model)))
            for id in ids {
                guard let node = model.nodes[id] else { continue }
                if let parentID = node.parent {
                    model.nodes[parentID]?.children.removeAll { $0 == id }
                } else if let rootIndex = model.roots.firstIndex(of: id) {
                    model.roots.remove(at: rootIndex)
                }
            }
            for id in descendants(of: ids, in: model) {
                model.nodes[id] = nil
            }
            for id in ids {
                model.nodes[id] = nil
            }
            purgeSecondaryReferences(to: removed, in: &model)

        case .deleteNodePromotingChildren(let id):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            var removed = Set([id])
            removed.formUnion(Set(descendants(of: node.children, in: model)))
            let slot = slotOf(id: id, parent: node.parent, model: model)
            for childID in node.children {
                model.nodes[childID]?.parent = node.parent
            }
            if let parentID = node.parent {
                model.nodes[parentID]?.children.replaceSubrange(slot...slot, with: node.children)
            } else if let rootIndex = model.roots.firstIndex(of: id) {
                model.roots.replaceSubrange(rootIndex...rootIndex, with: node.children)
            }
            model.nodes[id] = nil
            purgeSecondaryReferences(to: removed, in: &model)

        case .editText(let id, let title):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            model.nodes[id]?.title = title

        case .moveNode(let id, let parentID, let index):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            guard parentID != id else {
                throw ArborError.commandFailure("cannot move a node into itself")
            }
            if let parentID, descendants(of: [id], in: model).contains(parentID) {
                throw ArborError.commandFailure("cannot move a node into its own subtree")
            }
            if let parentID, model.nodes[parentID] == nil {
                throw ArborError.commandFailure("missing parent \(parentID)")
            }
            if let oldParent = node.parent {
                model.nodes[oldParent]?.children.removeAll { $0 == id }
            } else if let rootIndex = model.roots.firstIndex(of: id) {
                model.roots.remove(at: rootIndex)
            }
            model.nodes[id]?.parent = parentID
            if let parentID {
                let insertion = Self.clampIndex(index, parent: parentID, model: model)
                model.nodes[parentID]?.children.insert(id, at: insertion)
            } else {
                let insertion = Self.clampIndex(index, parent: nil, model: model)
                model.roots.insert(id, at: insertion)
            }
            purgeStaleSummaries(in: &model)

        case .reorderSibling(let id, let delta):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            let current = slotOf(id: id, parent: node.parent, model: model)
            let count = siblingCount(parent: node.parent, model: model)
            let target = Self.clamp(current + delta, count: count)
            if target == current { return }
            if let parentID = node.parent {
                model.nodes[parentID]?.children.remove(at: current)
                model.nodes[parentID]?.children.insert(id, at: target)
            } else {
                model.roots.remove(at: current)
                model.roots.insert(id, at: target)
            }

        case .promote(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("cannot promote a root")
            }
            let slot = slotOf(id: id, parent: parentID, model: model)
            guard let grandParentID = model.nodes[parentID]?.parent else {
                model.nodes[parentID]?.children.remove(at: slot)
                model.nodes[id]?.parent = nil
                let rootSlot = model.roots.firstIndex(of: parentID) ?? model.roots.count
                model.roots.insert(id, at: rootSlot + 1)
                purgeStaleSummaries(in: &model)
                return
            }
            let parentSlot = slotOf(id: parentID, parent: grandParentID, model: model)
            model.nodes[parentID]?.children.remove(at: slot)
            model.nodes[id]?.parent = grandParentID
            model.nodes[grandParentID]?.children.insert(id, at: parentSlot + 1)
            purgeStaleSummaries(in: &model)

        case .demote(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("demote needs a parent")
            }
            guard let siblings = model.nodes[parentID]?.children else {
                throw ArborError.commandFailure("missing parent \(parentID)")
            }
            guard let slot = siblings.firstIndex(of: id), slot > 0 else {
                throw ArborError.commandFailure("demote needs a previous sibling")
            }
            let previous = siblings[slot - 1]
            model.nodes[parentID]?.children.remove(at: slot)
            model.nodes[id]?.parent = previous
            model.nodes[previous]?.children.append(id)
            purgeStaleSummaries(in: &model)

        case .detach(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("cannot detach a root")
            }
            model.nodes[parentID]?.children.removeAll { $0 == id }
            model.nodes[id]?.parent = nil
            model.roots.append(id)
            purgeStaleSummaries(in: &model)

        case .insertSubtrees(let mapping, let anchors):
            for (id, node) in mapping.sorted(by: { $0.key < $1.key }) {
                model.nodes[id] = node
            }
            for anchor in anchors {
                if let parentID = anchor.parent {
                    let insertion = Self.clampIndex(anchor.index, parent: parentID, model: model)
                    model.nodes[parentID]?.children.insert(anchor.id, at: insertion)
                } else {
                    let insertion = Self.clampIndex(anchor.index, parent: nil, model: model)
                    model.roots.insert(anchor.id, at: insertion)
                }
            }

        case .group(_, let commands):
            var working = model
            for command in commands {
                try command.apply(to: &working)
            }
            model = working

        case .setSide(let id, let side):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            model.nodes[id]?.side = side

        case .setFolded(let id, let folded):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            model.nodes[id]?.folded = folded

        case .setOffset(let id, let offset):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            model.nodes[id]?.offset = offset

        case .setConnections(let connections):
            model.connections = connections

        case .setBoundaries(let boundaries):
            model.boundaries = boundaries

        case .setSummaries(let summaries):
            model.summaries = summaries
        }
    }

    /// Strips every connection, boundary and summary that references a
    /// removed node, so the model stays structurally valid after a delete.
    /// The delete commands' inverses restore the pre-delete lists wholesale.
    func purgeSecondaryReferences(to removed: Set<String>, in model: inout MapModel) {
        guard !removed.isEmpty else { return }
        let connections = (model.connections ?? []).filter { connection in
            !removed.contains(connection.from) && !removed.contains(connection.to)
        }
        model.connections = connections.isEmpty ? nil : connections

        var boundaries: [Boundary] = []
        for boundary in model.boundaries ?? [] {
            let nodes = boundary.nodes.filter { !removed.contains($0) }
            if nodes.isEmpty { continue }
            if nodes.count == boundary.nodes.count {
                boundaries.append(boundary)
            } else {
                boundaries.append(Boundary(id: boundary.id, nodes: nodes, title: boundary.title, style: boundary.style))
            }
        }
        model.boundaries = boundaries.isEmpty ? nil : boundaries

        let summaries = (model.summaries ?? []).filter { summary in
            !removed.contains(summary.node) && !removed.contains(summary.parent)
                && !summary.range.contains { removed.contains($0) }
        }
        model.summaries = summaries.isEmpty ? nil : summaries
    }

    /// Drops summaries whose range is no longer a run of the summary
    /// parent's children (moves, promotions, demotions and detachments can
    /// break them). The move commands' inverses restore the pre-move list.
    func purgeStaleSummaries(in model: inout MapModel) {
        let summaries = (model.summaries ?? []).filter { summary in
            guard let parent = model.nodes[summary.parent] else { return false }
            guard model.nodes[summary.node] != nil else { return false }
            for rangeID in summary.range where !parent.children.contains(rangeID) {
                return false
            }
            return true
        }
        model.summaries = summaries.isEmpty ? nil : summaries
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    func descendants(of ids: [String], in model: MapModel) -> [String] {
        var result: [String] = []
        var stack = ids
        var visited = Set<String>()
        while let current = stack.popLast() {
            guard visited.insert(current).inserted else { continue }
            for childID in model.nodes[current]?.children ?? [] {
                result.append(childID)
                stack.append(childID)
            }
        }
        return result
    }

    func slotOf(id: String, parent: String?, model: MapModel) -> Int {
        if let parent, let children = model.nodes[parent]?.children {
            return children.firstIndex(of: id) ?? 0
        }
        return model.roots.firstIndex(of: id) ?? 0
    }

    func siblingCount(parent: String?, model: MapModel) -> Int {
        if let parent {
            return model.nodes[parent]?.children.count ?? 0
        }
        return model.roots.count
    }

    static func clamp(_ value: Int, count: Int) -> Int {
        min(max(value, 0), max(count - 1, 0))
    }

    static func clampIndex(_ index: Int?, parent: String?, model: MapModel) -> Int {
        if let parent {
            let count = model.nodes[parent]?.children.count ?? 0
            return min(max(index ?? count, 0), count)
        }
        let count = model.roots.count
        return min(max(index ?? count, 0), count)
    }
}
