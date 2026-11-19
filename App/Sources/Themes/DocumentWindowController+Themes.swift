import AppKit
import MapCore

/// F-STY-5/6 window-side wiring: the Format ▸ "Edit Theme…" sheet and
/// the View ▸ Appearance radio group (Auto/Light/Dark). The appearance
/// override is ONE undoable `setAppearance` command through the store
/// — one undo step — and the theme editor's Apply performs one
/// `setTheme` (the editor controller owns that sheet's lifecycle).
/// Menu validation lives here and chains into the controller's single
/// `validateMenuItem` (DocumentWindowController+Toolbar).
@MainActor
extension DocumentWindowController {
    /// Format ▸ "Edit Theme…" (F-STY-5): opens the editor sheet seeded
    /// from the document's current theme — also the honest form of
    /// "New Theme from Current Map" until per-node overrides exist
    /// (ADR-0024).
    @objc func editThemeAction(_ sender: Any?) {
        guard let mapDocument = document as? MapDocument, let window else { return }
        ThemeEditorController(document: mapDocument).present(asSheetOn: window)
    }

    /// View ▸ Appearance (F-STY-6): Auto follows the system; Light and
    /// Dark pin the variant the document renders and exports in. One
    /// undoable command — the scene rebuild follows through the normal
    /// store-change path.
    @objc func setAppearanceAction(_ sender: Any?) {
        guard let mapDocument = document as? MapDocument else { return }
        guard let item = sender as? NSMenuItem else { return }
        let mode: AppearanceMode
        switch item.tag {
        case 1: mode = .light
        case 2: mode = .dark
        default: mode = .auto
        }
        guard mapDocument.model.appearance ?? .auto != mode else { return }
        try? mapDocument.store.perform(.setAppearance(mode: mode))
    }
}

// MARK: validation (chained from the single validateMenuItem)

@MainActor
extension DocumentWindowController {
    /// The Edit Theme… item needs a document; the Appearance radios
    /// always enable (they show the current state) but still refuse on
    /// a read-only document. Returns nil for items that are not
    /// F-STY's.
    func validateThemesMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        guard document is MapDocument else { return nil }
        switch menuItem.action {
        case #selector(editThemeAction(_:)):
            return true
        case #selector(setAppearanceAction(_:)):
            guard let mapDocument = document as? MapDocument else { return false }
            let current = mapDocument.model.appearance ?? .auto
            menuItem.state =
                menuItem.tag == Self.appearanceTag(of: current) ? .on : .off
            return true
        default:
            return nil
        }
    }

    private static func appearanceTag(of mode: AppearanceMode) -> Int {
        switch mode {
        case .auto: 0
        case .light: 1
        case .dark: 2
        }
    }
}
