import AppKit
import CanvasKit
import MapCore

extension DocumentWindowController {
    // MARK: AI (F-AI-1…F-AI-5) — actions the AI menu targets

    /// ⌘. — expand the selected node with AI; with ghosts presented,
    /// regenerates them (F-AI-2).
    @objc func aiExpandAction(_ sender: Any?) {
        guard !canvas.isEditing else { return }
        ai.expandAction()
    }

    /// F-AI-3: the "Generate Map From…" sheet.
    @objc func generateMapAction(_ sender: Any?) {
        guard ai.menuAvailable else { return }
        GenerateMapSheetPresenter.present(on: ai)
    }

    /// F-AI-4 (P2): summarize the selected branch into its note.
    @objc func aiSummarizeBranchAction(_ sender: Any?) {
        guard !canvas.isEditing, !canvas.selection.isEmpty else { return }
        Task { await ai.summarizeBranchAction() }
    }

    /// F-AI-4 (P2): rewrite the selected subtree's titles concisely.
    @objc func aiRewriteTitlesAction(_ sender: Any?) {
        guard !canvas.isEditing, !canvas.selection.isEmpty else { return }
        Task { await ai.rewriteTitlesAction() }
    }

    /// F-AI-4 (P2): suggest a title for the document.
    @objc func aiSuggestTitleAction(_ sender: Any?) {
        guard !canvas.isEditing else { return }
        Task { await ai.suggestTitleAction() }
    }

    /// SPEC §12: the per-document "Never send to cloud AI" flag — one
    /// undoable `setAIPolicy` command, mirrored by the menu's state.
    @objc func aiToggleNeverSendToCloudAction(_ sender: Any?) {
        ai.toggleNeverSendToCloud()
        documentToolbar?.validateVisibleItems()
    }
}

extension DocumentWindowController {
}
