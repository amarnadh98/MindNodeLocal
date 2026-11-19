import Foundation
import MapCore

/// Routes raw document bytes to the matching importer/exporter through
/// the `DocumentFormats` registry (SPEC §5.17) — the seam the open panel
/// and the later export sheet call. These are the default-options paths;
/// a format with export options (Markdown heading depth, plain-text
/// indent) is exported through its own type. The native `.arbor`
/// package stays with the document layer (`MapDocumentCoder`).
public enum DocumentIO {
    /// Imports `data` as `format`. For `.xmind` the bytes are the whole
    /// zip archive; for `.mindnode` they are the package's `contents.xml`
    /// entry; for the text formats they are UTF-8 text.
    public static func importDocument(_ data: Data, format: DocumentFormat) throws -> MapModel {
        switch format.id {
        case DocumentFormats.opml.id:
            return try OPMLDocumentIO.importDocument(try decodedText(data, format))
        case DocumentFormats.markdown.id:
            return try MarkdownDocumentIO.importDocument(try decodedText(data, format))
        case DocumentFormats.plainText.id:
            return try PlainTextOutlineIO.importDocument(try decodedText(data, format))
        case DocumentFormats.freemind.id:
            return try FreeMindIO.importDocument(try decodedText(data, format))
        case DocumentFormats.xmind.id:
            return try XMindIO.importDocument(archive: data)
        case DocumentFormats.mindnode.id:
            return try MindNodeIO.importDocument(contentsXML: data)
        default:
            throw DocumentIOError.notImplemented("import of \(format.displayName) is a later slice")
        }
    }

    /// Exports the whole `model` as `format`, default options.
    public static func exportDocument(_ model: MapModel, format: DocumentFormat) throws -> Data {
        let text: String
        switch format.id {
        case DocumentFormats.opml.id:
            text = OPMLDocumentIO.exportDocument(model)
        case DocumentFormats.markdown.id:
            text = MarkdownDocumentIO.exportDocument(model)
        case DocumentFormats.plainText.id:
            text = PlainTextOutlineIO.exportDocument(model)
        case DocumentFormats.freemind.id:
            text = FreeMindIO.exportDocument(model)
        default:
            throw DocumentIOError.notImplemented("export of \(format.displayName) is a later slice")
        }
        return Data(text.utf8)
    }

    private static func decodedText(_ data: Data, _ format: DocumentFormat) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentIOError.malformed(
                format: format.id, reason: "the input is not valid UTF-8")
        }
        return text
    }
}
