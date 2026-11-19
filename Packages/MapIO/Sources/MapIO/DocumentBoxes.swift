import Foundation
import MapCore

/// A parsed node while importing a whole external document: every field
/// the F-IO formats can carry — a title with inline runs, a note, a task,
/// tag *names* (declared as `Tag`s during assembly), structure, folded
/// state, a pinned side and a link — plus children. Format-specific cross
/// links (FreeMind `arrowlink`, XMind relationships) are resolved after
/// assembly through the external-id map, because only the assembler
/// knows which Arbor id each parsed node received.
///
/// Like `MutableOutline`, this is a non-Sendable builder class: parsing
/// is a strictly local synchronous pass and the tree never escapes it.
final class DocumentBox {
    var title: NodeTitle
    var note: String?
    var task: NodeTask?
    var tagNames: [String]
    var structure: String?
    var folded: Bool
    var side: SidePin?
    var link: String?
    /// The format-native id (XMind topic id, FreeMind `ID`, MindNode
    /// uuid) so cross links can be resolved after assembly.
    var externalID: String?
    var children: [DocumentBox]

    init(
        title: NodeTitle = NodeTitle(text: ""),
        note: String? = nil,
        task: NodeTask? = nil,
        tagNames: [String] = [],
        structure: String? = nil,
        folded: Bool = false,
        side: SidePin? = nil,
        link: String? = nil,
        externalID: String? = nil,
        children: [DocumentBox] = []
    ) {
        self.title = title
        self.note = note
        self.task = task
        self.tagNames = tagNames
        self.structure = structure
        self.folded = folded
        self.side = side
        self.link = link
        self.externalID = externalID
        self.children = children
    }
}

/// Assembles a `MapModel` from parsed `DocumentBox` roots: fresh ids and
/// timestamps, tag names deduplicated into declared `Tag`s, and a final
/// `MapRepairer` pass, so every importer's result passes `MapValidator`
/// (SPEC §5.17: "All importers produce a MapModel and go through
/// validation").
final class DocumentAssembler {
    private var model = MapModel.emptyDocument()
    private let stamp = Date()
    private var tagIDs: [String: String] = [:]
    private var externalIDs: [String: String] = [:]

    /// The color a tag declared only by name gets (OPML/Markdown carry no
    /// tag colors); listed as a lossy field in docs/io/format-matrix.md.
    private static let defaultTagColor = "#5E6AD2"

    init(title: String?) {
        model.title = title
    }

    /// Adds one parsed root and returns its Arbor id. The box's
    /// `externalID` (and every descendant's) is registered so cross links
    /// resolve via `arborID(forExternal:)` afterwards.
    @discardableResult
    func addRoot(_ box: DocumentBox) -> String {
        let rootID = add(box, parent: nil)
        model.roots.append(rootID)
        return rootID
    }

    /// The Arbor id a format-native id (XMind topic id, FreeMind `ID`)
    /// was assigned, for resolving cross links after the tree assembly.
    func arborID(forExternal externalID: String) -> String? {
        externalIDs[externalID]
    }

    /// The Arbor ids of a parsed node's children, in order, so range-based
    /// constructs (XMind boundaries/summaries) can be applied afterwards.
    func arborChildren(ofExternal externalID: String) -> [String] {
        guard let nodeID = externalIDs[externalID] else { return [] }
        return model.nodes[nodeID]?.children ?? []
    }

    func addConnection(from: String, to: String, label: String?) {
        guard model.nodes[from] != nil, model.nodes[to] != nil else { return }
        model.connections =
            (model.connections ?? [])
            + [Connection(id: UUID().uuidString, from: from, to: to, label: label)]
    }

    func addBoundary(nodes: [String], title: String?) {
        guard !nodes.isEmpty else { return }
        model.boundaries =
            (model.boundaries ?? [])
            + [Boundary(id: UUID().uuidString, nodes: nodes, title: title)]
    }

    /// The summary node Arbor needs for XMind's summaries, when the file
    /// does not carry one: appended as the parent's last child.
    @discardableResult
    func addSummaryNode(parent: String, title: String) -> String {
        let nodeID = UUID().uuidString
        model.nodes[nodeID] = Node(
            id: nodeID, parent: parent, title: NodeTitle(text: title),
            created: stamp, modified: stamp)
        model.nodes[parent]?.children.append(nodeID)
        return nodeID
    }

    func addSummary(parent: String, range: [String], node: String) {
        guard model.nodes[parent] != nil, model.nodes[node] != nil, range.count == 2 else { return }
        model.summaries =
            (model.summaries ?? [])
            + [Summary(id: UUID().uuidString, parent: parent, range: range, node: node)]
    }

    /// The assembled document, structurally repaired so `MapValidator`
    /// reports nothing (importers build clean trees, so the repair pass
    /// is normally a no-op safety net). Computed once, on first access.
    lazy var result: MapModel = MapRepairer.repair(model).model

    private func add(_ box: DocumentBox, parent: String?) -> String {
        let nodeID = UUID().uuidString
        if let externalID = box.externalID {
            externalIDs[externalID] = nodeID
        }
        let node = Node(
            id: nodeID,
            parent: parent,
            title: box.title,
            note: box.note,
            structure: box.structure,
            side: box.side,
            folded: box.folded,
            link: box.link,
            tags: box.tagNames.isEmpty ? nil : box.tagNames.map(tagID(for:)),
            task: box.task,
            created: stamp,
            modified: stamp
        )
        model.nodes[nodeID] = node
        if let parent {
            model.nodes[parent]?.children.append(nodeID)
        }
        for child in box.children {
            _ = add(child, parent: nodeID)
        }
        return nodeID
    }

    /// Declares `name` once and returns its stable tag id.
    private func tagID(for name: String) -> String {
        if let known = tagIDs[name] { return known }
        let tagID = UUID().uuidString
        model.tags =
            (model.tags ?? [])
            + [Tag(id: tagID, name: name, color: Self.defaultTagColor)]
        tagIDs[name] = tagID
        return tagID
    }
}
