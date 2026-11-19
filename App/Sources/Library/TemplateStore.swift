import AppKit
import MapCore
import MapLibrary

/// Errors from the template store.
enum TemplateStoreError: Error, Equatable {
    /// The document controller could not create an untitled document.
    case documentCreationFailed
}

/// User-saved templates (F-LIB-5): `.arbor` packages under
/// Application Support/Arbor/Templates. Built-ins live in code
/// (`TemplateCatalog`); this store covers "Save as Template…" — it
/// never edits the source document and "New from Template" never
/// edits the template.
@MainActor
final class TemplateStore {
    /// Injectable so hosted tests run against a temp directory.
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appending(path: "Arbor/Templates", directoryHint: .isDirectory)
        }
    }

    /// All templates: the twelve built-ins, then user-saved ones.
    func allTemplates() -> [TemplateCatalog.Template] {
        TemplateCatalog.builtins + TemplateCatalog.userTemplates(in: directory)
    }

    /// "Save as Template…": writes a copy of `model` (fresh ids) as a
    /// new `.arbor` package. Returns the written URL.
    @discardableResult
    func saveAsTemplate(model: MapModel, name: String) throws -> URL {
        let safeName = Self.sanitizedName(name, fallback: model.title ?? "Template")
        let materialized = TemplateCatalog.materialize(model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = directory.appending(path: "\(safeName).arbor", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: target.path) {
            target = directory.appending(
                path: "\(safeName) \(Int(Date().timeIntervalSince1970)).arbor",
                directoryHint: .isDirectory)
        }
        try ArborPackage.write(
            materialized,
            meta: PackageMeta(modified: Date(), docID: materialized.docID),
            to: target)
        return target
    }

    /// "New from Template": an untitled `MapDocument` holding the
    /// template's nodes with fresh ids — the template file itself is
    /// never opened for editing.
    @discardableResult
    func newDocument(from template: TemplateCatalog.Template) throws -> MapDocument {
        let document =
            try NSDocumentController.shared.makeUntitledDocument(
                ofType: AppIdentity.documentUTI) as? MapDocument
        guard let document else {
            throw TemplateStoreError.documentCreationFailed
        }
        document.store.replaceModel(TemplateCatalog.materialize(template.model))
        document.updateChangeCount(.changeDone)
        document.makeWindowControllers()
        document.showWindows()
        return document
    }

    /// Filename-safe template name (mirrors F-EDT-14's rules closely
    /// enough for a saved-file name).
    static func sanitizedName(_ raw: String, fallback: String) -> String {
        var name = ""
        for scalar in raw.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            if "/:\\".unicodeScalars.contains(scalar) {
                name.unicodeScalars.append("-")
            } else {
                name.unicodeScalars.append(scalar)
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : String(name.prefix(80))
    }
}
