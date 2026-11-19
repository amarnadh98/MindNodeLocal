import Foundation

extension MapCommand {
    // Command dispatchers are wide switches by design.
    // swiftlint:disable cyclomatic_complexity

    /// The command that undoes this one, evaluated against the model state
    /// **before** this command applies. Applying the returned command to the
    /// post-state restores the pre-state exactly.
    public func inverse(in model: MapModel) throws -> MapCommand {
        switch self {
        case .addChild, .addSibling, .addRoot:
            return .deleteSubtrees(ids: [createdNodeID])

        case .insertParent(let anchorID, let node):
            guard let anchor = model.nodes[anchorID] else {
                throw ArborError.commandFailure("missing anchor \(anchorID)")
            }
            let slot = slotOf(id: anchorID, parent: anchor.parent, model: model)
            return .group(
                name: displayName,
                commands: [
                    .moveNode(id: anchorID, parent: anchor.parent, index: slot),
                    .deleteSubtrees(ids: [node.id]),
                    .setSummaries(model.summaries),
                ])

        case .deleteSubtrees(let ids):
            return .group(
                name: displayName,
                commands: [
                    .insertSubtrees(mapping: subtreeMapping(of: ids, in: model), anchors: anchors(of: ids, in: model)),
                    .setConnections(model.connections),
                    .setBoundaries(model.boundaries),
                    .setSummaries(model.summaries),
                ])

        case .deleteNodePromotingChildren(let id):
            return try deletePromotingInverse(id: id, model: model)

        case .editText(let id, _):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            return .editText(id: id, title: node.title)

        case .setNote(let id, _):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            return .setNote(id: id, note: node.note)

        case .moveNode(let id, _, _):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            let slot = slotOf(id: id, parent: node.parent, model: model)
            return .group(
                name: displayName,
                commands: [
                    .moveNode(id: id, parent: node.parent, index: slot),
                    .setSummaries(model.summaries),
                ])

        case .reorderSibling(let id, let delta):
            guard model.nodes[id] != nil else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            let parent = model.nodes[id]?.parent
            let current = slotOf(id: id, parent: parent, model: model)
            let target = Self.clamp(current + delta, count: siblingCount(parent: parent, model: model))
            return .reorderSibling(id: id, delta: current - target)

        case .promote(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("cannot promote a root")
            }
            let slot = slotOf(id: id, parent: parentID, model: model)
            return .group(
                name: displayName,
                commands: [
                    .moveNode(id: id, parent: parentID, index: slot),
                    .setSummaries(model.summaries),
                ])

        case .demote(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("cannot demote a root")
            }
            let slot = slotOf(id: id, parent: parentID, model: model)
            return .group(
                name: displayName,
                commands: [
                    .moveNode(id: id, parent: parentID, index: slot),
                    .setSummaries(model.summaries),
                ])

        case .detach(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("cannot detach a root")
            }
            let slot = slotOf(id: id, parent: parentID, model: model)
            return .group(
                name: displayName,
                commands: [
                    .moveNode(id: id, parent: parentID, index: slot),
                    .setSummaries(model.summaries),
                ])

        case .insertSubtrees(_, let anchors):
            return .deleteSubtrees(ids: anchors.map(\.id))

        case .group(let name, let commands):
            var working = model
            var inverses: [MapCommand] = []
            inverses.reserveCapacity(commands.count)
            for command in commands {
                inverses.append(try command.inverse(in: working))
                try command.apply(to: &working)
            }
            return .group(name: name, commands: inverses.reversed())

        case .setSide(let id, _):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            return .setSide(id: id, side: node.side)

        case .setFolded(let id, _):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            return .setFolded(id: id, folded: node.folded)

        case .setOffset(let id, _):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            return .setOffset(id: id, offset: node.offset)

        case .setConnections:
            return .setConnections(model.connections)

        case .setBoundaries:
            return .setBoundaries(model.boundaries)

        case .setSummaries:
            return .setSummaries(model.summaries)

        case .recolorBranches(let assignments):
            // Exact snapshot of the pre-state's indices (nil included).
            let snapshot = try assignments.map { assignment -> PaletteIndexAssignment in
                guard let node = model.nodes[assignment.id] else {
                    throw ArborError.commandFailure("missing node \(assignment.id)")
                }
                return PaletteIndexAssignment(id: assignment.id, index: node.paletteIndex)
            }
            return .recolorBranches(assignments: snapshot)

        case .setTheme:
            return .setTheme(id: model.theme?.id)
        }
    }

    // swiftlint:enable cyclomatic_complexity

    private var createdNodeID: String {
        switch self {
        case .addChild(_, _, let node): node.id
        case .addSibling(_, _, let node): node.id
        case .insertParent(_, let node): node.id
        case .addRoot(_, let node): node.id
        default: ""
        }
    }

    /// Inverse of `deleteNodePromotingChildren`: re-insert the node at its
    /// old slot with no children (through `insertSubtrees`, the wholesale
    /// path that never assigns a fresh palette index — the restore is a
    /// snapshot, not a creation), move each promoted child back under it in
    /// the original order, and restore the secondary objects the delete
    /// purged.
    private func deletePromotingInverse(id: String, model: MapModel) throws -> MapCommand {
        guard let node = model.nodes[id] else {
            throw ArborError.commandFailure("missing node \(id)")
        }
        let childrenOrder = node.children
        var restore = node
        restore.children = []
        var restoreCommands: [MapCommand] = []
        if let parentID = node.parent {
            let slot = slotOf(id: id, parent: parentID, model: model)
            restoreCommands.append(
                .insertSubtrees(
                    mapping: [id: restore],
                    anchors: [InsertionAnchor(id: id, parent: parentID, index: slot)]))
        } else {
            let rootIndex = model.roots.firstIndex(of: id) ?? model.roots.count
            // A deleted root can still carry a pinned `side` (however
            // stale for a root); `addRoot`'s payload normalization would
            // drop it and undo would not be exact. `insertSubtrees`
            // restores the snapshot verbatim.
            restoreCommands.append(
                .insertSubtrees(
                    mapping: [id: restore],
                    anchors: [InsertionAnchor(id: id, parent: nil, index: rootIndex)]))
        }
        for (position, childID) in childrenOrder.enumerated() {
            restoreCommands.append(.moveNode(id: childID, parent: id, index: position))
        }
        restoreCommands.append(.setConnections(model.connections))
        restoreCommands.append(.setBoundaries(model.boundaries))
        restoreCommands.append(.setSummaries(model.summaries))
        return .group(name: displayName, commands: restoreCommands)
    }

    /// Snapshots of the subtrees rooted at `ids` (for the inverse of
    /// deletion), parents and children intact; the anchors carry the
    /// re-attachment points.
    private func subtreeMapping(of ids: [String], in model: MapModel) -> [String: Node] {
        var mapping: [String: Node] = [:]
        for id in ids {
            guard let node = model.nodes[id] else { continue }
            mapping[id] = node
            for descendantID in descendants(of: [id], in: model) {
                if let descendant = model.nodes[descendantID] {
                    mapping[descendantID] = descendant
                }
            }
        }
        return mapping
    }

    /// Re-attachment points for the deleted subtrees, in replay order:
    /// anchors sorted by `(parent, slot)` ascending so insertions land at
    /// their pre-delete positions, and excluding ids that are descendants
    /// of other deleted ids — those come back inside their ancestor's
    /// snapshot and must not be inserted twice.
    private func anchors(of ids: [String], in model: MapModel) -> [InsertionAnchor] {
        let deleted = Set(ids)
        var seen = Set<String>()
        var topLevel: [String] = []
        for id in ids where seen.insert(id).inserted {
            var ancestor = model.nodes[id]?.parent
            var isCovered = false
            while let current = ancestor {
                if deleted.contains(current) {
                    isCovered = true
                    break
                }
                ancestor = model.nodes[current]?.parent
            }
            if !isCovered {
                topLevel.append(id)
            }
        }
        let anchors = topLevel.compactMap { id -> InsertionAnchor? in
            guard let node = model.nodes[id] else { return nil }
            let slot = slotOf(id: id, parent: node.parent, model: model)
            return InsertionAnchor(id: id, parent: node.parent, index: slot)
        }
        return anchors.sorted { lhs, rhs in
            let lhsParent = lhs.parent ?? ""
            let rhsParent = rhs.parent ?? ""
            if lhsParent != rhsParent {
                return lhsParent < rhsParent
            }
            return lhs.index < rhs.index
        }
    }
}
