import AppKit
import CanvasKit
import MapCore

/// The ⏎/⌫/⇥/⎋/⌘↑/⌘↓-owning outline view (F-OUT-3). Claims the
/// structural keys via `performKeyEquivalent` so the menu's canvas
/// equivalents (⇥ "Add Child", ⏎ "Add Sibling Below", ⌫ "Delete", ⎋
/// "Deselect"…) never fire while a row is selected; the in-cell editor
/// does the same while a session is open (the same pattern as
/// CanvasKit's `EditingTextView`).
@MainActor
final class OutlineView: NSOutlineView {
    weak var host: OutlineViewController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if host?.performStructuralKey(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if host?.performArrowNavigation(with: event) == true { return }
        if host?.performStructuralKey(with: event) == true { return }
        super.keyDown(with: event)
    }
}

/// The outline pane (F-OUT-2/6): an `NSOutlineView` — SPEC §11.6's
/// fully accessible alternative — bound to the document's `MapStore`.
/// It is another VIEW on the same model: every mutation goes through
/// the store as one `MapCommand` (built by the pure `OutlineCommands`
/// in CanvasKit, headless-tested there); this controller never
/// mutates the model directly.
///
/// Disclosure is `node.folded` (one source of truth, F-LAY-14):
/// expanding a row performs `setFolded(id, false)` and collapsing
/// performs `setFolded(id, true)`; a reload mirrors the model's fold
/// state back onto the triangles. Selection is synced both ways with
/// the canvas through the window controller.
@MainActor
final class OutlineViewController: NSViewController {
    let outlineView = OutlineView()
    let dataSource = OutlineDataSource()

    /// The host supplies the live document (the store's owner).
    var documentProvider: (() -> MapDocument?)?
    /// The host supplies the live scene, so first-level row order
    /// follows the map's clockwise visual order (F-OUT-2).
    var sceneProvider: (() -> CanvasScene?)?
    /// Row selection changed by outline interaction (not programmatic
    /// sync); the window controller mirrors it onto the canvas.
    var onSelectionChange: ((Set<String>) -> Void)?

    /// The open in-cell editing session's row, if any (F-OUT-3).
    /// Internal setter: the session logic lives in
    /// OutlineTextEditor.swift's extension.
    var editingRowID: String?
    /// The session's live draft, preserved across reloads.
    var editingDraft: NodeTitle?
    /// The session's text view (re-embedded on every reload).
    var editingTextView: OutlineTextView?

    /// True while a reload mirrors model state onto the view, so the
    /// view's own change notifications never emit commands (loops).
    private var isSyncingViewToModel = false

    /// First-level sides from the live scene; see `sideOf(_:)`.
    private var sceneSides: [String: SidePin] = [:]
    /// Cached row depths (for the indent guides), rebuilt per reload.
    private var rowDepths: [String: Int] = [:]

    var store: MapStore? { documentProvider?()?.store }
    var model: MapModel? { store?.model }
    var isEditing: Bool { editingRowID != nil }

    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let rowHeight: CGFloat = 24
    /// The per-level indent the row views' guides are drawn at.
    static let indentPerLevel: CGFloat = 16

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let scroll = NSScrollView()
        outlineView.host = self
        dataSource.controller = self
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline.title"))
        column.width = 360
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.rowHeight = Self.rowHeight
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.indentationPerLevel = Self.indentPerLevel
        outlineView.selectionHighlightStyle = .regular
        outlineView.registerForDraggedTypes([OutlineDataSource.rowType])
        outlineView.draggingDestinationFeedbackStyle = .regular

        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        view = scroll
    }

    // MARK: sides (F-OUT-2: the map's actual visual order)

    /// The side of a first-level child as the MAP shows it: the live
    /// scene's branch direction wins; nodes without a branch (no scene
    /// yet, or a folded-away row) fall back to the pinned `side`, then
    /// to the right. Deeper levels are never permuted.
    func sideOf(_ id: String) -> SidePin? {
        if let sceneSide = sceneSides[id] { return sceneSide }
        return model?.nodes[id]?.side ?? .right
    }

    private func refreshSceneSides() {
        var sides: [String: SidePin] = [:]
        for branch in sceneProvider?()?.branches ?? [] {
            sides[branch.childID] = branch.direction == .left ? .left : .right
        }
        sceneSides = sides
    }

    // MARK: reload (the store changed, or the pane is about to show)

    /// Rebuilds rows from the store's model, mirroring fold state,
    /// repairing the selection and re-embedding an open editing
    /// session's editor.
    func reloadPreservingSelection() {
        loadViewIfNeeded()
        guard let model else { return }
        refreshSceneSides()
        rowDepths = {
            var depths: [String: Int] = [:]
            for row in OutlineModel.rows(in: model, sideOf: sideOf) {
                depths[row.id] = row.depth
            }
            return depths
        }()
        let selected = selectedRowIDs()
        let editingID = editingRowID
        let draft = editingDraft
        let caret = editingTextView?.selectedRange()

        isSyncingViewToModel = true
        outlineView.reloadData()
        syncExpansion(with: model)
        isSyncingViewToModel = false

        selectRows(ids: selected.filter { model.nodes[$0] != nil })
        // An open session survives external changes (undo while
        // editing, canvas edits) when its row does; otherwise the draft
        // is dropped — committing into a deleted row is a no-op.
        if let editingID, model.nodes[editingID] != nil {
            embedEditor(rowID: editingID, title: draft ?? model.nodes[editingID]!.title, caret: caret)
        } else {
            teardownEditor()
        }
    }

    /// Expands/collapses every item to mirror `node.folded`.
    private func syncExpansion(with model: MapModel) {
        func visit(_ id: String) {
            guard let node = model.nodes[id], !node.children.isEmpty else { return }
            let expanded = !node.folded
            if expanded != outlineView.isItemExpanded(id) {
                if expanded {
                    outlineView.expandItem(id)
                } else {
                    outlineView.collapseItem(id)
                }
            }
            guard expanded else { return }
            for child in OutlineModel.displayedChildren(of: id, in: model, sideOf: sideOf) {
                visit(child)
            }
        }
        for root in model.roots { visit(root) }
    }

    /// Depth of `id` in the displayed outline (0 = root section), from
    /// the cached projection; the row views' indent guides read it.
    func depth(of id: String) -> Int {
        rowDepths[id] ?? 0
    }

    // MARK: selection (F-OUT-1: synced both ways)

    func selectedRowIDs() -> Set<String> {
        var result: Set<String> = []
        for row in outlineView.selectedRowIndexes {
            if let id = outlineView.item(atRow: row) as? String {
                result.insert(id)
            }
        }
        return result
    }

    func selectRows(ids: Set<String>) {
        var indexes = IndexSet()
        for row in 0..<outlineView.numberOfRows {
            if let id = outlineView.item(atRow: row) as? String, ids.contains(id) {
                indexes.insert(row)
            }
        }
        isSyncingViewToModel = true
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        isSyncingViewToModel = false
        if let row = indexes.first {
            outlineView.scrollRowToVisible(row)
        }
    }

    /// The canvas selection moved; mirror it here (guarded so the
    /// outline's own change notification doesn't bounce back).
    func setSelectionFromCanvas(_ ids: Set<String>) {
        guard !isSyncingViewToModel else { return }
        guard let model else { return }
        selectRows(ids: ids.filter { model.nodes[$0] != nil })
    }

    func outlineSelectionDidChange(to ids: Set<String>) {
        guard !isSyncingViewToModel else { return }
        onSelectionChange?(ids)
    }

    // MARK: command plumbing (every action = one MapCommand = one undo step)

    /// Performs `action` through the store and applies its focus:
    /// selects the focus row, and re-enters editing where the gesture
    /// ends inside a session (merge: caret at the text junction,
    /// split: the fresh row).
    func perform(_ action: OutlineAction?, then followUp: ((OutlineAction) -> Void)? = nil) {
        guard let action, let store else { return }
        do {
            try store.perform(action.command)
        } catch {
            return
        }
        selectRows(ids: [action.focus])
        followUp?(action)
    }

    // MARK: gestures (F-OUT-3)

    /// ⏎: new row below (or split at the caret while editing).
    func newRowBelowSelection() {
        guard let model, let id = primarySelectedRowID() else { return }
        let title = model.nodes[id]?.title ?? NodeTitle(text: "")
        splitRow(id: id, caret: (title.text as NSString).length, draft: title)
    }

    func splitRow(id: String, caret: Int, draft: NodeTitle) {
        guard let model,
            let action = OutlineCommands.splitCommand(id: id, caret: caret, draft: draft, in: model)
        else { return }
        // The split's grouped command already carries the draft as the
        // head's editText; the session ends without a separate commit.
        teardownEditor()
        perform(action) { [weak self] _ in
            self?.beginEditing(rowID: action.focus, caret: 0)
        }
    }

    /// ⌫: merge with the row displayed above.
    func mergeSelection() {
        guard let model, let id = primarySelectedRowID() else { return }
        mergeRow(id: id, draft: model.nodes[id]?.title ?? NodeTitle(text: ""))
    }

    func mergeRow(id: String, draft: NodeTitle) {
        guard let model,
            let action = OutlineCommands.mergeCommand(id: id, draft: draft, in: model, sideOf: sideOf)
        else { return }
        teardownEditor()
        perform(action) { [weak self] split in
            if let junction = split.caret {
                self?.beginEditing(rowID: action.focus, caret: junction)
            }
        }
    }

    /// ⇥: indent under the previous displayed sibling.
    func indentSelection() {
        guard let id = primarySelectedRowID() else { return }
        commitEditingSession()
        perform(OutlineCommands.indentCommand(id: id, in: model ?? MapModel.emptyDocument(), sideOf: sideOf))
    }

    /// ⇧⇥: outdent one level (the model's `promote`).
    func outdentSelection() {
        guard let id = primarySelectedRowID() else { return }
        commitEditingSession()
        perform(OutlineCommands.outdentCommand(id: id, in: model ?? MapModel.emptyDocument()))
    }

    /// ⌘↑/⌘↓: move one displayed slot (F-OUT-3).
    func moveSelection(downward: Bool) {
        guard let id = primarySelectedRowID() else { return }
        commitEditingSession()
        perform(
            OutlineCommands.moveCommand(
                id: id, downward: downward, in: model ?? MapModel.emptyDocument(), sideOf: sideOf))
    }

    /// ⌥⌘←/⌥⌘→: fold/unfold — the SAME `setFolded` the map performs.
    func foldSelection(folded: Bool) {
        guard let id = primarySelectedRowID() else { return }
        commitEditingSession()
        perform(OutlineCommands.foldCommand(id: id, folded: folded, in: model ?? MapModel.emptyDocument()))
    }

    /// ⎋ / F2: toggle text editing vs row selection (F-OUT-3).
    func beginEditingSelection() {
        guard let id = primarySelectedRowID() else { return }
        beginEditing(rowID: id, selectAllText: true)
    }

    func primarySelectedRowID() -> String? {
        guard let row = outlineView.selectedRowIndexes.first else { return nil }
        return outlineView.item(atRow: row) as? String
    }

    // MARK: structural key routing (F-OUT-3) — reached from OutlineView

    /// The keys the menu must not steal while a row is selected.
    func performStructuralKey(with event: NSEvent) -> Bool {
        guard !isEditing,
            let key = event.charactersIgnoringModifiers, key.count == 1
        else { return false }
        let flags = event.modifierFlags
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let hasShift = flags.contains(.shift)
        switch (key, hasCommand, hasOption, hasShift) {
        case ("\r", false, false, false):
            newRowBelowSelection()
            return true
        case ("\t", false, false, false):
            indentSelection()
            return true
        case ("\t", false, false, true):
            outdentSelection()
            return true
        case ("\u{7f}", false, false, _):
            mergeSelection()
            return true
        case ("\u{1b}", false, false, false):
            beginEditingSelection()
            return true
        case ("\u{f700}", true, false, _):
            moveSelection(downward: false)
            return true
        case ("\u{f701}", true, false, _):
            moveSelection(downward: true)
            return true
        case ("\u{f702}", true, true, _):
            foldSelection(folded: true)
            return true
        case ("\u{f703}", true, true, _):
            foldSelection(folded: false)
            return true
        case ("\u{f705}", false, false, _):
            beginEditingSelection()
            return true
        default:
            return false
        }
    }

    /// Plain ←/→ in row-selection mode: ← folds (or climbs to the
    /// parent on a leaf/expanded row), → unfolds (or dives into the
    /// first child). KeyDown-only, like the canvas's arrow moves.
    func performArrowNavigation(with event: NSEvent) -> Bool {
        guard !isEditing,
            let key = event.charactersIgnoringModifiers, key.count == 1
        else { return false }
        let flags = event.modifierFlags
        guard !flags.contains(.command), !flags.contains(.option) else { return false }
        guard let model, let id = primarySelectedRowID(), let node = model.nodes[id] else { return false }
        switch key {
        case "\u{f702}":
            if !node.children.isEmpty, !node.folded, outlineView.isItemExpanded(id) {
                perform(OutlineCommands.foldCommand(id: id, folded: true, in: model))
            } else if let parent = node.parent {
                selectRows(ids: [parent])
            }
            return true
        case "\u{f703}":
            if !node.children.isEmpty {
                if node.folded {
                    perform(OutlineCommands.foldCommand(id: id, folded: false, in: model))
                } else if let first = displayedChildren(of: id, in: model).first {
                    selectRows(ids: [first])
                }
            }
            return true
        default:
            return false
        }
    }

    private func displayedChildren(of id: String, in model: MapModel) -> [String] {
        OutlineModel.displayedChildren(of: id, in: model, sideOf: sideOf)
    }

    // MARK: forwarded view notifications (OutlineDataSource is the
    // single delegate and hands the item-level ones here)

    func outlineViewItemDidChange(expanded: Bool, id: String) {
        guard !isSyncingViewToModel else { return }
        perform(OutlineCommands.foldCommand(id: id, folded: !expanded, in: model ?? MapModel.emptyDocument()))
    }

    func outlineViewSelectionDidChange() {
        guard !isSyncingViewToModel else { return }
        outlineSelectionDidChange(to: selectedRowIDs())
    }
}
