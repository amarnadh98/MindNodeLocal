import AppKit
import CanvasKit
import MapCore
import os

/// M3 content actions (SPEC §5.4/§5.6/§5.7): notes, links, tasks, tags
/// — the menu/keyboard surface of F-CNT-1/4, F-TSK-1/2/3/5 and
/// F-TAG-1/2. Every mutation is ONE `MapCommand` through the
/// document's `MapStore` (multi-select = one undo step); the canvas
/// closures forward node ids only (SPEC §11.3).
@MainActor
extension DocumentWindowController {
    /// View ▸ Show Tag Pills (persisted per user, like the minimap
    /// preference).
    static let showsTagPillsDefaultsKey = "ShowsTagPills"

    /// True when a highlight mode may be active — Esc's first job.
    var highlightActive: Bool { canvas.highlight != nil }

    /// Wires the canvas's decoration closures (F-TSK-1/2, F-CNT-1/4);
    /// called from `init`.
    func setupContent() {
        canvas.onToggleTaskDone = { [weak self] id in
            self?.toggleTaskDone(id: id)
        }
        canvas.onSetLeafTasksDone = { [weak self] id, done in
            self?.setLeafTasks(id: id, done: done)
        }
        canvas.onOpenNote = { [weak self] id in
            self?.openNotePopover(id: id)
        }
        canvas.onOpenLink = { [weak self] id in
            self?.openLink(id: id)
        }
    }

    // MARK: tasks (F-TSK-1/2/3)

    /// ⇧⌘T: turns every selected node into a task — or, when all of
    /// them already are, back into plain nodes. One command, one undo
    /// step.
    @objc func toggleTaskAction(_ sender: Any?) {
        guard let store = contentStore, !canvas.selection.isEmpty else { return }
        let ids = canvas.selection.sorted()
        let allTasks = ids.allSatisfy { store.model.nodes[$0]?.task != nil }
        performKeepingSelection(.setTask(ids: ids, isTask: !allTasks))
    }

    /// ⌃⌘T (or a checkbox click): completes the selected tasks — or
    /// reopens them when every one is already done.
    @objc func completeTaskAction(_ sender: Any?) {
        guard let store = contentStore else { return }
        let ids = canvas.selection.sorted().filter { store.model.nodes[$0]?.task != nil }
        guard !ids.isEmpty else { return }
        let allDone = ids.allSatisfy { store.model.nodes[$0]?.task?.done == true }
        performKeepingSelection(.setTaskDone(ids: ids, done: !allDone))
    }

    /// A checkbox click (F-TSK-1): flips this task's done state.
    func toggleTaskDone(id: String) {
        guard let store = contentStore, let done = store.model.nodes[id]?.task?.done else { return }
        perform(.setTaskDone(ids: [id], done: !done)) { _ in [id] }
    }

    /// A ring click (F-TSK-2): completes (or, ⌥-clicked, reopens) every
    /// leaf task in the subtree — one grouped step.
    func setLeafTasks(id: String, done: Bool) {
        guard let store = contentStore else { return }
        guard let command = MapCommand.setLeafTasksDone(parent: id, done: done, in: store.model)
        else { return }
        perform(command) { _ in [id] }
    }

    /// Task details sheet (F-TSK-3): due date, priority, repeat rule.
    @objc func taskDetailsAction(_ sender: Any?) {
        guard let store = contentStore, let id = canvas.selection.sorted().first,
            store.model.nodes[id]?.task != nil, let window
        else { return }
        TaskDetailsSheet.present(
            over: window, task: store.model.nodes[id]?.task
        ) { [weak self] due, priority, dueRepeat in
            self?.performTaskDetails(id: id, due: due, priority: priority, repeat: dueRepeat)
        }
    }

    func performTaskDetails(id: String, due: String?, priority: Int?, `repeat`: String?) {
        performKeepingSelection(
            .setTaskDetails(id: id, due: due, priority: priority, repeat: `repeat`))
    }

    // MARK: notes (F-CNT-1)

    /// ⇧⌘K: the note popover anchored to the node. One editing session
    /// commits ONE `setNote` when the popover closes.
    @objc func noteAction(_ sender: Any?) {
        guard let id = canvas.selection.sorted().first else { return }
        openNotePopover(id: id)
    }

    func openNotePopover(id: String) {
        guard let store = contentStore, let node = store.model.nodes[id] else { return }
        notePopoverHolder = NotePopoverHolder(nodeID: id, note: node.note) { [weak self] nodeID, text in
            guard let self else { return }
            let unchanged = self.contentStore?.model.nodes[nodeID]?.note == text
            if !unchanged {
                self.perform(.setNote(id: nodeID, note: text.isEmpty ? nil : text)) { _ in [nodeID] }
            }
        }
        notePopoverHolder?.present(anchor: canvas.viewRect(of: id) ?? canvas.bounds, of: canvas)
    }

    // MARK: links (F-CNT-4)

    /// ⌘K: the link sheet (web / file / `x-arbor://`), applied to every
    /// selected node as one grouped command.
    @objc func linkAction(_ sender: Any?) {
        guard let store = contentStore, let window, !canvas.selection.isEmpty else { return }
        let ids = canvas.selection.sorted()
        let current = ids.compactMap { store.model.nodes[$0]?.link }.first
        LinkSheet.present(over: window, current: current) { [weak self] url in
            guard let self, let store = self.contentStore else { return }
            let commands = ids.map { MapCommand.setLink(id: $0, link: url) }
            if let command = self.groupedCommands("Set Link", commands) {
                self.performKeepingSelection(command)
            }
        }
    }

    /// ⌥⌘K (or a badge click): opens the selected node's link. Web and
    /// file URLs go to NSWorkspace; `x-arbor://` routes here — a
    /// same-document node jump is implemented, another document is
    /// deferred behind `onOpenExternalDocument`.
    @objc func openLinkAction(_ sender: Any?) {
        guard let id = canvas.selection.sorted().first else { return }
        openLink(id: id)
    }

    func openLink(id: String) {
        guard let store = contentStore,
            let raw = store.model.nodes[id]?.link,
            let link = ArborLink.parse(raw)
        else { return }
        switch link {
        case .web(let url), .file(let url):
            NSWorkspace.shared.open(url)
        case .arbor(let docID, let nodeID):
            openArborLink(docID: docID, nodeID: nodeID)
        }
    }

    private func openArborLink(docID: String?, nodeID: String?) {
        guard let store = contentStore else { return }
        // F-REL-5: a link without a doc, or with THIS document's id,
        // is a same-document jump (select + center).
        if docID == nil || docID == store.model.docID {
            guard let nodeID, store.model.nodes[nodeID] != nil else { return }
            canvas.setSelection([nodeID])
            canvas.scrollSelectionIntoView()
            return
        }
        guard let docID else { return }
        onOpenExternalDocument?(docID, nodeID)
        contentLog.info("x-arbor link to another document \(docID, privacy: .public) is deferred (F-REL-5 seam)")
    }

    // MARK: tags (F-TAG-1/2)

    /// ⌥⌘T: the tag popover — type-ahead over the document's tags plus
    /// create-new; clicking a tag assigns/unassigns it on the whole
    /// selection (one command per click).
    @objc func tagsAction(_ sender: Any?) {
        guard let store = contentStore, !canvas.selection.isEmpty, let id = canvas.selection.sorted().first
        else { return }
        TagPopoverHolder.shared.presentAssign(
            model: store.model, anchor: canvas.viewRect(of: id) ?? canvas.bounds, of: canvas
        ) { [weak self] command in
            self?.performKeepingSelection(command)
        }
    }

    /// F-TAG-2: pick tags; matching nodes stay lit and everything else
    /// dims to 25% (view state, no undo).
    @objc func tagHighlightAction(_ sender: Any?) {
        guard let store = contentStore, let id = canvas.selection.sorted().first ?? store.model.roots.first
        else { return }
        TagPopoverHolder.shared.presentHighlight(
            model: store.model, anchor: canvas.viewRect(of: id) ?? canvas.bounds, of: canvas
        ) { [weak self] tagIDs in
            guard let self else { return }
            self.canvas.highlight = tagIDs.isEmpty ? nil : .tags(Set(tagIDs))
        }
    }

    /// F-TSK-5: highlight tasks mode (dims non-task nodes).
    @objc func highlightTasksAction(_ sender: Any?) {
        if canvas.highlight == .tasks {
            canvas.highlight = nil
        } else {
            canvas.highlight = .tasks
        }
    }

    /// View ▸ Show Tag Pills: persisted per user; the scene rebuilds
    /// without pills when off.
    @objc func showTagPillsAction(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let current = defaults.object(forKey: Self.showsTagPillsDefaultsKey) as? Bool ?? true
        defaults.set(!current, forKey: Self.showsTagPillsDefaultsKey)
        updateScene(preserveCamera: true)
    }

    var showsTagPills: Bool {
        UserDefaults.standard.object(forKey: Self.showsTagPillsDefaultsKey) as? Bool ?? true
    }

    // MARK: helpers

    var contentStore: MapStore? {
        (document as? MapDocument)?.store
    }

    /// One grouped command from `commands`, or nil when empty.
    func groupedCommands(_ name: String, _ commands: [MapCommand]) -> MapCommand? {
        switch commands.count {
        case 0:
            nil
        case 1:
            commands[0]
        default:
            .group(name: name, commands: commands)
        }
    }
}

// MARK: the store-performing path (moved from the controller body so
// each file stays under the lint budgets; the M3 content actions are
// this path's main extension consumers)

extension DocumentWindowController {
    /// Performs `command`; on success the canvas selects `replacement`
    /// in the rebuilt scene. A throwing command is a no-op (the store
    /// leaves the model untouched).
    func perform(_ command: MapCommand, selecting replacement: (MapModel) -> Set<String>) {
        guard let store else { return }
        do {
            try store.perform(command)
        } catch {
            return
        }
        canvas.setSelection(replacement(store.model))
    }

    func performKeepingSelection(_ command: MapCommand) {
        perform(command) { [canvas] _ in canvas.selection }
    }
}

private let contentLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "arbor", category: "content")
