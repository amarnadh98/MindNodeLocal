import CoreGraphics
import Foundation
import MapCore
import MapRender

/// Pure relation-command builders (F-REL-1/2/3, SPEC §6.1 Insert): each
/// returns ONE command — or nil when the selection can't produce the
/// relation, so no phantom undo step registers. The host performs them
/// through its `MapStore` (SPEC §11.3: one mutation, one undo step).
public enum RelationCommands {
    /// The connection a ⌘L-click or a Space/⇧ drag-drop creates
    /// (F-REL-1): `nil` when the pair is already connected either way
    /// (a duplicate would render two curves between the same nodes).
    public static func connect(model: MapModel, from: String, to: String) -> MapCommand? {
        guard from != to, model.nodes[from] != nil, model.nodes[to] != nil else { return nil }
        for connection in model.connections ?? [] {
            let pair = Set([connection.from, connection.to])
            if pair == Set([from, to]) { return nil }
        }
        return .addConnection(Connection(id: UUID().uuidString, from: from, to: to))
    }

    /// ⌥⌘G on a selection of siblings (F-REL-2): a boundary around the
    /// selected nodes — one node alone boundaries its whole subtree
    /// (MindNode semantics: the outline wraps member subtrees). Roots
    /// group the other roots; nodes with no shared parent can't be
    /// grouped (a boundary is one family's outline) and return nil.
    public static func boundary(selection: [String], in model: MapModel) -> MapCommand? {
        guard !selection.isEmpty else { return nil }
        let present = selection.filter { model.nodes[$0] != nil }
        guard !present.isEmpty else { return nil }
        if present.count > 1 {
            // `nil` parents (roots) group as their own family.
            let parents = Set(present.map { model.nodes[$0]?.parent ?? "" })
            guard parents.count == 1 else { return nil }
        }
        return .addBoundary(
            Boundary(id: UUID().uuidString, nodes: present.sorted()))
    }

    /// ⇧⌘] on consecutive siblings (F-REL-3): a summary over the range
    /// spanned by the selection — one summary node appended to the
    /// range's parent right after the range, plus the summary record;
    /// one grouped command, one undo step (the inverse removes the node
    /// and the record together). The selection must share a parent;
    /// the covered range extends from the first to the last selected
    /// child (intermediate siblings join the range so it stays a run).
    public static func summary(
        selection: [String], in model: MapModel, summaryNodeID: String = UUID().uuidString
    ) -> MapCommand? {
        let present = selection.filter { model.nodes[$0] != nil }
        guard !present.isEmpty else { return nil }
        let parents = Set(present.compactMap { model.nodes[$0]?.parent })
        guard parents.count == 1, let parent = parents.first else { return nil }
        guard let children = model.nodes[parent]?.children else { return nil }
        let slots = present.compactMap { children.firstIndex(of: $0) }
        guard !slots.isEmpty else { return nil }
        let range = Array(children[slots.min()!...slots.max()!])
        let summaryNode = Node(id: summaryNodeID, title: NodeTitle(text: ""))
        return MapCommand.group(
            name: "Add Summary",
            commands: [
                .addChild(
                    parent: parent, index: children.firstIndex(of: range.last!)! + 1,
                    node: summaryNode),
                .addSummary(
                    Summary(id: UUID().uuidString, parent: parent, range: range, node: summaryNodeID)),
            ])
    }

    /// ⌫ on selected connections (F-REL-1): one grouped removal.
    public static func deleteConnections(ids: [String]) -> MapCommand? {
        let commands = ids.sorted().map { MapCommand.removeConnection(id: $0) }
        switch commands.count {
        case 0:
            return nil
        case 1:
            return commands[0]
        default:
            return .group(name: "Delete Connection", commands: commands)
        }
    }

    /// The connection value after moving its midpoint handle to
    /// `handlePoint` (F-REL-1): the model stores the offset from the
    /// default control (SPEC §8.2), computed by the exact inversion of
    /// the curve math (`handle = (midpoint + control) / 2`).
    public static func moveHandle(
        connection: Connection, handlePoint: CGPoint, anchors: (from: CGPoint, to: CGPoint)
    ) -> MapCommand {
        let offset = RelationPath.controlOffset(
            forHandle: handlePoint, from: anchors.from, to: anchors.to)
        var updated = connection
        updated.control = offset
        return .editConnection(id: connection.id, connection: updated)
    }

    /// Double-click on a connection's handle (F-REL-1: double-click
    /// resets): the stored control offset clears back to the default
    /// bow.
    public static func resetHandle(connection: Connection) -> MapCommand {
        guard connection.control != nil else {
            return .group(name: "Add Connection", commands: [])
        }
        var updated = connection
        updated.control = nil
        return .editConnection(id: connection.id, connection: updated)
    }

    /// One connection-label commit (F-REL-1): empty text clears the
    /// label. A no-op commit (same label) registers no undo step.
    public static func setLabel(
        connection: Connection, label: String
    ) -> MapCommand? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? nil : trimmed
        guard next != connection.label else { return nil }
        var updated = connection
        updated.label = next
        return .editConnection(id: connection.id, connection: updated)
    }
}

extension DragCommands {
    /// A connection drop (F-REL-1: Space during a node drag, or a
    /// ⇧-drag from node to node): the dragged node connects to the
    /// hovered target. One `addConnection` — nil when there is no
    /// hovered node, the drop lands on the dragged node itself, or the
    /// pair is already connected.
    public static func connect(model: MapModel, from: String, target: DropTarget) -> MapCommand? {
        let hovered: String?
        switch target {
        case .reparent(let parent, _), .insertBetween(let parent, _, _):
            hovered = parent
        case .newRoot, .none:
            hovered = nil
        }
        guard let to = hovered else { return nil }
        return RelationCommands.connect(model: model, from: from, to: to)
    }
}
