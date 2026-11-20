import AppKit
import CanvasKit
import MapCore

extension DocumentWindowController {
    // MARK: fold (F-LAY-14)

    @objc func toggleFoldAction(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        var commands: [MapCommand] = []
        for id in selectedIDs {
            // A leaf has nothing to fold.
            guard let node = store.model.nodes[id], !node.children.isEmpty else { continue }
            commands.append(.setFolded(id: id, folded: !node.folded))
        }
        if let command = grouped("Fold Node", commands) {
            performKeepingSelection(command)
        }
    }

    /// ⌥⌘.: the selection folds/unfolds together with its siblings — one
    /// grouped command, one undo step.
    @objc func foldWithSiblingsAction(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        if let command = Folding.toggleWithSiblingsCommand(selection: selectedIDs, in: store.model) {
            performKeepingSelection(command)
        }
    }

    /// ⌃⌥.: unfolds each selected node one level; never folds.
    @objc func unfoldOneLevelAction(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        if let command = Folding.unfoldOneLevelCommand(selection: selectedIDs, in: store.model) {
            performKeepingSelection(command)
        }
    }

    /// ⌃1–⌃5 / ⌃0 (Show Levels, §6.1): one grouped command that folds
    /// everything below the menu item's level; 0 shows all. No-op states
    /// emit no command, so no phantom undo step registers.
    @objc func showLevelsAction(_ sender: Any?) {
        guard !canvas.isEditing, let store else { return }
        let levels = (sender as? NSMenuItem)?.tag ?? 0
        if let command = Folding.showLevelsCommand(levels: levels, in: store.model) {
            performKeepingSelection(command)
        }
    }
}
