import Foundation
import MapCore
import Testing

@testable import MapIO

/// Markdown document exchange (F-IO): golden exports for both heading
/// modes, round trip with the documented losses, the hand-written
/// fixture (headings + nested lists + tasks + note paragraphs + inline
/// styles + CJK), malformed/empty input.
@Suite
struct MarkdownDocumentIOTests {
    @Test func goldenExportMatchesFixture() throws {
        let model = IOSamples.richSample()
        let headings = try Fixtures.text("markdown", "golden", "md")
        #expect(
            MarkdownDocumentIO.exportDocument(model) == headings.trimmingTrailingNewline)
        let lists = try Fixtures.text("markdown", "golden-lists", "md")
        #expect(
            MarkdownDocumentIO.exportDocument(
                model, options: MarkdownExportOptions(headingDepth: nil))
                == lists.trimmingTrailingNewline)
    }

    @Test func exportImportRoundTripPreservesDocumentedFields() throws {
        let source = IOSamples.richSample()
        for headingDepth in [nil, 1, 2, 3] {
            let options = MarkdownExportOptions(headingDepth: headingDepth)
            let roundTripped = try MarkdownDocumentIO.importDocument(
                MarkdownDocumentIO.exportDocument(source, options: options))
            #expect(canonicalDoc(roundTripped) == canonicalDoc(source).forMarkdown())
            #expect(MapValidator.validate(roundTripped).isEmpty)
        }
    }

    @Test func roundTripPreservesInlineRuns() throws {
        let source = IOSamples.richSample()
        let roundTripped = try MarkdownDocumentIO.importDocument(
            MarkdownDocumentIO.exportDocument(source))
        // "Bold move" carries one bold run over its first word.
        let boldNode = try #require(
            roundTripped.nodes.values.first { $0.title.text == "Bold move" })
        #expect(boldNode.title.runs == [Run(range: [0, 4], bold: true)])
    }

    @Test func importsHandWrittenFixture() throws {
        let model = try MarkdownDocumentIO.importDocument(
            try Fixtures.text("markdown", "sample", "md"))
        #expect(MapValidator.validate(model).isEmpty)

        func node(_ title: String) -> Node? {
            model.nodes.values.first { $0.title.text == title }
        }

        let roadmap = try #require(node("产品 Roadmap 🚀"))
        #expect(roadmap.note == "Plan for Q4 研究.")
        #expect(model.roots.count == 2)

        let readPapers = try #require(node("Read papers 论文"))
        #expect(readPapers.task?.done == false)
        let alphaPaper = try #require(node("Alpha paper"))
        #expect(alphaPaper.task?.done == true)
        let betaPaper = try #require(node("Beta paper"))
        #expect(betaPaper.note == "Needs a subscription.")

        let boldItem = try #require(
            model.nodes.values.first { $0.title.text == "Bold item with code and a link" })
        #expect(boldItem.title.runs.contains { $0.bold == true })
        #expect(boldItem.title.runs.contains { $0.code == true })
        #expect(boldItem.title.runs.contains { $0.link == "https://example.com" })
        #expect(boldItem.note == "This paragraph is the note of the bold item.")

        let deep = try #require(node("Deep branch"))
        #expect(model.nodes[deep.parent ?? ""]?.title.text == "Research")
        let leafTwo = try #require(node("Leaf two"))
        #expect(leafTwo.note == "Note line one.\nNote line two.")

        let itemA = try #require(node("item A"))
        #expect(model.nodes[itemA.parent ?? ""]?.title.text == "Second root 📚")
    }

    @Test func taskNodesForceListModeUnderHeadings() throws {
        let model = try MarkdownDocumentIO.importDocument(
            try Fixtures.text("markdown", "golden", "md"))
        let boldMove = try #require(
            model.nodes.values.first { $0.title.text == "Bold move" })
        #expect(boldMove.task?.done == true)
        // The task node is a child of the H1 root, not a sibling heading.
        let parent = try #require(boldMove.parent)
        #expect(model.nodes[parent]?.title.text == "产品 Vision 🚀")
    }

    @Test func headingDepthOptionShapesOutputOnly() throws {
        let model = IOSamples.richSample()
        let withHeadings = MarkdownDocumentIO.exportDocument(
            model, options: MarkdownExportOptions(headingDepth: 2))
        #expect(withHeadings.lines.contains { $0.hasPrefix("# ") })
        #expect(withHeadings.lines.contains { $0.hasPrefix("## ") })

        // Every variant parses back to the same canonical document.
        for headingDepth in [0, 1, 2, 3, 6] {
            let options = MarkdownExportOptions(headingDepth: headingDepth)
            let exported = MarkdownDocumentIO.exportDocument(model, options: options)
            let roundTripped = try MarkdownDocumentIO.importDocument(exported)
            #expect(canonicalDoc(roundTripped) == canonicalDoc(model).forMarkdown())
        }
        // `nil` exports the whole map as lists: no heading lines at all.
        let listsOnly = MarkdownDocumentIO.exportDocument(
            model, options: MarkdownExportOptions(headingDepth: nil))
        #expect(!listsOnly.lines.contains { $0.hasPrefix("#") })
    }

    @Test func cjkEmojiAndInlineStylesRoundTrip() throws {
        let text = """
            # 脑图 🧠

            - **加粗** 研究
                - *斜体* 论文
                    - `代码` note
                        - [x] 完成 ✅ with a [链接](https://example.com/研究)
            """
        let model = try MarkdownDocumentIO.importDocument(text)
        #expect(MapValidator.validate(model).isEmpty)
        let exported = MarkdownDocumentIO.exportDocument(
            model, options: MarkdownExportOptions(headingDepth: nil))
        let roundTripped = try MarkdownDocumentIO.importDocument(exported)
        #expect(canonicalDoc(roundTripped) == canonicalDoc(model))
        #expect(canonicalDoc(model).roots.first?.title == "脑图 🧠")
    }

    @Test func emptyInputThrows() {
        #expect(throws: DocumentIOError.self) {
            _ = try MarkdownDocumentIO.importDocument("")
        }
        #expect(throws: DocumentIOError.self) {
            _ = try MarkdownDocumentIO.importDocument("   \n  \n\t")
        }
    }
}
