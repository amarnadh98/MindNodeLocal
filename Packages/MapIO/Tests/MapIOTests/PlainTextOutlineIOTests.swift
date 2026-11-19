import Foundation
import MapCore
import Testing

@testable import MapIO

/// Plain indented-text document exchange (F-IO): golden exports, tab /
/// 2-space / 4-space auto-detection, round trip with the documented
/// (drastic) losses, malformed/empty input.
@Suite
struct PlainTextOutlineIOTests {
    @Test func goldenExportMatchesFixture() throws {
        let model = IOSamples.richSample()
        let tabs = try Fixtures.text("text", "golden", "txt")
        #expect(PlainTextOutlineIO.exportDocument(model) == tabs.trimmingTrailingNewline)

        let spaces = PlainTextOutlineIO.exportDocument(
            model, options: PlainTextExportOptions(indent: .spaces(2)))
        #expect(spaces.contains("\n  Bold move"))
        #expect(!spaces.contains("\t"))
    }

    @Test func exportImportRoundTripPreservesHierarchyAndTitles() throws {
        let source = IOSamples.richSample()
        for indent in [PlainTextExportOptions.Indent.tab, .spaces(2), .spaces(4)] {
            let options = PlainTextExportOptions(indent: indent)
            let roundTripped = try PlainTextOutlineIO.importDocument(
                PlainTextOutlineIO.exportDocument(source, options: options))
            #expect(canonicalDoc(roundTripped) == canonicalDoc(source).forPlainText())
            #expect(MapValidator.validate(roundTripped).isEmpty)
        }
    }

    @Test func detectsTabsTwoAndFourSpaceIndents() throws {
        let tabbed = try PlainTextOutlineIO.importDocument(
            try Fixtures.text("text", "sample", "txt"))
        let spaced = try PlainTextOutlineIO.importDocument(
            try Fixtures.text("text", "spaces", "txt"))
        // The same tab-indented sample with 4-space indents must parse to
        // the identical tree.
        let fourSpaces = try PlainTextOutlineIO.importDocument(
            try Fixtures.text("text", "sample", "txt").replacingOccurrences(of: "\t", with: "    "))

        let expected = CanonicalDoc(
            title: nil,
            roots: [
                CanonicalNode(
                    title: "产品 Vision 🚀", note: nil, task: nil, tagNames: [],
                    structure: nil, folded: false, side: nil, link: nil,
                    children: [
                        CanonicalNode(
                            title: "Research 论文", note: nil, task: nil, tagNames: [],
                            structure: nil, folded: false, side: nil, link: nil,
                            children: [
                                CanonicalNode(
                                    title: "Paper draft", note: nil, task: nil, tagNames: [],
                                    structure: nil, folded: false, side: nil, link: nil)
                            ]),
                        CanonicalNode(
                            title: "Ship & deliver", note: nil, task: nil, tagNames: [],
                            structure: nil, folded: false, side: nil, link: nil),
                    ]),
                CanonicalNode(
                    title: "Second root", note: nil, task: nil, tagNames: [],
                    structure: nil, folded: false, side: nil, link: nil,
                    children: [
                        CanonicalNode(
                            title: "Quoted \"child\"", note: nil, task: nil, tagNames: [],
                            structure: nil, folded: false, side: nil, link: nil)
                    ]),
            ],
            connections: [])

        #expect(canonicalDoc(tabbed) == expected)
        #expect(canonicalDoc(spaced) == expected)
        #expect(canonicalDoc(fourSpaces) == expected)
        #expect(MapValidator.validate(tabbed).isEmpty)
    }

    @Test func emptyInputThrows() {
        #expect(throws: DocumentIOError.self) {
            _ = try PlainTextOutlineIO.importDocument("")
        }
        #expect(throws: DocumentIOError.self) {
            _ = try PlainTextOutlineIO.importDocument("\n\n \t\n")
        }
    }
}
