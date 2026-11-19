import Foundation
import MapCore
import Testing

@testable import MapIO

/// Paste parsing fixtures (F-EDT-9): plain text with tab/space indentation,
/// Markdown headings + nested lists, OPML 2.0, XML escaping, unicode/CJK,
/// deep nesting and big-paste linearity.
@Suite
struct PasteParsingTests {
    /// (depth, title) pairs in outline order, for structural assertions.
    private func flatten(_ subtrees: [PastedSubtree]) -> [(depth: Int, title: String)] {
        var result: [(depth: Int, title: String)] = []
        func walk(_ subtree: PastedSubtree, depth: Int) {
            result.append((depth, subtree.snapshot.title.text))
            for child in subtree.children {
                walk(child, depth: depth + 1)
            }
        }
        for subtree in subtrees {
            walk(subtree, depth: 0)
        }
        return result
    }

    private func titles(_ subtrees: [PastedSubtree]) -> [String] {
        flatten(subtrees).map(\.title)
    }

    private func paste(_ text: String, format: PasteFormat? = nil) throws -> [PastedSubtree] {
        try #require(PasteboardParser.parseText(text, format: format))
    }

    // MARK: Plain text

    @Test func tabsAndTwoSpaceIndentsBothWork() throws {
        let tabbed = try paste("Root\n\tChild\n\t\tGrand\n\tChild2")
        #expect(flatten(tabbed).map(\.depth) == [0, 1, 2, 1])

        let spaced = try paste("Root\n  Child\n    Grand\n  Child2")
        #expect(flatten(spaced).map(\.depth) == [0, 1, 2, 1])
    }

    @Test func mixedTabAndSpaceIndentationSharesOneScale() throws {
        // One tab and four spaces are the same depth step; eight spaces go
        // one level deeper.
        let mixed = try paste("Root\n\tChild one\n        Grand\n\tChild two")
        #expect(flatten(mixed).map(\.depth) == [0, 1, 2, 1])
        #expect(titles(mixed) == ["Root", "Child one", "Grand", "Child two"])
    }

    @Test func singleLinePastesAsOneNodeAndEmptyInputPastesNothing() throws {
        #expect(titles(try paste("Just a thought")) == ["Just a thought"])
        #expect(PasteboardParser.parseText("") == nil)
        #expect(PasteboardParser.parseText("   \n\n \t \n") == nil)
        #expect(PasteboardParser.detectFormat("") == nil)
    }

    @Test func unicodeCJKRoundTrip() throws {
        let text = "根概念\n\t子概念 甲\n\t\t孙子 ①\n\t子概念 乙\nBranch émoji 🎉"

        var model = MapModel.emptyDocument()
        model.nodes["r"] = Node(id: "r", title: NodeTitle(text: "根概念"))
        model.nodes["a"] = Node(id: "a", parent: "r", title: NodeTitle(text: "子概念 甲"))
        model.nodes["g"] = Node(id: "g", parent: "a", title: NodeTitle(text: "孙子 ①"))
        model.nodes["b"] = Node(id: "b", parent: "r", title: NodeTitle(text: "子概念 乙"))
        model.nodes["f"] = Node(id: "f", title: NodeTitle(text: "Branch émoji 🎉"))
        model.roots = ["r", "f"]
        model.nodes["r"]?.children = ["a", "b"]
        model.nodes["a"]?.children = ["g"]

        let exported = PasteboardSerializer.plainText(from: model, selection: model.roots)
        #expect(exported == text)
        #expect(titles(try paste(exported)) == titles(try paste(text)))
    }

    // MARK: Markdown

    @Test func headingsCreateLevelsAndListsNestUnderTheNearestHeading() throws {
        let text = """
            # Lecture
            Intro paragraph
            ## Topics
            - First
              - First dot one
              - First dot two
            - Second
            ### Extra
            * Star item
            1. Ordered item
            """
        let forest = try paste(text)
        #expect(
            flatten(forest).map(\.depth) == [0, 1, 1, 2, 3, 3, 2, 2, 3, 3])
        #expect(
            titles(forest) == [
                "Lecture", "Intro paragraph", "Topics", "First", "First dot one", "First dot two",
                "Second", "Extra", "Star item", "Ordered item",
            ])
    }

    @Test func markdownInlineStylesParseIntoRuns() throws {
        let forest = try paste(
            "- **bold** and *ital* and `code` and ~~gone~~ and [link](https://arbor.example)")
        let title = try #require(forest.first?.snapshot.title)
        #expect(title.text == "bold and ital and code and gone and link")

        let bold = try #require(title.runs.first { $0.bold == true })
        #expect(bold.range == [0, 4])
        #expect(title.runs.contains { $0.italic == true && $0.range == [9, 4] })
        #expect(title.runs.contains { $0.code == true && $0.range == [18, 4] })
        #expect(title.runs.contains { $0.strike == true && $0.range == [27, 4] })
        let link = try #require(title.runs.first { $0.link != nil })
        #expect(link.range == [36, 4])
        #expect(link.link == "https://arbor.example")
    }

    @Test func markdownInlineRenderRoundTripsThroughParse() throws {
        let title = NodeTitle(
            text: "Bold and linked and gone",
            runs: [
                Run(range: [0, 4], bold: true),
                Run(range: [9, 15], link: "https://arbor.example"),
                Run(range: [20, 4], strike: true),
            ])
        let rendered = MarkdownInline.render(title)
        #expect(rendered == "**Bold** and [linked and ~~gone~~](https://arbor.example)")

        let parsed = MarkdownInline.parse(rendered)
        #expect(parsed.text == title.text)
        #expect(MarkdownInline.render(parsed) == rendered)
        #expect(parsed.runs.contains { $0.bold == true && $0.range == [0, 4] })
        // The link label splits into its plain and struck parts, both linked.
        #expect(parsed.runs.contains { $0.range == [9, 11] && $0.link == "https://arbor.example" })
        #expect(
            parsed.runs.contains {
                $0.range == [20, 4] && $0.strike == true && $0.link == "https://arbor.example"
            })
    }

    // MARK: OPML

    @Test func opmlParsesEscapedAttributesAndNotes() throws {
        let text = """
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head><title>T &amp; T</title></head>
              <body>
                <outline text="A &amp; B &lt;C&gt; &quot;D&quot; &apos;E&apos;">
                  <outline text="概念图 🌲" _note="note with&#10;a newline"/>
                </outline>
              </body>
            </opml>
            """
        #expect(PasteboardParser.detectFormat(text) == .opml)
        let forest = try paste(text, format: .opml)
        #expect(flatten(forest).map(\.depth) == [0, 1])
        #expect(titles(forest) == [#"A & B <C> "D" 'E'"#, "概念图 🌲"])
        #expect(forest.first?.children.first?.snapshot.note == "note with\na newline")
    }

    @Test func opmlRenderEscapesAndRoundTrips() throws {
        var model = MapModel.emptyDocument()
        model.title = "Esc & ape"
        model.nodes["r"] = Node(
            id: "r", title: NodeTitle(text: #"A & B <C> "D" 'E'"#), note: "line one\nline two")
        model.nodes["c"] = Node(id: "c", parent: "r", title: NodeTitle(text: "概念图 🌲"))
        model.roots = ["r"]
        model.nodes["r"]?.children = ["c"]

        let opml = PasteboardSerializer.opml(from: model, selection: ["r"])
        #expect(opml.contains(#"text="A &amp; B &lt;C&gt; &quot;D&quot; &apos;E&apos;""#))
        #expect(opml.contains(#"text="概念图 🌲""#))
        #expect(opml.contains("_note=\"line one&#10;line two\""))

        let forest = try #require(PasteboardParser.parseText(opml, format: .opml))
        #expect(forest.first?.snapshot.title.text == #"A & B <C> "D" 'E'"#)
        #expect(forest.first?.snapshot.note == "line one\nline two")
        #expect(forest.first?.children.first?.snapshot.title.text == "概念图 🌲")
    }

    // MARK: Detection

    @Test func detectFormatPicksTheRightParser() throws {
        #expect(PasteboardParser.detectFormat("Hello\nWorld") == .plainText)
        #expect(PasteboardParser.detectFormat("- item\n- item two") == .markdown)
        #expect(PasteboardParser.detectFormat("## Heading") == .markdown)
        #expect(PasteboardParser.detectFormat("1. first\n2. second") == .markdown)
        #expect(PasteboardParser.detectFormat("  * nested") == .markdown)
        #expect(PasteboardParser.detectFormat("*emphasis* only") == .plainText)
        #expect(PasteboardParser.detectFormat("Root\n\tChild") == .plainText)
    }

    // MARK: Scale

    @Test func fiftyLevelDeepPasteAppliesAndValidates() throws {
        var text = "L0"
        for level in 1...49 {
            text += "\n" + String(repeating: "\t", count: level) + "L\(level)"
        }
        var target = MapModel.emptyDocument()
        target.nodes["T"] = Node(id: "T", title: NodeTitle(text: "Target"))
        target.roots = ["T"]

        let command = try #require(
            try PasteboardParser.pasteCommand(fromText: text, parent: "T", index: 0, in: target))
        try command.apply(to: &target)
        #expect(MapValidator.validate(target).isEmpty)

        var cursor = try #require(target.nodes["T"]?.children.first)
        for level in 0..<50 {
            #expect(target.nodes[cursor]?.title.text == "L\(level)")
            if level < 49 {
                cursor = try #require(target.nodes[cursor]?.children.first)
            }
        }
        #expect(target.nodes[cursor]?.children.isEmpty == true)
    }

    @Test func twoThousandLinePasteStaysLinear() throws {
        let clock = ContinuousClock()
        for size in [2_000, 8_000] {
            let lines = (0..<size).map { index in
                String(repeating: "\t", count: index % 4) + "N\(index)"
            }
            let elapsed = clock.measure {
                _ = PasteboardParser.parseText(lines.joined(separator: "\n"))
            }
            #expect(elapsed < .seconds(2), "\(size)-line paste took \(elapsed)")
        }

        let lines = (0..<2_000).map { index in
            String(repeating: "\t", count: index % 4) + "N\(index)"
        }
        let forest = try paste(lines.joined(separator: "\n"))
        let flat = flatten(forest)
        #expect(flat.count == 2_000)
        #expect(flat.map(\.depth) == (0..<2_000).map { $0 % 4 })
    }

    // MARK: Paste commands from text

    @Test func pastedTextUnderSelectionValidatesAndUndoIsExact() throws {
        var target = MapModel.emptyDocument()
        target.nodes["T"] = Node(id: "T", title: NodeTitle(text: "Target"))
        target.roots = ["T"]
        let original = target

        let command = try #require(
            try PasteboardParser.pasteCommand(
                fromText: "One\n\tTwo\n\t\tThree", parent: "T", index: 0, in: target))
        let undo = try command.inverse(in: target)
        try command.apply(to: &target)

        #expect(MapValidator.validate(target).isEmpty)
        let one = try #require(target.nodes["T"]?.children.first)
        #expect(target.nodes[one]?.title.text == "One")
        let two = try #require(target.nodes[one]?.children.first)
        #expect(target.nodes[two]?.title.text == "Two")
        let three = try #require(target.nodes[two]?.children.first)
        #expect(target.nodes[three]?.title.text == "Three")

        try undo.apply(to: &target)
        #expect(target == original)
    }

    @Test func missingParentThrowsAndNothingToPasteReturnsNothing() throws {
        var target = MapModel.emptyDocument()
        target.nodes["T"] = Node(id: "T", title: NodeTitle(text: "Target"))
        target.roots = ["T"]
        #expect(throws: ArborError.self) {
            _ = try PasteboardParser.pasteCommand(
                fromText: "x", parent: "nope", index: 0, in: target)
        }
        #expect(
            try PasteboardParser.pasteCommand(fromText: "  \n ", parent: "T", index: 0, in: target) == nil)
    }
}
