import Foundation
import Testing

@testable import MapAI

/// F-AI-1's structured-list robustness: the JSON-lines stream parser
/// handles chunked deltas, fences, junk and plain-text answers.
struct JSONLinesParserTests {
    @Test func emitsItemsAsLinesComplete() {
        var parser = JSONLinesStreamParser()
        var items: [AIListItem] = []
        items += parser.feed("{\"text\":\"One\"}\n")
        #expect(items.count == 1)
        items += parser.feed("{\"text\":\"Two\"}\n{\"text")
        #expect(items.count == 2)
        items += parser.feed("\":\"Three\"}\n")
        #expect(items.count == 3)
        items += parser.finish()
        #expect(items.map(\.text) == ["One", "Two", "Three"])
    }

    @Test func midLineChunkingAcrossDeltas() {
        var parser = JSONLinesStreamParser()
        var items: [AIListItem] = []
        for piece in ["{\"text\": \"Mi", "ndful brea", "thing\"}\n{\"text\":\"ok\"}\n"] {
            items += parser.feed(piece)
        }
        items += parser.finish()
        #expect(items.map(\.text) == ["Mindful breathing", "ok"])
    }

    @Test func parentIndexTravels() {
        let items = JSONLinesParser.parse(#"{"text":"Child","parentIndex":3}"#)
        #expect(items == [AIListItem(text: "Child", parentIndex: 3)])
    }

    @Test func malformedJSONLinesAreDroppedNotFatal() {
        let items = JSONLinesParser.parse(
            """
            {"text":"good"}
            {this is not json}
            {"text":"also good"}
            """)
        #expect(items.map(\.text) == ["good", "also good"])
    }

    @Test func codeFenceWrappingIsTolerated() {
        let items = JSONLinesParser.parse(
            """
            ```json
            {"text":"fenced"}
            ```
            """)
        #expect(items.map(\.text) == ["fenced"])
    }

    @Test func plainTextLinesFallBackGracefully() {
        let items = JSONLinesParser.parse(
            """
            - Idea one
            * Idea two
            3. Idea three
            "Quoted idea"
            """)
        #expect(items.map(\.text) == ["Idea one", "Idea two", "Idea three", "Quoted idea"])
    }

    @Test func emptyAndJunkLinesProduceNothing() {
        var parser = JSONLinesStreamParser()
        #expect(parser.feed("\n\n   \n").isEmpty)
        #expect(parser.finish().isEmpty)
        #expect(parser.feed("").isEmpty)
    }

    @Test func missingParentIndexDefaultsToNil() {
        let items = JSONLinesParser.parse(#"{"text":"no parent"}"#)
        #expect(items.first?.parentIndex == nil)
    }

    @Test func titleKeyIsAlsoAccepted() {
        let items = JSONLinesParser.parse(#"{"title":"aliased"}"#)
        #expect(items.map(\.text) == ["aliased"])
    }
}
