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
            inserted.paletteIndex = model.createdPaletteIndex(for: inserted, parent: parentID)
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
            inserted.paletteIndex = model.createdPaletteIndex(for: inserted, parent: anchor.parent)
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
            inserted.paletteIndex = model.createdPaletteIndex(for: inserted, parent: anchor.parent)
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

        case .setNote(let id, let note):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            // An empty note is no note: the decoration reads nil as
            // "nothing to show" (F-CNT-1's ≡ icon).
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            model.nodes[id]?.note = (trimmed?.isEmpty ?? true) ? nil : note

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

        case .addConnection(let connection):
            try Self.validateConnection(connection, in: model)
            var connections = model.connections ?? []
            if let slot = connections.firstIndex(where: { $0.id == connection.id }) {
                connections[slot] = connection
            } else {
                connections.append(connection)
            }
            model.connections = connections

        case .removeConnection(let id):
            let connections = (model.connections ?? []).filter { $0.id != id }
            model.connections = connections.isEmpty ? nil : connections

        case .editConnection(let id, let connection):
            try Self.validateConnection(connection, in: model)
            guard var connections = model.connections,
                let slot = connections.firstIndex(where: { $0.id == id })
            else {
                throw ArborError.commandFailure("missing connection \(id)")
            }
            connections[slot] = connection
            model.connections = connections

        case .addBoundary(let boundary):
            for nodeID in boundary.nodes where model.nodes[nodeID] == nil {
                throw ArborError.commandFailure("missing node \(nodeID)")
            }
            var boundaries = model.boundaries ?? []
            if let slot = boundaries.firstIndex(where: { $0.id == boundary.id }) {
                boundaries[slot] = boundary
            } else {
                boundaries.append(boundary)
            }
            model.boundaries = boundaries

        case .removeBoundary(let id):
            let boundaries = (model.boundaries ?? []).filter { $0.id != id }
            model.boundaries = boundaries.isEmpty ? nil : boundaries

        case .editBoundary(let id, let boundary):
            for nodeID in boundary.nodes where model.nodes[nodeID] == nil {
                throw ArborError.commandFailure("missing node \(nodeID)")
            }
            guard var boundaries = model.boundaries,
                let slot = boundaries.firstIndex(where: { $0.id == id })
            else {
                throw ArborError.commandFailure("missing boundary \(id)")
            }
            boundaries[slot] = boundary
            model.boundaries = boundaries

        case .addSummary(let summary):
            try Self.validateSummary(summary, in: model)
            var summaries = model.summaries ?? []
            if let slot = summaries.firstIndex(where: { $0.id == summary.id }) {
                summaries[slot] = summary
            } else {
                summaries.append(summary)
            }
            model.summaries = summaries

        case .removeSummary(let id):
            let summaries = (model.summaries ?? []).filter { $0.id != id }
            model.summaries = summaries.isEmpty ? nil : summaries

        case .recolorBranches(let assignments):
            // All-or-nothing: every id must exist before any index moves.
            for assignment in assignments where model.nodes[assignment.id] == nil {
                throw ArborError.commandFailure("missing node \(assignment.id)")
            }
            for assignment in assignments {
                model.nodes[assignment.id]?.paletteIndex = assignment.index
            }

        case .setTheme(let id):
            model.theme = id.map { ThemeSelection(id: $0, overrides: model.theme?.overrides) }

        case .setAppearance(let mode):
            model.appearance = mode

        case .setPresentations(let presentations):
            // M6 (F-PRE-2/3): a wholesale replace — the authoring layer
            // builds the whole new list and groups the command under an
            // action name ("Add Slide", …), one undo step per action.
            model.presentations = presentations
        case .setStudy(_, let id, let study):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            model.nodes[id]?.study = study
        case .setLink(let id, let link):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            // A whitespace-only link is no link (F-CNT-4): trim, and an
            // empty result clears the stored value.
            let trimmed = link?.trimmingCharacters(in: .whitespacesAndNewlines)
            model.nodes[id]?.link = (trimmed?.isEmpty ?? true) ? nil : trimmed

        case .setAIPolicy(let policy):
            model.ai = policy

        case .setTitle(let title):
            model.title = title

        case .setTask(let ids, let isTask):
            // All-or-nothing: every id must exist before any task moves.
            for id in ids where model.nodes[id] == nil {
                throw ArborError.commandFailure("missing node \(id)")
            }
            for id in ids {
                if isTask {
                    if model.nodes[id]?.task == nil {
                        model.nodes[id]?.task = NodeTask()
                    }
                } else {
                    model.nodes[id]?.task = nil
                }
            }

        case .setTaskDone(let ids, let done):
            for id in ids where model.nodes[id] == nil {
                throw ArborError.commandFailure("missing node \(id)")
            }
            for id in ids {
                // A completion request on a non-task is a no-op, not a
                // failure: grouped commands (complete-all) target only
                // leaf tasks, but multi-selects can mix both kinds.
                guard var task = model.nodes[id]?.task else { continue }
                task.done = done
                model.nodes[id]?.task = task
            }

        case .setTaskDetails(let id, let due, let priority, let `repeat`):
            guard var task = model.nodes[id]?.task else {
                throw ArborError.commandFailure("node \(id) is not a task")
            }
            task.due = due
            task.priority = priority
            task.`repeat` = `repeat`
            model.nodes[id]?.task = task

        case .setTaskValue(let id, let task):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            model.nodes[id]?.task = task

        case .setTags(let tags):
            model.tags = tags

        case .toggleTag(let ids, let tagID, let assigned):
            for id in ids where model.nodes[id] == nil {
                throw ArborError.commandFailure("missing node \(id)")
            }
            for id in ids {
                var tags = model.nodes[id]?.tags ?? []
                if assigned {
                    if !tags.contains(tagID) {
                        tags.append(tagID)
                        model.nodes[id]?.tags = tags
                    }
                } else if let slot = tags.firstIndex(of: tagID) {
                    tags.remove(at: slot)
                    model.nodes[id]?.tags = tags.isEmpty ? nil : tags
                }
            }

        case .setNodeTags(let id, let tags):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            model.nodes[id]?.tags = tags
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

    /// A connection's structural preconditions (SPEC §8.2 invariants):
    /// both endpoints exist, and a node never connects to itself.
    static func validateConnection(_ connection: Connection, in model: MapModel) throws {
        guard connection.from != connection.to else {
            throw ArborError.commandFailure("cannot connect a node to itself")
        }
        for endpoint in [connection.from, connection.to] where model.nodes[endpoint] == nil {
            throw ArborError.commandFailure("missing node \(endpoint)")
        }
    }

    /// A summary's structural preconditions (SPEC §8.2): the parent and
    /// summary node exist, and the range is a run of the parent's
    /// children.
    static func validateSummary(_ summary: Summary, in model: MapModel) throws {
        guard let parent = model.nodes[summary.parent] else {
            throw ArborError.commandFailure("missing node \(summary.parent)")
        }
        guard model.nodes[summary.node] != nil else {
            throw ArborError.commandFailure("missing node \(summary.node)")
        }
        for rangeID in summary.range where !parent.children.contains(rangeID) {
            throw ArborError.commandFailure("\(rangeID) is not a child of \(summary.parent)")
        }
    }
}
