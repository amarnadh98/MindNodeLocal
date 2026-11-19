import AppKit
import CanvasKit
import MapCore
import MapIO
import MapRender
import SceneExport
import SwiftUI

/// File ▸ Export… (⌥⌘E, F-IO's export UI): presents the SwiftUI export
/// sheet against the document's live scene and selection, remembers the
/// last choice in UserDefaults, then writes through an `NSSavePanel`
/// with the chosen format's UTType.
extension DocumentWindowController {
    private var exportVariant: ThemeVariant {
        guard let mapDocument = document as? MapDocument else { return .light }
        switch mapDocument.model.appearance {
        case .dark: return .dark
        case .light: return .light
        case .auto, .none: return canvas.effectiveVariant
        }
    }

    @objc func exportAction(_ sender: Any?) {
        guard let mapDocument = document as? MapDocument, let window else { return }
        let scene =
            canvas.scene
            ?? ExportCoordinator.scene(
                for: mapDocument.model, variant: exportVariant)
        let variant = exportVariant
        let selection = canvas.selection
        let model = mapDocument.model
        let documentTitle = mapDocument.displayName ?? "Untitled"
        let lastChoice = ExportCoordinator.loadLastChoice() ?? ExportChoice()

        let host = NSHostingController(
            rootView: ExportSheetView(
                initialChoice: lastChoice,
                hasSelection: !selection.isEmpty,
                formats: ExportCoordinator.exportableFormats(),
                renderPreview: { updated in
                    ExportPreview.render(
                        choice: updated, model: model, scene: scene, selection: selection,
                        variant: variant, documentTitle: documentTitle)
                },
                onExport: { chosen in
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet)
                    }
                    ExportCoordinator.saveLastChoice(chosen)
                    self.runExportSavePanel(chosen)
                },
                onCancel: {
                    if let sheet = window.attachedSheet {
                        window.endSheet(sheet)
                    }
                }))

        // NSWindow only begins sheets from an NSWindow, so the hosting
        // controller wraps in one; the sheet's own controls dismiss it
        // through `window.attachedSheet`.
        let sheetWindow = NSWindow(contentViewController: host)
        window.beginSheet(sheetWindow) { _ in
            // Export… dismissed the sheet itself before running the save
            // panel; a plain cancel needs nothing further.
        }
    }

    /// The save half of the export: the right UTType and suggested
    /// filename, then one write through the shared export path.
    func runExportSavePanel(_ choice: ExportChoice) {
        guard let mapDocument = document as? MapDocument, let window,
            let format = ExportCoordinator.format(for: choice)
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ExportCoordinator.utType(for: format)]
        panel.nameFieldStringValue = ExportCoordinator.suggestedFileName(
            for: format, documentName: mapDocument.displayName)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try ExportCoordinator.exportData(
                choice: choice,
                model: mapDocument.model,
                scene: canvas.scene
                    ?? ExportCoordinator.scene(
                        for: mapDocument.model, variant: exportVariant),
                selection: canvas.selection,
                variant: exportVariant,
                documentTitle: mapDocument.displayName ?? "Untitled")
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Export failed"
            alert.informativeText = "The document could not be exported as \(format.displayName)."
            alert.beginSheetModal(for: window)
        }
    }
}
