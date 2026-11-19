import Foundation
import MapCore

/// F-AI-2 context extraction: everything the expand-node prompt needs,
/// pulled out of the model as pure data — the ancestor path (root down
/// to the node) and the titles of the node's existing siblings, so the
/// assistant does not repeat them. All of it travels inside the
/// prompt's data delimiters (see `Prompts`).
public enum ExpandContext {
    /// The request for expanding `nodeID`, or nil when the node is
    /// gone (deleted mid-flight).
    public static func request(for nodeID: String, in model: MapModel) -> AIRequest? {
        guard let node = model.nodes[nodeID] else { return nil }
        return Prompts.expandChildren(
            nodeTitle: node.title.text, ancestors: ancestorTitles(of: nodeID, in: model),
            siblings: siblingTitles(of: nodeID, in: model))
    }

    /// Titles from the map's root down to `nodeID`'s parent (the node
    /// itself is in the prompt body, not the path).
    public static func ancestorTitles(of nodeID: String, in model: MapModel) -> [String] {
        var chain: [String] = []
        var current = model.nodes[nodeID]?.parent
        while let id = current {
            guard let node = model.nodes[id] else { break }
            chain.append(node.title.text)
            current = node.parent
        }
        return chain.reversed()
    }

    /// The titles of the node's existing siblings, excluding itself.
    public static func siblingTitles(of nodeID: String, in model: MapModel) -> [String] {
        guard let parent = model.nodes[nodeID]?.parent else {
            return model.roots.filter { $0 != nodeID }.compactMap { model.nodes[$0]?.title.text }
        }
        return (model.nodes[parent]?.children ?? []).filter { $0 != nodeID }.compactMap { model.nodes[$0]?.title.text }
    }
}
