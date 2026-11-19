import AppKit
import CanvasKit
import MapCore

/// The F-FOC responder-chain surface (SPEC §6.1 Find/View tables): the
/// menu items route here, validation keeps them honest, and the
/// coordinator gets its model/scene plumbing. Everything lives in this
/// file so the hooks inside `DocumentWindowController` stay one-liners
/// (the shared file only owns the property and four call sites).
@MainActor
extension DocumentWindowController: NSMenuItemValidation {
    // MARK: Find (F-FOC-3)

    /// ⌘F — the find bar; Edit ▸ Find ▸ Find…
    @objc func findAction(_ sender: Any?) {
        focusFind.showFindBar(replace: false)
    }

    /// ⌥⌘F — the find bar with the replace row; Edit ▸ Find ▸ Find and
    /// Replace…
    @objc func findReplaceAction(_ sender: Any?) {
        focusFind.showFindBar(replace: true)
    }

    /// ⌘G — the next match, wrap-around.
    @objc func findNextAction(_ sender: Any?) {
        focusFind.findNext()
    }

    /// ⇧⌘G — the previous match, wrap-around.
    @objc func findPreviousAction(_ sender: Any?) {
        focusFind.findPrevious()
    }

    /// ⌘E — the selected node's title becomes the query.
    @objc func useSelectionForFindAction(_ sender: Any?) {
        focusFind.useSelectionForFind()
    }

    // MARK: Focus & Zen (F-FOC-1/2)

    /// ⇧⌘F — Focus mode.
    @objc func focusModeAction(_ sender: Any?) {
        focusFind.toggleFocusMode()
    }

    /// ⌃⌘F — Zen mode.
    @objc func zenModeAction(_ sender: Any?) {
        focusFind.toggleZenMode()
    }

    // MARK: Quick Open (F-FOC-4)

    /// ⇧⌘O — fuzzy-jump to any node in the document.
    @objc func quickOpenAction(_ sender: Any?) {
        focusFind.openQuickOpen(mode: .nodes)
    }

    /// ⇧⌘P — the command palette over the enabled menu items.
    @objc func commandPaletteAction(_ sender: Any?) {
        focusFind.openQuickOpen(mode: .commands)
    }

    // MARK: menu validation

    /// §14.1 (reachable *and honestly enabled*): the F-FOC items
    /// validate against the coordinator's state; everything else stays
    /// at AppKit's default (enabled). `@objc` so both the menu
    /// machinery and the command palette's enable check can find it.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findAction), #selector(findReplaceAction):
            return document != nil && window != nil
        case #selector(findNextAction), #selector(findPreviousAction):
            return focusFind.isFindActive && !focusFind.matches.isEmpty
        case #selector(useSelectionForFindAction):
            return !canvas.selection.isEmpty && !canvas.isEditing
        case #selector(focusModeAction), #selector(zenModeAction):
            return document != nil && window != nil
        case #selector(quickOpenAction), #selector(commandPaletteAction):
            return document != nil && window != nil
        default:
            return true
        }
    }

    // MARK: coordinator plumbing (called from the shared file's hooks)

    /// The store's current model — the coordinator's search source.
    var focusFindModel: MapModel? {
        (document as? MapDocument)?.store.model
    }

    /// Rebuilds the scene (camera preserved) through the controller's
    /// own path, so the coordinator's temporary-unfold copy and the
    /// dimming/ring sync apply exactly as after a store change.
    func focusFindRebuildScene() {
        updateScene(preserveCamera: true)
    }

    /// Performs `command` through the document's `MapStore` — one undo
    /// step (SPEC §11.3) — then selects `ids` in the rebuilt scene.
    func focusFindPerform(_ command: MapCommand, selecting ids: Set<String>) {
        guard let store = focusFindStore else { return }
        do {
            try store.perform(command)
        } catch {
            return
        }
        canvas.setSelection(ids)
    }

    private var focusFindStore: MapStore? {
        (document as? MapDocument)?.store
    }

    // MARK: the find bar's field editor

    /// The find bar's fields need their plain ⏎/⇥/⎋/arrow presses
    /// claimed before the menu's equivalents ("Add Sibling Below" owns
    /// a bare ⏎), so they type into a dedicated editor. Every other
    /// field in the window gets AppKit's default editor untouched —
    /// including the Outline view's.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> NSTextView? {
        guard let field = client as? FindBarField else { return nil }
        let editor = focusFind.fieldEditor
        editor.editorBar = field.owningBar
        return editor
    }
}
