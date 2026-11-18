import Testing

@testable import MapIO

@Test func importFormatsMatchSpec() {
    #expect(ImportFormat.allCases.count == 11)
    #expect(
        Set(ImportFormat.allCases.map(\.rawValue)) == [
            "arbor", "opml", "markdown", "plainText", "freemind", "xmind",
            "mindnode", "textBundle", "rtf", "csv", "jsonCanvas",
        ])
}

@Test func exportFormatsMatchSpec() {
    #expect(ExportFormat.allCases.count == 16)
    #expect(
        Set(ExportFormat.allCases.map(\.rawValue)) == [
            "arbor", "opml", "markdown", "plainText", "pdf", "png", "svg",
            "freemind", "xmind", "textBundle", "rtf", "csv", "pptx", "anki",
            "jsonCanvas", "mermaid",
        ])
}

@Test func everySpecFormatIsCoveredExactlyOnceByDirection() {
    let imports = Set(ImportFormat.allCases.map(\.rawValue))
    let exports = Set(ExportFormat.allCases.map(\.rawValue))
    let specFormats: Set<String> = [
        "arbor", "opml", "markdown", "plainText", "pdf", "png", "svg",
        "freemind", "xmind", "mindnode", "textBundle", "rtf", "csv",
        "pptx", "anki", "jsonCanvas", "mermaid",
    ]
    #expect(imports.union(exports) == specFormats)
    #expect(!imports.contains("pdf"))
    #expect(!imports.contains("png"))
    #expect(!imports.contains("svg"))
    #expect(!imports.contains("pptx"))
    #expect(!imports.contains("anki"))
    #expect(!imports.contains("mermaid"))
    #expect(!exports.contains("mindnode"))
}
