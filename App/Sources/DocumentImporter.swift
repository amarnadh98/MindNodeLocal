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
    /// the same registry). A `.mindnode` file is either layout MindNode
    /// has shipped: the legacy **directory package** (MindNode 1-2,
    /// importer wants its `contents.xml`) or the current **stored zip**
    /// (MindNode 2026+, `Contents.data` protobuf — ADR-0035); the
    /// importer reads the whole file and sniffs which. Every other
    /// format reads the raw bytes.
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
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                data = try Data(contentsOf: url.appendingPathComponent("contents.xml"))
            } else {
                data = try Data(contentsOf: url)
            }
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

    /// The alert a failed import shows (SPEC §5.17): the title names
    /// the file; the detail carries the importer's own message — the
    /// underlying reason, never just "Import failed". Built as a pure
    /// function so tests can assert what the user actually reads.
    @MainActor
    static func makeImportErrorAlert(for error: Error) -> NSAlert {
        let alert = NSAlert(error: error)
        if let url = (error as? ImportContextError)?.url {
            alert.messageText = "Import failed — \(url.lastPathComponent)"
        }
        alert.informativeText =
            (error as? ImportContextError)?.underlying.localizedDescription
            ?? error.localizedDescription
        return alert
    }

    /// Presents the import-failure sheet on `window` (modal when nil).
    @MainActor
    static func presentImportError(_ error: Error, for window: NSWindow?) {
        let alert = makeImportErrorAlert(for: error)
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
