import Foundation

public enum ValidationError: Error, Sendable, Hashable {
    case missingNode(id: String)
    case orphanNode(id: String)
    case rootIsNotRoot(id: String)
    case danglingParent(nodeID: String, parentID: String)
    case danglingChild(nodeID: String, childID: String)
    case parentChildMismatch(nodeID: String, parentID: String)
    case cycle(nodeID: String)
    case unreachableNode(id: String)
    case danglingConnection(connectionID: String, endpointID: String)
    case danglingBoundary(boundaryID: String, nodeID: String)
    case danglingSummaryNode(summaryID: String, nodeID: String)
    case summaryRangeNotChildren(summaryID: String, nodeID: String)
    case danglingTag(nodeID: String, tagID: String)
    case duplicateRoot(id: String)
}

/// Checks the structural invariants of SPEC §8.2. Validation is
/// non-destructive: it only reports.
public enum MapValidator {
    public static func validate(_ model: MapModel) -> [ValidationError] {
        var errors = validateRoots(model)
        errors.append(contentsOf: validateHierarchy(model))
        errors.append(contentsOf: validateTags(model))
        errors.append(contentsOf: detectCycles(model))
        errors.append(contentsOf: validateConnections(model))
        errors.append(contentsOf: validateBoundaries(model))
        errors.append(contentsOf: validateSummaries(model))
        return errors
    }

    private static func validateRoots(_ model: MapModel) -> [ValidationError] {
        var errors: [ValidationError] = []
        var seenRoots = Set<String>()
        for rootID in model.roots {
            guard model.nodes[rootID] != nil else {
                errors.append(.missingNode(id: rootID))
                continue
            }
            if !seenRoots.insert(rootID).inserted {
                errors.append(.duplicateRoot(id: rootID))
            }
            if model.nodes[rootID]?.parent != nil {
                errors.append(.rootIsNotRoot(id: rootID))
            }
        }
        return errors
    }

    private static func validateHierarchy(_ model: MapModel) -> [ValidationError] {
        var errors: [ValidationError] = []
        for (id, node) in model.nodes {
            if node.parent == nil, !model.roots.contains(id) {
                errors.append(.orphanNode(id: id))
            }
            if let parentID = node.parent {
                guard let parent = model.nodes[parentID] else {
                    errors.append(.danglingParent(nodeID: id, parentID: parentID))
                    continue
                }
                if !parent.children.contains(id) {
                    errors.append(.parentChildMismatch(nodeID: id, parentID: parentID))
                }
            }
            for childID in node.children {
                guard let child = model.nodes[childID] else {
                    errors.append(.danglingChild(nodeID: id, childID: childID))
                    continue
                }
                if child.parent != id {
                    errors.append(.parentChildMismatch(nodeID: childID, parentID: id))
                }
            }
        }
        return errors
    }

    private static func validateTags(_ model: MapModel) -> [ValidationError] {
        var errors: [ValidationError] = []
        let declaredTags = Set((model.tags ?? []).map(\.id))
        for (id, node) in model.nodes {
            for tagID in node.tags ?? [] where !declaredTags.contains(tagID) {
                errors.append(.danglingTag(nodeID: id, tagID: tagID))
            }
        }
        return errors
    }

    private static func validateConnections(_ model: MapModel) -> [ValidationError] {
        var errors: [ValidationError] = []
        for connection in model.connections ?? [] {
            for endpoint in [connection.from, connection.to]
            where model.nodes[endpoint] == nil {
                errors.append(
                    .danglingConnection(connectionID: connection.id, endpointID: endpoint))
            }
        }
        return errors
    }

    private static func validateBoundaries(_ model: MapModel) -> [ValidationError] {
        var errors: [ValidationError] = []
        for boundary in model.boundaries ?? [] {
            for nodeID in boundary.nodes where model.nodes[nodeID] == nil {
                errors.append(.danglingBoundary(boundaryID: boundary.id, nodeID: nodeID))
            }
        }
        return errors
    }

    private static func validateSummaries(_ model: MapModel) -> [ValidationError] {
        var errors: [ValidationError] = []
        for summary in model.summaries ?? [] {
            if model.nodes[summary.node] == nil {
                errors.append(.danglingSummaryNode(summaryID: summary.id, nodeID: summary.node))
            }
            guard let parent = model.nodes[summary.parent] else {
                errors.append(.danglingSummaryNode(summaryID: summary.id, nodeID: summary.parent))
                continue
            }
            for rangeID in summary.range where !parent.children.contains(rangeID) {
                errors.append(.summaryRangeNotChildren(summaryID: summary.id, nodeID: rangeID))
            }
        }
        return errors
    }

    private static func detectCycles(_ model: MapModel) -> [ValidationError] {
        var errors: [ValidationError] = []
        var visited = Set<String>()
        var onStack = Set<String>()

        func visit(_ id: String) {
            guard visited.insert(id).inserted else { return }
            onStack.insert(id)
            if let node = model.nodes[id] {
                for childID in node.children {
                    if onStack.contains(childID) {
                        errors.append(.cycle(nodeID: childID))
                    } else {
                        visit(childID)
                    }
                }
            }
            onStack.remove(id)
        }

        for rootID in model.roots {
            visit(rootID)
        }
        for id in model.nodes.keys where !visited.contains(id) {
            errors.append(.unreachableNode(id: id))
            visit(id)
        }
        return errors
    }
}
