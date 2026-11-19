import AppKit
import CanvasKit
import MapCore

/// The in-cell title editor (F-OUT-3): a real `NSTextView` embedded
/// in the row's cell view — spell check, autocorrect and the emoji
/// picker all work, like CanvasKit's editing overlay. While a session
/// is open it claims the structural keys via
/// `performKeyEquivalent` (⏎ splits at the caret, ⌫ at the very start
/// merges with the row above, ⇥/⇧⇥ indent/outdent, ⌘↑/⌘↓ move,
/// ⌥⌘←/→ fold/unfold, ⎋/⌘⏎ commit) so the menu equivalents can never
/// fire mid-edit — the same belt-and-braces pattern as the canvas's
/// `EditingTextView`. A commit is ONE `editText` command and the
/// session is closed after it (F-DOC-2).
@MainActor
extension OutlineViewController {
    /// Opens the editing session on `rowID`, embedding the editor in
    /// the row's cell. `selectAllText` selects the whole title (the
    /// ⏎-toggle path); a `caret` (merge) places the insertion point
    /// instead; neither (split's fresh row) starts at zero.
    func beginEditing(rowID: String, selectAllText: Bool = false, caret: Int? = nil) {
        guard let model = model, let node = model.nodes[rowID] else { return }
        // An open session on another row commits first (⏎-equivalent).
        if editingRowID != nil, editingRowID != rowID {
            commitEditingSession()
        }
        teardownEditor()
        let row = outlineView.row(forItem: rowID)
        guard row >= 0,
            let cell =
                outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? OutlineRowCellView
        else { return }

        let font = Self.titleFont
        let color = NSColor.labelColor
        let attributed = NodeTitleText.attributed(node.title, baseFont: font, baseColor: color)
        let editor = OutlineTextView(frame: cell.bounds)
        editor.coordinator = self
        editor.font = font
        editor.textColor = color
        editor.drawsBackground = false
        editor.isRichText = true
        editor.allowsUndo = true
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.autoresizingMask = [.width, .height]
        editor.textStorage?.setAttributedString(attributed)
        cell.textField?.isHidden = true
        cell.addSubview(editor, positioned: .above, relativeTo: nil)
        editor.frame = cell.textField?.frame ?? cell.bounds.insetBy(dx: 4, dy: 0)

        let length = (node.title.text as NSString).length
        if selectAllText {
            editor.selectAll(nil)
        } else {
            editor.selectedRange = NSRange(location: min(max(caret ?? 0, 0), length), length: 0)
        }

        editingRowID = rowID
        editingTextView = editor
        editingDraft = node.title
        outlineView.window?.makeFirstResponder(editor)
    }

    /// Commits the live draft as ONE `editText` command and closes the
    /// session (F-DOC-2: one undo step per edit session).
    func commitEditingSession() {
        guard let rowID = editingRowID, let draft = editingDraft, let model else {
            teardownEditor()
            return
        }
        teardownEditor()
        guard let node = model.nodes[rowID], draft != node.title else { return }
        do {
            try store?.perform(.editText(id: rowID, title: draft))
        } catch {
            return
        }
        store?.closeEditSession()
    }

    /// Removes the editor view and session state without committing
    /// (the session's draft is already carried by the gesture's own
    /// grouped command — split/merge).
    func teardownEditor() {
        if let editor = editingTextView {
            (editor.superview as? OutlineRowCellView)?.textField?.isHidden = false
            editor.removeFromSuperview()
        }
        if let rowID = editingRowID {
            let row = outlineView.row(forItem: rowID)
            if row >= 0 {
                let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? OutlineRowCellView
                cell?.textField?.isHidden = false
            }
        }
        editingTextView = nil
        editingRowID = nil
        editingDraft = nil
    }

    /// Re-embeds the editor after a reload (the cell views were
    /// rebuilt) — the session's draft and caret survive.
    func embedEditor(rowID: String, title: NodeTitle, caret: NSRange?) {
        beginEditing(rowID: rowID, caret: caret?.location)
        guard let editor = editingTextView, editingRowID == rowID else { return }
        let attributed = NodeTitleText.attributed(
            title, baseFont: Self.titleFont, baseColor: .labelColor)
        editor.textStorage?.setAttributedString(attributed)
        editingDraft = title
        if let caret {
            editor.selectedRange = caret
        }
    }

    // MARK: editor key routing (reached by OutlineTextView)

    /// The draft as a `NodeTitle`, tracked live — typing never mutates
    /// the model; the commit is one `editText` command.
    func editorTextDidChange() {
        guard let editor = editingTextView else { return }
        editingDraft = NodeTitleText.title(
            from: editor.textStorage ?? NSAttributedString(),
            baseFont: Self.titleFont,
            baseColor: .labelColor)
    }

    /// ⏎ inside the editor: split the row at the caret (F-OUT-3) —
    /// one grouped command, the draft becomes the head.
    func editorSplit() {
        guard let rowID = editingRowID, let draft = editingDraft else { return }
        let caret =
            editingTextView?.selectedRange().location ?? (draft.text as NSString).length
        splitRow(id: rowID, caret: caret, draft: draft)
    }

    /// ⌫ with the caret at the very start and nothing selected: merge
    /// with the row displayed above (F-OUT-3) — one grouped command.
    func editorMergeIfAtStart() -> Bool {
        guard let rowID = editingRowID, let draft = editingDraft,
            let editor = editingTextView
        else { return false }
        let selected = editor.selectedRange()
        guard selected.location == 0, selected.length == 0 else { return false }
        mergeRow(id: rowID, draft: draft)
        return true
    }

    /// ⇥/⇧⇥ while editing: commit, then indent/outdent the row.
    func editorIndent(outdent: Bool) {
        guard let rowID = editingRowID else { return }
        commitEditingSession()
        guard let model else { return }
        perform(
            outdent
                ? OutlineCommands.outdentCommand(id: rowID, in: model)
                : OutlineCommands.indentCommand(id: rowID, in: model, sideOf: sideOf))
    }

    /// ⌘↑/⌘↓ while editing: commit, then move.
    func editorMove(downward: Bool) {
        guard let rowID = editingRowID else { return }
        commitEditingSession()
        guard let model else { return }
        perform(OutlineCommands.moveCommand(id: rowID, downward: downward, in: model, sideOf: sideOf))
    }

    /// ⌥⌘←/→ while editing: commit, then fold/unfold.
    func editorFold(folded: Bool) {
        guard let rowID = editingRowID else { return }
        commitEditingSession()
        guard let model else { return }
        perform(OutlineCommands.foldCommand(id: rowID, folded: folded, in: model))
    }
}

/// The editor's text view. Routes the editing keys through the
/// coordinator and publishes every text change as a draft
/// `NodeTitle`. Resigning focus commits (window switch, view-mode
/// change), except when the coordinator mediates it.
@MainActor
final class OutlineTextView: NSTextView {
    var coordinator: OutlineViewController?

    /// Typing undo is internal to the edit session: it must never land
    /// on the document's undo manager, where it would shadow the
    /// commit's single `editText` step (F-DOC-2 — the same contract as
    /// the canvas overlay's `EditingTextView`). The private manager
    /// (and its stack) dies with the session.
    private let sessionUndoManager = UndoManager()
    override var undoManager: UndoManager? { sessionUndoManager }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let decision = decision(for: event) {
            dispatch(decision)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let decision = decision(for: event) {
            dispatch(decision)
            return
        }
        super.keyDown(with: event)
    }

    private func decision(for event: NSEvent) -> EditorKeyDecision? {
        guard let key = event.characters, key.count == 1 else { return nil }
        let flags = event.modifierFlags
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let hasShift = flags.contains(.shift)
        switch (key, hasCommand, hasOption, hasShift) {
        case ("\r", false, false, false):
            return .split
        case ("\r", true, false, _), ("\u{1b}", false, false, false):
            return .commit
        case ("\t", false, false, false):
            return .indent
        case ("\t", false, false, true):
            return .outdent
        case ("\u{7f}", false, false, _):
            // ⌫ only belongs to the session at the very start; other
            // positions are ordinary text deletions.
            return coordinator?.editorMergeIfAtStart() == true ? .mergeHandled : nil
        case ("\u{f700}", true, false, _):
            return .moveUp
        case ("\u{f701}", true, false, _):
            return .moveDown
        case ("\u{f702}", true, true, _):
            return .fold
        case ("\u{f703}", true, true, _):
            return .unfold
        default:
            return nil
        }
    }

    private func dispatch(_ decision: EditorKeyDecision) {
        switch decision {
        case .split:
            coordinator?.editorSplit()
        case .commit:
            coordinator?.commitEditingSession()
        case .indent:
            coordinator?.editorIndent(outdent: false)
        case .outdent:
            coordinator?.editorIndent(outdent: true)
        case .moveUp:
            coordinator?.editorMove(downward: false)
        case .moveDown:
            coordinator?.editorMove(downward: true)
        case .fold:
            coordinator?.editorFold(folded: true)
        case .unfold:
            coordinator?.editorFold(folded: false)
        case .mergeHandled:
            break
        }
    }

    override func didChangeText() {
        super.didChangeText()
        coordinator?.editorTextDidChange()
    }

    override func resignFirstResponder() -> Bool {
        // Focus lost for a reason the coordinator didn't mediate
        // (window switch, view-mode swap): commit, one undo step.
        if coordinator?.editingRowID != nil {
            coordinator?.commitEditingSession()
        }
        return super.resignFirstResponder()
    }
}

/// The routed editing keys.
private enum EditorKeyDecision {
    case split
    case commit
    case indent
    case outdent
    case moveUp
    case moveDown
    case fold
    case unfold
    case mergeHandled
}
