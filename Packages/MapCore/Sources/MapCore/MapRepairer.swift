import Foundation

/// One concrete repair applied while loading a package (SPEC §8.2: the
/// loader validates, repairs what it can, and logs).
public enum RepairAction: Sendable, Hashable {
    case removedMissingRoot(id: String)
    case removedDuplicateRoot(id: String)
    case clearedParentOfRoot(id: String)
    case promotedOrphanToRoot(id: String)
    case removedDanglingChild(nodeID: String, childID: String)
    case removedDuplicateChild(nodeID: String, childID: String)
    case removedChildBacklink(nodeID: String, childID: String)
    case relinkedChild(nodeID: String, parentID: String)
    case brokeCycle(nodeID: String, parentID: String)
    case droppedConnection(connectionID: String, endpointID: String)
    case removedBoundaryNode(boundaryID: String, nodeID: String)
    case droppedBoundary(boundaryID: String)
    case removedTagReference(nodeID: String, tagID: String)
    case droppedSummary(summaryID: String)
}

/// The outcome of a conservative repair pass: the repaired model, the
/// actions that were applied, and the violations that could not be fixed.
public struct RepairOutcome: Sendable {
    public let model: MapModel
    public let applied: [RepairAction]
    public let remaining: [ValidationError]
}

/// Conservative structural repair. Policy: never delete node data. Parent
/// pointers are authoritative for hierarchy (children lists are resynced to
/// them); nodes that lose their parent become roots; cycles are broken by
/// promoting their deterministically-chosen lowest-ID member to a root;
/// secondary objects (connections, boundaries, summaries, tag references)
/// drop only the references that point at nothing. The pass is
/// deterministic: nodes are processed in `created` order, ties broken by ID,
/// so the same broken file always repairs identically.
public enum MapRepairer {
    public static func repair(_ model: MapModel) -> RepairOutcome {
        var repaired = model
        var applied: [RepairAction] = []

        repairRoots(&repaired, into: &applied)
        repairOrphans(&repaired, into: &applied)
        repairHierarchy(&repaired, into: &applied)
        repairCycles(&repaired, into: &applied)
        repairConnections(&repaired, into: &applied)
        repairBoundaries(&repaired, into: &applied)
        repairSummaries(&repaired, into: &applied)
        repairTags(&repaired, into: &applied)

        return RepairOutcome(
            model: repaired, applied: applied, remaining: MapValidator.validate(repaired))
    }

    /// Deterministic processing order: creation time, then ID.
    private static func nodeOrder(_ model: MapModel) -> [String] {
        model.nodes.keys.sorted { lhs, rhs in
            let left = model.nodes[lhs]
            let right = model.nodes[rhs]
            if let left, let right, left.created != right.created {
                return left.created < right.created
            }
            return lhs < rhs
        }
    }

    private static func repairRoots(_ model: inout MapModel, into applied: inout [RepairAction]) {
        var seen = Set<String>()
        var roots: [String] = []
        for rootID in model.roots {
            if model.nodes[rootID] == nil {
                applied.append(.removedMissingRoot(id: rootID))
                continue
            }
            if !seen.insert(rootID).inserted {
                applied.append(.removedDuplicateRoot(id: rootID))
                continue
            }
            if model.nodes[rootID]?.parent != nil {
                model.nodes[rootID]?.parent = nil
                applied.append(.clearedParentOfRoot(id: rootID))
            }
            roots.append(rootID)
        }
        model.roots = roots
    }

    private static func repairOrphans(_ model: inout MapModel, into applied: inout [RepairAction]) {
        for id in nodeOrder(model) {
            if let parentID = model.nodes[id]?.parent, model.nodes[parentID] == nil {
                model.nodes[id]?.parent = nil
                if !model.roots.contains(id) {
                    model.roots.append(id)
                }
                applied.append(.promotedOrphanToRoot(id: id))
            }
            if model.nodes[id]?.parent == nil, !model.roots.contains(id) {
                model.roots.append(id)
                applied.append(.promotedOrphanToRoot(id: id))
            }
        }
    }

    private static func repairHierarchy(
        _ model: inout MapModel, into applied: inout [RepairAction]
    ) {
        let ids = nodeOrder(model)

        for id in ids {
            guard let parentID = model.nodes[id]?.parent, model.nodes[parentID] != nil else {
                continue
            }
            if !(model.nodes[parentID]?.children.contains(id) ?? false) {
                model.nodes[parentID]?.children.append(id)
                applied.append(.relinkedChild(nodeID: id, parentID: parentID))
            }
        }

        for id in ids {
            guard var node = model.nodes[id] else { continue }
            var children: [String] = []
            var seen = Set<String>()
            for childID in node.children {
                guard model.nodes[childID] != nil else {
                    applied.append(.removedDanglingChild(nodeID: id, childID: childID))
                    continue
                }
                if !seen.insert(childID).inserted {
                    applied.append(.removedDuplicateChild(nodeID: id, childID: childID))
                    continue
                }
                if model.nodes[childID]?.parent == id {
                    children.append(childID)
                } else {
                    applied.append(.removedChildBacklink(nodeID: id, childID: childID))
                }
            }
            node.children = children
            model.nodes[id] = node
        }
    }

    /// Breaks unreachable cycles: walk parents from an unreachable node
    /// until a cycle closes, clear the parent of its lowest-ID member and
    /// promote that member to a root, then resync the hierarchy. Repeats
    /// until every node is reachable. Never deletes node data.
    private static func repairCycles(_ model: inout MapModel, into applied: inout [RepairAction]) {
        let order = nodeOrder(model)
        var guardCount = model.nodes.count + 1

        while guardCount > 0 {
            guardCount -= 1
            let unreachable = unreachableNodes(model, order: order)
            guard let entry = unreachable.first else { return }

            let breaker = cycleMembers(model: model, entry: entry).min() ?? entry
            let brokenParent = model.nodes[breaker]?.parent
            model.nodes[breaker]?.parent = nil
            if !model.roots.contains(breaker) {
                model.roots.append(breaker)
            }
            if let brokenParent {
                applied.append(.brokeCycle(nodeID: breaker, parentID: brokenParent))
            }
            repairHierarchy(&model, into: &applied)
        }
    }

    /// Nodes not reachable from the current roots via children lists.
    private static func unreachableNodes(_ model: MapModel, order: [String]) -> [String] {
        var reachable = Set<String>()
        var stack = model.roots
        while let current = stack.popLast() {
            guard reachable.insert(current).inserted else { continue }
            stack.append(contentsOf: model.nodes[current]?.children ?? [])
        }
        return order.filter { !reachable.contains($0) }
    }

    /// The members of the first cycle found by walking parents from `entry`.
    private static func cycleMembers(model: MapModel, entry: String) -> [String] {
        var walk = entry
        var seen = Set<String>()
        var path: [String] = []
        while let parent = model.nodes[walk]?.parent, model.nodes[parent] != nil, !seen.contains(walk) {
            seen.insert(walk)
            path.append(walk)
            walk = parent
        }
        guard seen.contains(walk), let start = path.firstIndex(of: walk) else {
            return []
        }
        return Array(path[start...])
    }

    private static func repairConnections(
        _ model: inout MapModel, into applied: inout [RepairAction]
    ) {
        let connections = (model.connections ?? []).filter { connection in
            for endpoint in [connection.from, connection.to] where model.nodes[endpoint] == nil {
                applied.append(
                    .droppedConnection(connectionID: connection.id, endpointID: endpoint))
                return false
            }
            return true
        }
        model.connections = connections.isEmpty ? nil : connections
    }

    private static func repairBoundaries(
        _ model: inout MapModel, into applied: inout [RepairAction]
    ) {
        var boundaries: [Boundary] = []
        for boundary in model.boundaries ?? [] {
            let nodes = boundary.nodes.filter { nodeID in
                if model.nodes[nodeID] == nil {
                    applied.append(.removedBoundaryNode(boundaryID: boundary.id, nodeID: nodeID))
                    return false
                }
                return true
            }
            if nodes.isEmpty {
                applied.append(.droppedBoundary(boundaryID: boundary.id))
                continue
            }
            boundaries.append(
                Boundary(id: boundary.id, nodes: nodes, title: boundary.title, style: boundary.style))
        }
        model.boundaries = boundaries.isEmpty ? nil : boundaries
    }

    private static func repairSummaries(
        _ model: inout MapModel, into applied: inout [RepairAction]
    ) {
        var summaries: [Summary] = []
        for summary in model.summaries ?? [] {
            let parent = model.nodes[summary.parent]
            let nodeExists = model.nodes[summary.node] != nil
            let rangeValid =
                parent != nil
                && summary.range.allSatisfy { parent?.children.contains($0) ?? false }
            if !nodeExists || !rangeValid {
                applied.append(.droppedSummary(summaryID: summary.id))
                continue
            }
            summaries.append(summary)
        }
        model.summaries = summaries.isEmpty ? nil : summaries
    }

    private static func repairTags(_ model: inout MapModel, into applied: inout [RepairAction]) {
        let declared = Set((model.tags ?? []).map(\.id))
        for id in nodeOrder(model) {
            guard let references = model.nodes[id]?.tags, !references.isEmpty else { continue }
            let filtered = references.filter { tagID in
                if declared.contains(tagID) {
                    return true
                }
                applied.append(.removedTagReference(nodeID: id, tagID: tagID))
                return false
            }
            model.nodes[id]?.tags = filtered
        }
    }
}
