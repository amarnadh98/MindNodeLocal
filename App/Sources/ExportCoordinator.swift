import AppKit
import CanvasKit
import Foundation
import MapCore
import MapIO
import MapRender
import SceneExport
import UniformTypeIdentifiers

/// Everything the File ▸ Export… sheet (⌥⌘E, SPEC §5.17) chooses: the
/// format plus each format's options, persisted to UserDefaults so the
/// sheet remembers the last choice.
struct ExportChoice: Codable, Sendable, Equatable {
    /// A `DocumentFormats` id ("opml", "pdf", "svg", …).
    var formatID: String = "pdf"

    // PDF options.
    var pdfContent: String = "wholeMap"  // wholeMap | selection | outline
    var pdfBackground = true
    var pdfBookmarks = true

    // Raster options (PNG/JPEG/HEIC).
    var imageScale = 2
    var imageTransparent = false

    // SVG options.
    var svgTextAsOutlines = false

    // Text-format options.
    var markdownHeadingDepth = 2
    var textIndent = "tab"  // tab | two | four

    static let defaultFormatID = "pdf"
}

/// Builds export bytes for an `ExportChoice` — the one production path
/// behind both the sheet's preview and its save, and the seam the
/// hosted tests drive (pure: no panels, no AppKit).
enum ExportCoordinator {
    /// The formats the sheet offers: every exportable registry entry
    /// except the native package (File ▸ Save handles that).
    static func exportableFormats() -> [DocumentFormat] {
        DocumentFormats.all.filter { $0.canExport && $0.id != DocumentFormats.arbor.id }
    }

    static func format(for choice: ExportChoice) -> DocumentFormat? {
        let registry = DocumentFormats.format(id: choice.formatID)
        guard let registry, registry.canExport, registry.id != DocumentFormats.arbor.id else {
            return nil
        }
        return registry
    }

    /// The scene the graphic formats render from, built from scratch
    /// when the caller has none (tests, Quick Look). `theme` overrides
    /// the model's theme id — the MainActor callers resolve user themes
    /// through the catalog first (F-STY-5).
    static func scene(
        for model: MapModel, variant: ThemeVariant, measurer: TextMeasurer = SceneRenderer.sharedMeasurer,
        theme: MapRender.Theme? = nil
    ) -> CanvasScene {
        SceneGeometry.build(model: model, variant: variant, measurer: measurer, theme: theme)
    }

    /// The exported bytes for `choice`, plus the format metadata the
    /// save panel needs. `selection` seeds the PDF "selection subtree"
    /// content option. `theme` resolves user themes when the caller
    /// has no live scene.
    static func exportData(
        choice: ExportChoice,
        model: MapModel,
        scene: CanvasScene?,
        selection: Set<String>,
        variant: ThemeVariant,
        documentTitle: String,
        theme: MapRender.Theme? = nil
    ) throws -> Data {
        guard let format = format(for: choice) else {
            throw DocumentIOError.notImplemented("unknown export format \(choice.formatID)")
        }

        switch format.id {
        case DocumentFormats.opml.id:
            return Data(OPMLDocumentIO.exportDocument(model).utf8)
        case DocumentFormats.markdown.id:
            let options = MarkdownExportOptions(headingDepth: choice.markdownHeadingDepth)
            return Data(MarkdownDocumentIO.exportDocument(model, options: options).utf8)
        case DocumentFormats.plainText.id:
            let indent: PlainTextExportOptions.Indent
            switch choice.textIndent {
            case "two": indent = .spaces(2)
            case "four": indent = .spaces(4)
            default: indent = .tab
            }
            return Data(PlainTextOutlineIO.exportDocument(model, options: PlainTextExportOptions(indent: indent)).utf8)
        case DocumentFormats.freemind.id:
            return Data(FreeMindIO.exportDocument(model).utf8)
        case DocumentFormats.pdf.id:
            return try PDFExporter.export(
                scene: scene ?? Self.scene(for: model, variant: variant, theme: theme),
                model: model,
                options: pdfOptions(choice, selection: selection, title: documentTitle))
        case DocumentFormats.png.id,
            DocumentFormats.jpeg.id,
            DocumentFormats.heic.id:
            var options = ImageExportOptions(
                format: rasterFormat(format), pixelScale: choice.imageScale,
                transparentBackground: choice.imageTransparent)
            options.margin = 24
            return try ImageExporter.export(
                scene: scene ?? Self.scene(for: model, variant: variant, theme: theme),
                model: model, options: options
            ).data
        case DocumentFormats.svg.id:
            var options = SVGExportOptions()
            options.textAsOutlines = choice.svgTextAsOutlines
            options.margin = 24
            return Data(
                SVGExporter.export(
                    scene: scene ?? Self.scene(for: model, variant: variant, theme: theme),
                    model: model, options: options
                ).utf8)
        default:
            throw DocumentIOError.notImplemented("export of \(format.displayName) is a later slice")
        }
    }

    static func pdfOptions(
        _ choice: ExportChoice, selection: Set<String>, title: String
    ) -> PDFExportOptions {
        let content: PDFExportOptions.Content
        switch choice.pdfContent {
        case "selection" where !selection.isEmpty:
            content = .map(.subtree(selection))
        case "outline":
            content = .outline
        default:
            content = .map(.wholeMap)
        }
        return PDFExportOptions(
            content: content,
            includeBackground: choice.pdfBackground,
            includeBookmarks: choice.pdfBookmarks,
            title: title)
    }

    private static func rasterFormat(_ format: DocumentFormat) -> ImageExportFormat {
        switch format.id {
        case DocumentFormats.png.id: .png
        case DocumentFormats.jpeg.id: .jpeg
        default: .heic
        }
    }

    // MARK: panel metadata

    static func utType(for format: DocumentFormat) -> UTType {
        switch format.id {
        case DocumentFormats.plainText.id: .plainText
        case DocumentFormats.pdf.id: .pdf
        case DocumentFormats.png.id: .png
        case DocumentFormats.jpeg.id: .jpeg
        case DocumentFormats.heic.id: .heic
        case DocumentFormats.svg.id: UTType("public.svg-image") ?? .xml
        default:
            UTType(format.utTypeIdentifier)
                ?? UTType(filenameExtension: format.extensions.first ?? "") ?? .data
        }
    }

    /// The save panel's suggested filename: the document's display name
    /// plus the format's primary extension.
    static func suggestedFileName(for format: DocumentFormat, documentName: String?) -> String {
        var base = documentName?.isEmpty == false ? documentName! : "Untitled"
        if let dot = base.lastIndex(of: "."), base != ".hidden" {
            base = String(base[base.startIndex..<dot])
        }
        return "\(base).\(format.extensions.first ?? format.id)"
    }

    // MARK: last-choice persistence

    private static let defaultsKey = "export.lastChoice"

    static func loadLastChoice(defaults: UserDefaults = .standard) -> ExportChoice? {
        guard let raw = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ExportChoice.self, from: raw)
    }

    static func saveLastChoice(_ choice: ExportChoice, defaults: UserDefaults = .standard) {
        if let raw = try? JSONEncoder().encode(choice) {
            defaults.set(raw, forKey: defaultsKey)
        }
    }
}

/// What the sheet's live preview shows for a choice: a rendered
/// thumbnail or, for text formats, the exported text itself.
enum ExportPreview {
    case image(Data)
    case text(String)
    case failed(String)

    /// Renders a small preview: rasters get a 256 px PNG thumbnail; PDF
    /// and SVG get their rasterized/thumbnail PNG; text formats show the
    /// exported bytes. `theme` resolves user themes when no live scene
    /// exists.
    static func render(
        choice: ExportChoice,
        model: MapModel,
        scene: CanvasScene?,
        selection: Set<String>,
        variant: ThemeVariant,
        documentTitle: String,
        theme: MapRender.Theme? = nil
    ) -> ExportPreview {
        // Thumbnails mirror the live document: whatever the format, a
        // small PNG of the map (or the outline's first lines) reads
        // best; the text formats show their own bytes.
        if let format = ExportCoordinator.format(for: choice),
            [
                DocumentFormats.opml.id, DocumentFormats.markdown.id,
                DocumentFormats.plainText.id, DocumentFormats.freemind.id,
            ].contains(format.id)
        {
            do {
                let data = try ExportCoordinator.exportData(
                    choice: choice, model: model, scene: scene, selection: selection,
                    variant: variant, documentTitle: documentTitle)
                let text = String(data: data, encoding: .utf8) ?? ""
                return .text(String(text.prefix(2_000)))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        do {
            let mapScene = scene ?? ExportCoordinator.scene(for: model, variant: variant, theme: theme)
            var options = ImageExportOptions(format: .png, targetLongEdgePixels: 256)
            options.margin = 24
            let result = try ImageExporter.export(scene: mapScene, model: model, options: options)
            return .image(result.data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
