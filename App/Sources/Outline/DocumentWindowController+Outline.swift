import AppKit
import CanvasKit
import MapCore

/// The outline ↔ window integration (F-OUT-1, M4): the view-mode
/// container (⌘1 Map, ⌘2 Outline full width, ⌘3 Side by side) and the
/// two-way selection sync between the outline pane and the canvas.
///
/// The container swaps `window.contentView` between three roots — the
/// canvas alone, the outline scroll view alone, and the split view
/// holding both. The views keep their state across swaps (the same
/// instances), so zoom, scroll and the editing sessions survive every
/// mode change; only the first responder moves to whichever pane is
/// visible.
extension DocumentWindowController {
    /// Wires the outline pane to this document's store and the live
    /// scene. Called once from `init` (the document itself is wired
    /// lazily through `documentProvider`).
    func installOutlineIntegration() {
        outlineController.documentProvider = { [weak self] in
            self?.document as? MapDocument
        }
        outlineController.sceneProvider = { [weak self] in
            self?.canvas.scene
        }
        outlineController.onSelectionChange = { [weak self] ids in
            self?.outlineSelectionDidChange(ids)
        }

        documentSplitView.isVertical = true
        documentSplitView.dividerStyle = .thin
        documentSplitView.delegate = self
    }

    /// F-OUT-1: ⌘1 / ⌘2 / ⌘3. The active mode persists in the
    /// F-CAN-8 view-state sidecar (`CanvasViewState.activeView`).
    func applyViewMode(_ mode: ViewMode) {
        guard let window else { return }
        if mode == .sideBySide, documentSplitView.arrangedSubviews.isEmpty {
            documentSplitView.addArrangedSubview(outlineController.view)
            documentSplitView.addArrangedSubview(canvas)
            outlineController.view.translatesAutoresizingMaskIntoConstraints = false
        }
        if mode != .sideBySide, let outlinePane = documentSplitView.arrangedSubviews.first {
            lastOutlinePaneWidth = outlinePane.frame.width
        }
        activeViewMode = mode
        switch mode {
        case .map:
            setMainContentView(canvas)
        case .outline:
            setMainContentView(outlineController.view)
        case .sideBySide:
            setMainContentView(documentSplitView)
        }
        // The visible pane owns the keyboard (except while an editing
        // session keeps its own first responder).
        if window.isVisible {
            window.makeFirstResponder(mode == .map ? canvas : outlineController.outlineView)
        }
        scheduleViewStateSave()
    }

    @objc func showMapViewAction(_ sender: Any?) {
        applyViewMode(.map)
    }

    @objc func showOutlineViewAction(_ sender: Any?) {
        applyViewMode(.outline)
    }

    @objc func showSideBySideViewAction(_ sender: Any?) {
        applyViewMode(.sideBySide)
    }

    // MARK: selection sync (F-OUT-1: both live, both directions)

    /// The canvas selection moved (interaction or the model's post-
    /// command repair): mirror it onto the outline rows.
    func canvasSelectionDidChange(_ ids: Set<String>) {
        scheduleViewStateSave()
        guard !isSyncingSelection else { return }
        isSyncingSelection = true
        outlineController.setSelectionFromCanvas(ids)
        isSyncingSelection = false
    }

    /// The outline selection moved: mirror it onto the canvas so the
    /// map, the clipboard and every Edit-menu action follow the same
    /// nodes (one selection per document).
    func outlineSelectionDidChange(_ ids: Set<String>) {
        guard !isSyncingSelection, !ids.isEmpty else { return }
        isSyncingSelection = true
        canvas.setSelection(ids)
        isSyncingSelection = false
        scheduleViewStateSave()
    }
}

/// The split view's size constraints for the side-by-side mode.
extension DocumentWindowController: NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedPosition }
        // The outline pane: a comfortable sidebar, never collapsed
        // (⌘2 is the full-width mode) and never wider than a third.
        let width = splitView.bounds.width
        return min(max(proposedPosition, 220), width * 0.45)
    }
}
