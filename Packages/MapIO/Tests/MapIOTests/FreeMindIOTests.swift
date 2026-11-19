import Foundation
import MapCore
import Testing

@testable import MapIO

/// FreeMind/Freeplane `.mm` document exchange (F-IO): golden export,
/// round trip, the hand-written fixture (richcontent notes, FOLDED,
/// POSITION side pins, LINK, attributes, arrowlink connections, the
/// button_ok done icon), malformed input.
@Suite
struct FreeMindIOTests {
    @Test func goldenExportMatchesFixture() throws {
        let exported = FreeMindIO.exportDocument(IOSamples.richSample())
        let golden = try Fixtures.text("freemind", "golden", "mm")
        #expect(exported == golden.trimmingTrailingNewline)
    }

    @Test func exportImportRoundTripPreservesDocumentedFields() throws {
        let source = IOSamples.richSample()
        let roundTripped = try FreeMindIO.importDocument(
            FreeMindIO.exportDocument(source))
        #expect(canonicalDoc(roundTripped) == canonicalDoc(source).forFreeMind())
        #expect(MapValidator.validate(roundTripped).isEmpty)
    }

    @Test func importsHandWrittenFixture() throws {
        let model = try FreeMindIO.importDocument(
            try Fixtures.text("freemind", "sample", "mm"))
        #expect(MapValidator.validate(model).isEmpty)

        let root = try #require(model.nodes[model.roots[0]])
        #expect(root.title.text == "产品 Vision 🚀")
        #expect(root.note == "First note line\nSecond & line")

        let research = try #require(model.nodes[root.children[0]])
        #expect(research.title.text == "Research 论文")
        #expect(research.side == .right)
        #expect(research.task?.due == "2026-12-01")
        #expect(research.tagNames(model) == ["alpha", "高优先"])

        let paper = try #require(model.nodes[research.children[0]])
        #expect(paper.title.text == "Paper draft")
        #expect(paper.link == "https://example.com/paper")

        let ship = try #require(model.nodes[root.children[1]])
        #expect(ship.title.text == "Ship it")
        #expect(ship.side == .left)
        #expect(ship.folded)
        #expect(ship.task?.done == true)

        // The arrowlink became a real connection, unlabeled.
        #expect(model.connections?.count == 1)
        let connection = try #require(model.connections?.first)
        #expect(model.nodes[connection.from]?.title.text == "Paper draft")
        #expect(model.nodes[connection.to]?.title.text == "Ship it")
        #expect(connection.label == nil)
    }

    @Test func malformedInputThrowsNeverCrashes() {
        #expect(throws: DocumentIOError.self) {
            _ = try FreeMindIO.importDocument("definitely <not> & xml")
        }
        #expect(throws: DocumentIOError.self) {
            _ = try FreeMindIO.importDocument("<html><body/></html>")
        }
        #expect(throws: DocumentIOError.self) {
            _ = try FreeMindIO.importDocument(
                #"<?xml version="1.0"?><map version="1.0.1"></map>"#)
        }
        #expect(throws: DocumentIOError.self) {
            _ = try FreeMindIO.importDocument("")
        }
    }
}
