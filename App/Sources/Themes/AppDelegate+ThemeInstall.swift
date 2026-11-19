import AppKit

/// F-STY-5's "double-click to install": a `.arbortheme` opened from
/// Finder lands in the themes folder through the catalog, with an
/// alert confirming where it went (the app-level action needs no
/// validation conformance). Kept in an extension so the AppDelegate
/// class body stays under `type_body_length`.
extension AppDelegate {
    /// Installs one theme file and says so. A broken file gets its
    /// own alert with the decoder's error.
    @MainActor
    func installTheme(at url: URL) {
        do {
            let theme = try ThemeCatalog.shared.install(from: url)
            let alert = NSAlert()
            alert.messageText = "Theme installed"
            alert.informativeText =
                "“\(theme.name)” is available in Settings ▸ Themes and the theme editor."
            alert.runModal()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "The theme could not be installed"
            alert.informativeText = "“\(url.lastPathComponent)” is not a valid Arbor theme file."
            alert.runModal()
        }
    }
}
