import AppKit
import CanvasKit
import MapCore
import MapLayout
import MapRender

/// The inspector's window-side wiring (SPEC §4.1, F-STY-2…8): the ⌥⌘I
/// toggle, the main-content swap the view modes route through, the
/// F-LAY-14 pill click, the live theme preview, the spacing rhythm
/// (F-LAY-12) and this feature's menu validation — chained into the
/// ONE `validateMenuItem` (DocumentWindowController+Toolbar) through
/// its `default:` helper list, which sits at swiftlint's cyclomatic
/// limit.
@MainActor
extension DocumentWindowController {
    /// ⌥⌘I (View ▸ Toggle Inspector, SPEC §6.1): shows/hides the
    /// trailing pane; the preference persists per user.
    @objc func toggleInspectorAction(_ sender: Any?) {
        inspector.toggleVisibility()
    }

    /// The view-mode swap's landing pad: with the pane installed, the
    /// split's main item changes its view in place (⌘1/⌘2/⌘3 never
    /// rebuild the canvas instance); without it the window's content
    /// view is assigned directly, exactly as before the pane existed.
    func setMainContentView(_ view: NSView) {
        if inspector.isInstalled {
            inspector.setMainView(view)
        } else {
            window?.contentView = view
        }
    }

    /// The first-show hook: a window opened with the persisted
    /// preference installs the pane before the first scene build
    /// settles, and the pane takes its first snapshot either way.
    func inspectorWindowDidShow() {
        inspector.installIfNeeded()
        inspector.refresh()
    }

    /// F-LAY-14: a click on a folded node's count pill — ONE `setFolded`
    /// undo step, selection untouched.
    @objc func unfoldFromPill(_ id: String) {
        performKeepingSelection(.setFolded(id: id, folded: false))
    }

    /// F-STY-4: the hovered theme tile pins the scene's theme WITHOUT
    /// touching the model (view-only; hover never dirties the
    /// document). `nil` = the stored selection.
    func previewThemeOverride(for model: inout MapModel) {
        if let previewThemeID {
            model.theme = ThemeSelection(id: previewThemeID)
        }
    }

    /// F-LAY-12: the user-level spacing rhythm every document lays out
    /// at (the inspector's Layout pane is its editor).
    var effectiveLayoutSpacing: LayoutSpacing {
        DocumentPreferences.layoutSpacing
    }

    /// The scene cache matches the current variant AND spacing (a
    /// spacing change is a full rebuild — the cache is spacing-tagged).
    func sceneCacheFor(variant: ThemeVariant, spacing: LayoutSpacing) -> SceneBuildCache? {
        guard let cache = sceneCache, cache.variant == variant, cache.spacing == spacing else {
            return nil
        }
        return cache
    }

    /// This feature's menu validation (chained from `validateMenuItem`'s
    /// `default:`): the Inspector item's checkmark, and the
    /// selection-sensitive Format ▸ Style items.
    func validateInspectorMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(toggleInspectorAction(_:)):
            menuItem.state = inspector.isVisible ? .on : .off
            return true
        case #selector(applyShapeAction(_:)):
            return !canvas.isEditing && !canvas.selection.isEmpty
        case #selector(resetStyleAction(_:)):
            return !canvas.isEditing
                && canvas.selection.contains { id in
                    store?.model.nodes[id]?.style != nil
                }
        case #selector(recolorBranchesAction(_:)):
            return !canvas.isEditing && store?.model.roots.isEmpty == false
        default:
            return nil
        }
    }

    // MARK: Format ▸ Style menu actions (one MapStore command each)

    /// Format ▸ Style ▸ Shape (F-STY-1): applies the menu item's tag as
    /// a `NodeShape` raw value to the whole selection — one undo step.
    @objc func applyShapeAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
            let shape = NodeShape.allCases[safe: menuItem.tag]
        else { return }
        performStyleCommandOnSelection { .setStyle(ids: $0, patch: NodeStylePatch(shape: shape)) }
    }

    /// Format ▸ Style ▸ Reset to Theme (F-STY-3): clears every stored
    /// override on the selection — one undo step.
    @objc func resetStyleAction(_ sender: Any?) {
        performStyleCommandOnSelection { .resetStyle(ids: $0, keys: nil) }
    }

    /// Format ▸ Style ▸ Recolor Branches (F-STY-8): rotates every
    /// root's persistent palette colors — one grouped undo step.
    @objc func recolorBranchesAction(_ sender: Any?) {
        guard let store else { return }
        let commands = store.model.roots.map { MapCommand.recolorBranches(rootID: $0, in: store.model) }
        let grouped: MapCommand? =
            switch commands.count {
            case 0: nil
            case 1: commands[0]
            default: .group(name: "Recolor Branches", commands: commands)
            }
        if let grouped {
            performKeepingSelection(grouped)
        }
    }

    /// The inspector's and the menu's shared selection-style path.
    func performStyleCommandOnSelection(_ make: ([String]) -> MapCommand) {
        guard !canvas.isEditing, !canvas.selection.isEmpty else { return }
        let ids = canvas.selection.sorted()
        perform(make(ids)) { _ in canvas.selection }
    }
}

extension Array {
    /// A bounds-checked subscript (the menu's tag is trusted input).
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
