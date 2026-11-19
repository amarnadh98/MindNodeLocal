import Foundation
import MapCore

/// Node lookup for automation (F-INT-1 Find Nodes / Get Node / Add Node
/// parent resolution, MCP `search_nodes`/`update_node`/`move_node`).
/// Title matching is case- and diacritic-insensitive, substring by
/// default (find), exact for references (resolve).
public enum NodeSearch {
    public enum TaskFilter: String, Sendable, Codable {
        case open
        case done
    }

    public struct Query: Sendable, Equatable {
        public var text: String?
        public var tag: String?
        public var task: TaskFilter?

        public init(text: String? = nil, tag: String? = nil, task: TaskFilter? = nil) {
            self.text = text
            self.tag = tag
            self.task = task
        }

        var isEmpty: Bool { text == nil && tag == nil && task == nil }
    }

    public struct Hit: Sendable, Equatable, Codable {
        public let nodeID: String
        public let title: String
        /// "Root › Branch › Node" — the F-STD-1 breadcrumb shape.
        public let breadcrumb: [String]
        public let note: String?
        public let taskDone: Bool?
        public let tags: [String]

        public init(
            nodeID: String, title: String, breadcrumb: [String], note: String?, taskDone: Bool?,
            tags: [String]
        ) {
            self.nodeID = nodeID
            self.title = title
            self.breadcrumb = breadcrumb
            self.note = note
            self.taskDone = taskDone
            self.tags = tags
        }
    }

    /// One match per node, depth-first in outline order (roots in
    /// creation order, then `children` order) — the same order the
    /// outline view shows.
    public static func hits(in model: MapModel, query: Query) -> [Hit] {
        guard !query.isEmpty else { return [] }
        var results: [Hit] = []
        for rootID in model.roots {
            visit(rootID, breadcrumb: [], in: model, query: query, results: &results)
        }
        return results
    }

    /// Whether one node satisfies `query`. An "open" task means the node
    /// HAS a task that is not done — a taskless node matches neither
    /// filter (same semantics as the Find bar's task filter).
    public static func matches(_ node: Node, in model: MapModel, query: Query) -> Bool {
        if let text = query.text, !fuzzyContains(node.title.text, text) { return false }
        if let task = query.task {
            let done = node.task?.done
            switch (task, done) {
            case (.open, .some(false)), (.done, .some(true)):
                break
            default:
                return false
            }
        }
        if let tag = query.tag {
            let names = (node.tags ?? []).compactMap { id in
                (model.tags ?? []).first { $0.id == id }?.name
            }
            guard names.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
                return false
            }
        }
        return true
    }

    /// Resolves a node *reference* — a node id, or a node's exact title
    /// (case-insensitive) — to its id. `nil` when neither matches. The
    /// resolution order (id first) keeps short titles from shadowing
    /// real ids.
    public static func resolve(reference: String, in model: MapModel) -> String? {
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if model.nodes[needle] != nil { return needle }
        for rootID in model.roots {
            if let found = findTitle(rootID, in: model, needle: needle) {
                return found
            }
        }
        return nil
    }

    /// The ancestors of `nodeID`, root first (the breadcrumb).
    public static func breadcrumb(of nodeID: String, in model: MapModel) -> [String] {
        var chain: [String] = []
        var current = model.nodes[nodeID]?.parent
        while let id = current, let node = model.nodes[id] {
            chain.append(node.title.text)
            current = node.parent
        }
        return chain.reversed()
    }

    private static func visit(
        _ nodeID: String, breadcrumb: [String], in model: MapModel, query: Query,
        results: inout [Hit]
    ) {
        guard let node = model.nodes[nodeID] else { return }
        if matches(node, in: model, query: query) {
            let names = (node.tags ?? []).compactMap { id in
                (model.tags ?? []).first { $0.id == id }?.name
            }
            results.append(
                Hit(
                    nodeID: nodeID,
                    title: node.title.text,
                    breadcrumb: breadcrumb,
                    note: node.note,
                    taskDone: node.task?.done,
                    tags: names
                ))
        }
        let childBreadcrumb = breadcrumb + [node.title.text]
        for childID in node.children {
            visit(childID, breadcrumb: childBreadcrumb, in: model, query: query, results: &results)
        }
    }

    private static func findTitle(_ nodeID: String, in model: MapModel, needle: String) -> String? {
        guard let node = model.nodes[nodeID] else { return nil }
        if node.title.text.caseInsensitiveCompare(needle) == .orderedSame {
            return nodeID
        }
        for childID in node.children {
            if let found = findTitle(childID, in: model, needle: needle) {
                return found
            }
        }
        return nil
    }

    /// Case- and diacritic-insensitive substring match.
    public static func fuzzyContains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
