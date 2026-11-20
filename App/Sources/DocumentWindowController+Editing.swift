import AppKit
import CanvasKit
import MapCore
import MapRender

// The inline-editing commit funnel and the create actions (SPEC §11.4,
// F-EDT-1/2), split out of the controller body to keep the shared file
// under the lint budgets. Everything here is the same
// `DocumentWindowController`: one editing commit is ONE `editText`
// command through the store, then the post-commit create; a node made
// and left blank is dropped deterministically (ADR-0034) — never via
// the undo manager.
extension DocumentWindowController {
    // MARK: inline editing (SPEC §11.4, F-EDT-1/2)

    /// One editing commit: ONE `editText` command through the store
    /// (F-DOC-2), the session closed so the next edit of the same node is
    /// its own undo step, then the post-commit create (if any) with the
    /// new node selected and in edit mode. Internal: the hosted tests
    /// drive the real commit path (the M3 smart-typing suites).
    func handleEditingCommit(id: String, title: NodeTitle, next: NodeTextEditor.PostCommitAction) {
        editingDraftTitle = nil
        guard let store else { return }
        // The record of a fresh inserted parent is consumed by its first
        // commit — empty drops it (promoting the anchor back into its
        // slot), anything else makes it a normal node.
        let freshInsertedParent = freshInsertedParentID == id
        freshInsertedParentID = nil
        // A node made and left empty just goes away — no stray blank
        // boxes to tidy up. (Clearing an existing node's text keeps the
        // node.)
        if title.text.isEmpty, dropBlankNewNode(id, freshInsertedParent: freshInsertedParent) {
            return
        }
        if store.model.nodes[id]?.title != title {
            // F-EDT-10 smart typing: one grouped command carries the
            // whole parse — `#tag` tokens, the task prefixes, `$$math$$`,
            // ``` code fences and the `--` note split — so the entire
            // commit is one undo step.
            let parse = SmartTyping.parseCommit(in: title)
            if parse == SmartTyping.CommitParse(title: title) {
                try? store.perform(.editText(id: id, title: title))
            } else {
                try? store.perform(
                    .smartCommit(id: id, parse: parse, in: store.model))
            }
        }
        // One undo step per edit session (F-DOC-2): close the typing
        // session so a second session on this node registers separately.
        store.closeEditSession()
        canvas.setSelection([id])

        switch next {
        case .none:
            break
        case .child:
            createAfterCommit(anchor: id, inheritingSide: false, shape: childCreationShape(parent: id)) {
                .addChild(parent: $0, index: nil, node: $1)
            }
        case .siblingBelow:
            createAfterCommit(
                anchor: id, inheritingSide: true, shape: siblingCreationShape(anchor: id)
            ) {
                .addSibling(anchor: $0, before: false, node: $1)
            }
        case .siblingAbove:
            createAfterCommit(
                anchor: id, inheritingSide: true, shape: siblingCreationShape(anchor: id)
            ) {
                .addSibling(anchor: $0, before: true, node: $1)
            }
        case .insertParent:
            // The inserted parent keeps the theme's level style for its
            // new depth (ADR-0037 leaves it to the theme).
            freshInsertedParentID = createAfterCommit(anchor: id, inheritingSide: true, shape: nil) {
                .insertParent(anchor: $0, node: $1)
            }
        }
    }

    /// True when the editing session ends with no text on a node this
    /// controller created blank, and it is safe to remove: the node's
    /// stored title was still empty (so this session never had content
    /// to lose — clearing an existing node's text keeps the node) and
    /// it is not the map's only root. Deletes it — deterministically,
    /// through one `MapCommand` — selects what the delete leaves
    /// selected, and reports whether it did.
    ///
    /// Never through `undo()`: with the app's real undo grouping
    /// (`UndoManager.groupsByEvent`) a commit-and-create presses two
    /// commands — the just-typed `editText` and the post-commit add —
    /// into ONE event undo group, so an undo here reverts the previous
    /// node's typed text too (data loss, reported from real use). A
    /// delete command touches exactly one subtree: every other node
    /// keeps its text verbatim, and ⌘Z afterwards restores the blank
    /// box like any ordinary delete step.
    private func dropBlankNewNode(_ id: String, freshInsertedParent: Bool) -> Bool {
        guard let store, let node = store.model.nodes[id], Self.isBlankNode(node) else {
            return false
        }
        store.closeEditSession()
        // A fresh inserted parent (⌥⇥) is just as blank, but it owns the
        // anchor as its child so it is no leaf: delete it promoting the
        // anchor back into its slot. The record is only handed to the
        // inserted parent's FIRST commit, so an old empty-titled node
        // with children is never touched.
        if freshInsertedParent, !node.children.isEmpty {
            let promoted = Set(node.children)
            perform(.deleteNodePromotingChildren(id: id)) { _ in promoted }
            return true
        }
        guard Self.isBlankLeaf(node), node.parent != nil || store.model.roots.count > 1 else {
            return false
        }
        let replacement = MapStore.selectionAfterDelete(
            model: store.model, deletedIDs: [id], selection: [id])
        perform(.deleteSubtrees(ids: [id])) { _ in replacement }
        return true
    }

    /// No text or content of any kind (children included by
    /// `isBlankLeaf`, excluded for a fresh inserted parent, which owns
    /// the anchor it was created over).
    static func isBlankNode(_ node: Node) -> Bool {
        node.title.text.isEmpty && (node.note ?? "").isEmpty
            && node.task == nil && (node.tags ?? []).isEmpty && (node.markers ?? []).isEmpty
            && node.image == nil && (node.attachments ?? []).isEmpty && node.link == nil
            && node.source == nil && node.math != true
    }

    /// A blank node with no children — every create path except
    /// ⌥⇥'s inserted parent.
    static func isBlankLeaf(_ node: Node) -> Bool {
        Self.isBlankNode(node) && node.children.isEmpty
    }

    /// The create half of commit-and-create (F-EDT-1): one add command
    /// relative to the just-committed node, then edit the fresh node
    /// (returned). A new sibling or inserted parent inherits the
    /// anchor's pinned side (F-LAY-1): the box lands on the same side
    /// of the map as the node it was created from/next to, instead of
    /// wherever the balanced layout's unpinned alternation would put
    /// it. A new child keeps no pin — only a root's children carry
    /// one, and the Node Well pins those by the clicked side itself.
    /// `shape` is the ADR-0037 creation default (nil = the theme's
    /// level style decides): side and shape compose, so a new node can
    /// inherit BOTH its anchor's side and its shape.
    @discardableResult
    private func createAfterCommit(
        anchor: String, inheritingSide: Bool, shape: NodeShape?, _ make: (String, Node) -> MapCommand
    ) -> String {
        var node = Node(id: UUID().uuidString)
        if inheritingSide {
            node.side = store?.model.nodes[anchor]?.side
        }
        if let shape {
            node.style = NodeStylePatch(shape: shape)
        }
        perform(make(anchor, node)) { _ in [node.id] }
        canvas.beginEditing(nodeID: node.id)
        return node.id
    }

    /// F-CAN-5: double-click on empty canvas creates a floating root
    /// centered at that point. Roots carry no absolute position, so the
    /// click point is stored as the root's manual `offset` from its auto
    /// slot (SPEC §8.2); `SceneGeometry` applies offsets after auto
    /// layout (also the F-LAY-11 groundwork). One undoable grouped
    /// command, then edit mode.
    func createFloatingNode(at modelPoint: CGPoint) {
        guard let store else { return }
        let node = Node(id: UUID().uuidString)
        // Probe the post-add layout for the new root's auto slot.
        var probe = store.model
        try? MapCommand.addRoot(index: nil, node: node).apply(to: &probe)
        let probeScene = SceneGeometry.build(
            model: probe, variant: currentVariant(), measurer: SceneRenderer.sharedMeasurer,
            theme: ThemeCatalog.shared.theme(for: probe))
        let autoFrame = probeScene.nodes[node.id]?.frame ?? .zero
        let offset = ModelOffset(
            x: modelPoint.x - autoFrame.midX,
            y: modelPoint.y - autoFrame.midY)
        let command = MapCommand.group(
            name: "Add Node",
            commands: [
                .addRoot(index: nil, node: node),
                .setOffset(id: node.id, offset: offset),
            ])
        do {
            try store.perform(command)
        } catch {
            return
        }
        canvas.setSelection([node.id])
        canvas.beginEditing(nodeID: node.id)
    }

    // MARK: create (F-EDT-1)

    /// ⏎/⌘⏎/F2 on a single selected node edits it instead (F-EDT-2);
    /// while editing, the create keys commit and create (F-EDT-1).
    @objc func editTitleAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.nodeTextEditor.selectAllText()
            return
        }
        guard canvas.selection.count == 1, let id = canvas.selection.first else { return }
        canvas.beginEditing(nodeID: id)
    }

    @objc func addChildAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .child)
            return
        }
        // F-AI-2: ⇥ with ghosts presented accepts ALL suggestions —
        // one grouped command, one undo step, author .ai.
        if ai.presentingGhosts {
            ai.acceptAll()
            return
        }
        addCommand(shapeFor: childCreationShape) { .addChild(parent: $0, index: nil, node: $1) }
    }

    @objc func addSiblingBelowAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .siblingBelow)
            return
        }
        if canvas.selection.count == 1, let id = canvas.selection.first {
            // F-EDT-2: ⏎ on a selected node enters edit mode.
            canvas.beginEditing(nodeID: id)
            return
        }
        addCommand(inheritingSide: true, shapeFor: siblingCreationShape) {
            .addSibling(anchor: $0, before: false, node: $1)
        }
    }

    /// Always creates a sibling below the selection, without ⏎'s
    /// enter-edit rule — for callers with no keyboard context, such as
    /// VoiceOver's Add Sibling action and the toolbar button.
    @objc func addSiblingBelow(_ sender: Any?) {
        addCommand(inheritingSide: true, shapeFor: siblingCreationShape) {
            .addSibling(anchor: $0, before: false, node: $1)
        }
    }

    @objc func addSiblingAboveAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .siblingAbove)
            return
        }
        addCommand(inheritingSide: true, shapeFor: siblingCreationShape) {
            .addSibling(anchor: $0, before: true, node: $1)
        }
    }

    @objc func insertParentAction(_ sender: Any?) {
        if canvas.isEditing {
            canvas.commitEditing(next: .insertParent)
            return
        }
        freshInsertedParentID = addCommand(inheritingSide: true) {
            .insertParent(anchor: $0, node: $1)
        }
    }

    @objc func addRootAction(_ sender: Any?) {
        if canvas.isEditing {
            // ⇧⏎ inside the text is a line break, not a new root (F-EDT-1).
            canvas.nodeTextEditor.insertLineBreak()
            return
        }
        let node = Node(id: UUID().uuidString)
        perform(.addRoot(index: nil, node: node)) { _ in [node.id] }
        canvas.beginEditing(nodeID: node.id)
    }
}
