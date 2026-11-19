import AppKit
import Foundation
import MapCore
import MapIO

/// F-IO import wiring: turning a foreign file (`.opml`, `.md`, `.txt`,
/// `.mm`, `.xmind`, `.mindnode`) into a model, and landing it as a NEW
/// untitled Arbor document — the source file is never touched, let
/// alone overwritten.
enum DocumentImporter {
    /// The importable formats the open/Import panels offer.
    static var importableFormats: [DocumentFormat] {
        DocumentFormats.all.filter { $0.canImport && $0.id != DocumentFormats.arbor.id }
    }

    /// Sniffs the format for `url` by extension (the open panel keys off
    /// the same registry). `.mindnode` is a package: the importer wants
    /// its `contents.xml`; every other format reads the raw bytes.
    static func importModel(at url: URL) throws -> MapModel {
        let fileExtension = url.pathExtension.lowercased()
        guard
            let format = DocumentFormats.format(forExtension: fileExtension),
            format.canImport, format.id != DocumentFormats.arbor.id
        else {
            throw CocoaError(
                .fileReadUnsupportedScheme,
                userInfo: [NSLocalizedDescriptionKey: "Arbor cannot import .\(fileExtension) files."])
        }
        let data: Data
        if format.id == DocumentFormats.mindnode.id {
            data = try Data(contentsOf: url.appendingPathComponent("contents.xml"))
        } else {
            data = try Data(contentsOf: url)
        }
        return try DocumentIO.importDocument(data, format: format)
    }

    /// Opens `url` as a NEW untitled document: import the model, create
    /// the document through `NSDocumentController`, show it. The source
    /// file is only ever read; failures rethrow wrapped so the error
    /// sheet can name the file.
    @MainActor
    static func openForeignDocument(at url: URL) throws -> MapDocument {
        let model: MapModel
        do {
            model = try importModel(at: url)
        } catch {
            throw ImportContextError(url: url, underlying: error)
        }
        let made = try NSDocumentController.shared.makeUntitledDocument(ofType: AppIdentity.documentUTI)
        guard let document = made as? MapDocument else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "the app's document class is not registered for \(AppIdentity.documentUTI)"
                ])
        }
        document.adoptImportedModel(model)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        for controller in document.windowControllers {
            controller.showWindow(nil)
        }
        return document
    }

    /// An error alert for a failed import, carrying the importer's own
    /// message (SPEC §5.17 — including the MindNode OPML fallback hint,
    /// which `DocumentIOError.errorDescription` renders).
    @MainActor
    static func presentImportError(_ error: Error, for window: NSWindow?) {
        let alert = NSAlert(error: error)
        alert.messageText = "Import failed"
        if let url = (error as? ImportContextError)?.url {
            alert.informativeText = url.lastPathComponent
        }
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Wraps a failed import's URL so the error sheet can name the file
/// while the message stays the importer's own.
struct ImportContextError: LocalizedError {
    let url: URL
    let underlying: Error

    var errorDescription: String? { underlying.localizedDescription }
}
