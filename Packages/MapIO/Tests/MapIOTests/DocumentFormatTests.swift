import Foundation
import MapCore
import Testing

@testable import MapIO

/// The `DocumentFormat` registry (F-IO) and the `DocumentIO` facade that
/// every implemented format routes through.
@Suite
struct DocumentFormatTests {
    @Test func registryCoversTheImplementedFormats() {
        #expect(
            DocumentFormats.all.map(\.id)
                == ["arbor", "opml", "markdown", "plainText", "freemind", "xmind", "mindnode"])
        #expect(DocumentFormats.all.map(\.displayName).count == DocumentFormats.all.count)
    }

    @Test func capabilitiesMatchTheSpecTable() {
        #expect(DocumentFormats.opml.capability == .both)
        #expect(DocumentFormats.markdown.canImport && DocumentFormats.markdown.canExport)
        #expect(DocumentFormats.plainText.canImport && DocumentFormats.plainText.canExport)
        #expect(DocumentFormats.freemind.canImport && DocumentFormats.freemind.canExport)
        #expect(DocumentFormats.xmind.capability == .importOnly)
        #expect(DocumentFormats.mindnode.capability == .importOnly)
        #expect(!DocumentFormats.xmind.canExport)
        #expect(!DocumentFormats.mindnode.canExport)
    }

    @Test func lookupsByIdExtensionAndUTType() {
        #expect(DocumentFormats.format(id: "opml") == DocumentFormats.opml)
        #expect(DocumentFormats.format(forExtension: "OPML") == DocumentFormats.opml)
        #expect(DocumentFormats.format(forExtension: "md") == DocumentFormats.markdown)
        #expect(DocumentFormats.format(forExtension: "xmind") == DocumentFormats.xmind)
        #expect(DocumentFormats.format(forExtension: "zzz") == nil)
        #expect(DocumentFormats.format(forUTType: "org.opml.opml") == DocumentFormats.opml)
        #expect(DocumentFormats.format(forUTType: "com.arbor.map") == DocumentFormats.arbor)
        // Stable ids and unique UTI strings: the open panel keys off them.
        #expect(Set(DocumentFormats.all.map(\.utTypeIdentifier)).count == DocumentFormats.all.count)
        #expect(Set(DocumentFormats.all.map(\.id)).count == DocumentFormats.all.count)
    }

    @Test func facadeImportsEverySupportedFormat() throws {
        let model = IOSamples.richSample()

        let opml = try DocumentIO.importDocument(
            Data(OPMLDocumentIO.exportDocument(model).utf8), format: DocumentFormats.opml)
        #expect(MapValidator.validate(opml).isEmpty)

        let markdown = try DocumentIO.importDocument(
            Data(MarkdownDocumentIO.exportDocument(model).utf8), format: DocumentFormats.markdown)
        #expect(MapValidator.validate(markdown).isEmpty)

        let plainText = try DocumentIO.importDocument(
            Data(PlainTextOutlineIO.exportDocument(model).utf8), format: DocumentFormats.plainText)
        #expect(MapValidator.validate(plainText).isEmpty)

        let freemind = try DocumentIO.importDocument(
            Data(FreeMindIO.exportDocument(model).utf8), format: DocumentFormats.freemind)
        #expect(MapValidator.validate(freemind).isEmpty)

        let xmind = try DocumentIO.importDocument(
            try Fixtures.data("xmind", "sample", "xmind"), format: DocumentFormats.xmind)
        #expect(MapValidator.validate(xmind).isEmpty)

        let mindnode = try DocumentIO.importDocument(
            try Fixtures.data("mindnode", "contents-v9", "plist"), format: DocumentFormats.mindnode)
        #expect(MapValidator.validate(mindnode).isEmpty)
    }

    @Test func facadeExportsTheTextFormats() throws {
        let model = IOSamples.richSample()
        for format in [
            DocumentFormats.opml, DocumentFormats.markdown, DocumentFormats.plainText,
            DocumentFormats.freemind,
        ] {
            let data = try DocumentIO.exportDocument(model, format: format)
            #expect(!data.isEmpty)
            let roundTripped = try DocumentIO.importDocument(data, format: format)
            #expect(MapValidator.validate(roundTripped).isEmpty)
        }
    }

    @Test func facadeRejectsWhatLaterSlicesOwn() throws {
        let model = IOSamples.richSample()
        #expect(throws: DocumentIOError.self) {
            _ = try DocumentIO.exportDocument(model, format: DocumentFormats.xmind)
        }
        #expect(throws: DocumentIOError.self) {
            _ = try DocumentIO.exportDocument(model, format: DocumentFormats.mindnode)
        }
        #expect(throws: DocumentIOError.self) {
            // The native package belongs to the document layer.
            _ = try DocumentIO.importDocument(Data(), format: DocumentFormats.arbor)
        }
        #expect(throws: DocumentIOError.self) {
            _ = try DocumentIO.importDocument(
                Data("weird".utf8),
                format: DocumentFormat(
                    id: "pdf", displayName: "PDF", utTypeIdentifier: "com.adobe.pdf",
                    extensions: ["pdf"], capability: .exportOnly))
        }
    }
}
