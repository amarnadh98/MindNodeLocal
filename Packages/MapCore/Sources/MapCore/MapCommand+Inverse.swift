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
                ])

        case .deleteSubtrees(let ids):
            return .insertSubtrees(mapping: subtreeMapping(of: ids, in: model), anchors: anchors(of: ids, in: model))

        case .deleteNodePromotingChildren(let id):
            return try deletePromotingInverse(id: id, model: model)

        case .editText(let id, let title):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            return .editText(id: id, title: node.title)

        case .moveNode(let id, _, _):
            guard let node = model.nodes[id] else {
                throw ArborError.commandFailure("missing node \(id)")
            }
            let slot = slotOf(id: id, parent: node.parent, model: model)
            return .moveNode(id: id, parent: node.parent, index: slot)

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
            return .moveNode(id: id, parent: parentID, index: slot)

        case .demote(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("cannot demote a root")
            }
            let slot = slotOf(id: id, parent: parentID, model: model)
            return .moveNode(id: id, parent: parentID, index: slot)

        case .detach(let id):
            guard let node = model.nodes[id], let parentID = node.parent else {
                throw ArborError.commandFailure("cannot detach a root")
            }
            let slot = slotOf(id: id, parent: parentID, model: model)
            return .moveNode(id: id, parent: parentID, index: slot)

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
    /// old slot with no children, then move each promoted child back under

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
            restoreCommands.append(.addChild(parent: parentID, index: slot, node: restore))
        } else {
            let rootIndex = model.roots.firstIndex(of: id) ?? model.roots.count
            restoreCommands.append(.addRoot(index: rootIndex, node: restore))
        }
        for (position, childID) in childrenOrder.enumerated() {
            restoreCommands.append(.moveNode(id: childID, parent: id, index: position))
        }
        return .group(name: displayName, commands: restoreCommands)
    }

    /// Snapshots of the subtrees rooted at `ids` (for the inverse of
    /// deletion), parents and children intact; the anchors carry the

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

    private func anchors(of ids: [String], in model: MapModel) -> [InsertionAnchor] {
        ids.compactMap { id in
            guard let node = model.nodes[id] else { return nil }
            let slot = slotOf(id: id, parent: node.parent, model: model)
            return InsertionAnchor(id: id, parent: node.parent, index: slot)
        }
    }
}
