import Foundation

/// One level-1 node's persistent palette index assignment (ADR-0009).
/// `index: nil` clears the stored index, returning the node to
/// positional fallback.
public struct PaletteIndexAssignment: Sendable, Equatable, Hashable {
    public let id: String
    public let index: Int?

    public init(id: String, index: Int?) {
        self.id = id
        self.index = index
    }
}

/// Where an inserted subtree top attaches: under `parent` at `index`, or as
/// a root at `index` when `parent` is nil.
public struct InsertionAnchor: Sendable, Equatable, Hashable {
    public let id: String
    public let parent: String?
    public let index: Int

    public init(id: String, parent: String?, index: Int) {
        self.id = id
        self.parent = parent
        self.index = index
    }
}

/// A reversible mutation of a `MapModel` (SPEC §11.1: every change to a map
/// goes through a `MapCommand` with an inverse). Commands are self-contained
/// values: they carry everything needed to apply **and** to invert, so undo
/// and redo are exact. `inverse(in:)` must be evaluated against the model
/// **before** `apply(to:)` runs — that pair is what the document registers
/// with its `UndoManager`.
///
/// Commands are pure structure: they never stamp `modified`/`modifiedBy`;
/// the applying layer records authorship.
public indirect enum MapCommand: Sendable, Equatable {
    /// Creates `node` as a child of `parent`, inserted at `index` (nil
    /// appends; out-of-range indexes clamp).
    case addChild(parent: String, index: Int?, node: Node)
    /// Creates `node` as a sibling of `anchor`, above or below it.
    case addSibling(anchor: String, before: Bool, node: Node)
    /// Creates `node` between `anchor` and its parent, taking the anchor's
    /// slot among its siblings (F-EDT-1: ⌥⇥).
    case insertParent(anchor: String, node: Node)
    /// Creates `node` as a new root, inserted at `index` (nil appends).
    case addRoot(index: Int?, node: Node)
    /// Deletes the subtrees rooted at `ids` (F-EDT-4). The inverse snapshots
    /// everything it removes.
    case deleteSubtrees(ids: [String])
    /// Deletes `id` only, promoting its children into its slot (F-EDT-4:
    /// ⌥⌫).
    case deleteNodePromotingChildren(id: String)
    /// Replaces the title of `id` (F-EDT-7).
    case editText(id: String, title: NodeTitle)
    /// Replaces the Markdown note of `id` (F-CNT-1; find & replace,
    /// F-FOC-3, reaches notes through this command so it is one
    /// undoable step like every other mutation).
    case setNote(id: String, note: String?)
    /// Moves `id`'s subtree to `parent` at `index`; `nil` parent makes it a
    /// root (F-EDT-5). Moving a node into its own subtree throws.
    case moveNode(id: String, parent: String?, index: Int)
    /// Moves `id` among its siblings by `delta` (F-EDT-6: ⌘↑/⌘↓).
    case reorderSibling(id: String, delta: Int)
    /// Promotes `id` one level: becomes the sibling after its parent
    /// (F-EDT-6: ⌘←).
    case promote(id: String)
    /// Demotes `id`: becomes the last child of its previous sibling
    /// (F-EDT-6: ⌘→).
    case demote(id: String)
    /// Detaches `id`'s subtree into a new root (F-EDT-6: ⇧⌘D).
    case detach(id: String)
    /// Inserts pre-generated node snapshots wholesale (the inverse of
    /// deletions, and the payload of duplication).
    case insertSubtrees(mapping: [String: Node], anchors: [InsertionAnchor])
    /// Applies `commands` in order as one undoable step. The inverse undoes
    /// them in reverse.
    case group(name: String, commands: [MapCommand])
    /// Sets the document's pinned side of a root child (F-LAY-1).
    case setSide(id: String, side: SidePin?)
    /// Sets the folded flag of `id` (F-LAY-14).
    case setFolded(id: String, folded: Bool)
    /// Sets the manual offset of `id` (F-LAY-11). `nil` clears it.
    case setOffset(id: String, offset: ModelOffset?)
    /// Replaces the whole connection list. The delete commands use this to
    /// strip references to removed nodes, and their inverses use it to
    /// restore them.
    case setConnections(_ connections: [Connection]?)
    /// Replaces the whole boundary list (see `setConnections`).
    case setBoundaries(_ boundaries: [Boundary]?)
    /// Replaces the whole summary list (see `setConnections`).
    case setSummaries(_ summaries: [Summary]?)
    /// Assigns persistent branch palette indices (F-STY-8 "Recolor
    /// Branches", ADR-0009). Each assignment sets `paletteIndex` — `nil`
    /// clears it back to positional fallback. Exact inverse: the inverse
    /// snapshots the pre-state's values.
    case recolorBranches(assignments: [PaletteIndexAssignment])
    /// Sets the document's theme id (F-STY-3/F-STY-4), preserving any
    /// stored theme overrides. `nil` clears the selection back to the
    /// default theme.
    case setTheme(id: String?)
    /// Replaces the whole presentation list (M6, F-PRE-2/3). Every
    /// slide-authoring action (add/reorder/duplicate/rename/delete
    /// slide, notes, build orders, presentation create/rename/delete)
    /// performs ONE grouped replacement with a meaningful name — one
    /// undo step — and the inverse restores the pre-action list
    /// exactly, `nil` included.
    case setPresentations(_ presentations: [Presentation]?)
    /// Replaces one node's whole study section (F-STD-1/3/6: the deck
    /// flag, the card policy, the per-card FSRS states). The host builds
    /// the next `NodeStudy` from the current one (toggling the deck,
    /// marking a card, writing a grade — ADR-0015); the inverse snapshots
    /// the pre-state whole, so the restore is exact. `study: nil` removes
    /// the section. `name` is the undo-menu action name ("Make Study
    /// Deck", "Mark Card", "Grade Card").
    case setStudy(name: String, id: String, study: NodeStudy?)

    /// A short, user-facing name for the undo menu (F-DOC-2: "Undo Add
    /// Node"). Localized when the UI layer lands.
    public var displayName: String {
        switch self {
        case .addChild, .addSibling, .insertParent, .addRoot: "Add Node"
        case .deleteSubtrees, .deleteNodePromotingChildren: "Delete Node"
        case .editText: "Edit Text"
        case .setNote: "Edit Note"
        case .moveNode, .reorderSibling, .promote, .demote, .detach: "Move Node"
        case .insertSubtrees: "Duplicate Node"
        case .group(let name, _): name
        case .setSide: "Pin Side"
        case .setFolded: "Fold Node"
        case .setOffset: "Move Node"
        case .setConnections, .setBoundaries, .setSummaries: "Delete Node"
        case .recolorBranches: "Recolor Branches"
        case .setTheme: "Set Theme"
        case .setPresentations: "Edit Slides"
        case .setStudy(let name, _, _): name
        }
    }

    /// True when `nextForward` continues the edit session `previousForward`
    /// started, so the undo manager should coalesce instead of pushing a
    /// new entry (F-DOC-2: typing coalesces into one undo per edit session).
    public static func continuesEdit(previousForward: MapCommand, nextForward: MapCommand) -> Bool {
        guard case .editText(let idPrevious, _) = previousForward,
            case .editText(let idNext, _) = nextForward
        else { return false }
        return idPrevious == idNext
    }

    /// Builds a duplication of `id`'s subtree with fresh ids, inserted as
    /// the next sibling (or next root). The returned `insertSubtrees`
    /// command's inverse deletes the copy. The copy gets fresh timestamps
    /// and no inherited review state — a duplicate is a new node, not a
    /// clone of the original's study history.
    public static func duplicate(id: String, in model: MapModel) throws -> MapCommand {
        guard let node = model.nodes[id] else {
            throw ArborError.commandFailure("missing node \(id)")
        }
        var mapping: [String: Node] = [:]
        let now = Date()

        func copy(_ nodeID: String, parent: String?) -> String {
            let newID = UUID().uuidString
            var snapshot = model.nodes[nodeID]!
            snapshot.id = newID
            snapshot.parent = parent
            snapshot.created = now
            snapshot.modified = now
            if var study = snapshot.study {
                // A duplicate is a new node, not a clone of the study
                // history: the whole scheduling state goes (ADR-0015).
                study.fsrs = nil
                study.fsrsByCard = nil
                snapshot.study = study
            }
            snapshot.children = model.nodes[nodeID]!.children.map { copy($0, parent: newID) }
            mapping[newID] = snapshot
            return newID
        }

        let rootCopy = copy(id, parent: nil)
        var rootSnapshot = mapping[rootCopy]!
        rootSnapshot.parent = node.parent
        mapping[rootCopy] = rootSnapshot
        if let parentID = node.parent {
            let slot = model.nodes[parentID]?.children.firstIndex(of: id) ?? 0
            return .insertSubtrees(
                mapping: mapping, anchors: [InsertionAnchor(id: rootCopy, parent: parentID, index: slot + 1)])
        }
        let rootIndex = model.roots.firstIndex(of: id) ?? model.roots.count
        return .insertSubtrees(
            mapping: mapping, anchors: [InsertionAnchor(id: rootCopy, parent: nil, index: rootIndex + 1)])
    }

    /// Builds the F-STY-8 "Recolor Branches" action for one root: each
    /// level-1 child takes the next child's persistent palette index
    /// (the last wraps to the first), a pure rotation of the stored
    /// values. Nodes without a stored index contribute `nil`, their
    /// positional fallback. The inverse (a snapshot of the pre-state)
    /// is exact.
    public static func recolorBranches(rootID: String, in model: MapModel) -> MapCommand {
        let children = model.nodes[rootID]?.children ?? []
        let values = children.map { model.nodes[$0]?.paletteIndex }
        let assignments = children.enumerated().map { position, childID in
            let rotated = children.isEmpty ? nil : values[(position + 1) % children.count]
            return PaletteIndexAssignment(id: childID, index: rotated)
        }
        return .recolorBranches(assignments: assignments)
    }
}
