import Foundation
import MapCore
import Testing

@testable import MapIO

/// OPML 2.0 document exchange (F-IO): golden export, Arbor→OPML→Arbor
/// round trip lossless for tasks/tags/structure/folded (SPEC §5.17),
/// hand-written fixture import, malformed input, CJK + emoji.
@Suite
struct OPMLDocumentIOTests {
    @Test func goldenExportMatchesFixture() throws {
        let exported = OPMLDocumentIO.exportDocument(IOSamples.richSample())
        let golden = try Fixtures.text("opml", "golden", "opml")
        #expect(exported == golden.trimmingTrailingNewline)
    }

    @Test func exportImportRoundTripPreservesDocumentedFields() throws {
        let source = IOSamples.richSample()
        let roundTripped = try OPMLDocumentIO.importDocument(
            OPMLDocumentIO.exportDocument(source))
        #expect(canonicalDoc(roundTripped) == canonicalDoc(source).forOPML())
        #expect(MapValidator.validate(roundTripped).isEmpty)
    }

    @Test func importedModelHasFreshIdentityAndCleanTimestamps() throws {
        let source = IOSamples.richSample()
        let roundTripped = try OPMLDocumentIO.importDocument(
            OPMLDocumentIO.exportDocument(source))
        #expect(roundTripped.docID != source.docID)
        #expect(roundTripped.formatVersion == ArborFormat.formatVersion)
        #expect(Set(roundTripped.nodes.keys).isDisjoint(with: source.nodes.keys))
        for node in roundTripped.nodes.values {
            #expect(node.created == node.modified)
        }
        // Hierarchy invariants (MapValidator double-checks below).
        for (id, node) in roundTripped.nodes {
            if let parentID = node.parent {
                #expect(roundTripped.nodes[parentID]?.children.contains(id) == true)
            } else {
                #expect(roundTripped.roots.contains(id))
            }
        }
        #expect(MapValidator.validate(roundTripped).isEmpty)
    }

    @Test func importsHandWrittenFixture() throws {
        let model = try OPMLDocumentIO.importDocument(
            try Fixtures.text("opml", "sample", "opml"))
        #expect(model.title == "会议纪要 Meeting Notes")
        #expect(MapValidator.validate(model).isEmpty)

        // Root 1: note with a &#10; newline, one done task, one open task
        // with due + priority, tags, folded structure child.
        let first = try #require(model.nodes[model.roots[0]])
        #expect(first.title.text == "产品 Vision 🚀")
        #expect(first.note == "第一行\nsecond line")
        let research = try #require(model.nodes[first.children[0]])
        #expect(research.task == NodeTask(done: false, due: "2026-12-01", priority: 2))
        let cjk = try #require(model.nodes[research.children[0]])
        #expect(cjk.title.text == "中文研究")
        #expect(cjk.tagNames(model) == ["高优先", "alpha"])
        let paper = try #require(model.nodes[research.children[1]])
        #expect(paper.title.text == "Paper <draft>")
        #expect(paper.folded)
        #expect(paper.structure == "mindmap.balanced")
        let ship = try #require(model.nodes[first.children[1]])
        #expect(ship.title.text == "Ship & deliver")
        #expect(ship.task?.done == true)

        // Root 2: XML-escaped attribute values.
        let second = try #require(model.nodes[model.roots[1]])
        #expect(second.title.text == "第二个根 Second root")
        let child = try #require(model.nodes[second.children[0]])
        #expect(child.title.text == "Child \"quoted\"")
        #expect(child.note == "note with an & entity")
    }

    @Test func tagNamesResolveToDeclaredTags() throws {
        let model = try OPMLDocumentIO.importDocument(
            try Fixtures.text("opml", "sample", "opml"))
        let declared = Set((model.tags ?? []).map(\.name))
        #expect(declared == ["高优先", "alpha"])
        for node in model.nodes.values {
            for tagID in node.tags ?? [] {
                #expect((model.tags ?? []).contains { $0.id == tagID })
            }
        }
    }

    @Test func malformedInputThrowsNeverCrashes() {
        #expect(throws: DocumentIOError.self) {
            _ = try OPMLDocumentIO.importDocument("this is not xml <oops")
        }
        #expect(throws: DocumentIOError.self) {
            _ = try OPMLDocumentIO.importDocument("<html><body>nope</body></html>")
        }
        #expect(throws: DocumentIOError.self) {
            _ = try OPMLDocumentIO.importDocument(
                #"<?xml version="1.0"?><opml version="2.0"><head/><body/></opml>"#)
        }
        #expect(throws: DocumentIOError.self) {
            _ = try OPMLDocumentIO.importDocument("")
        }
        #expect(throws: DocumentIOError.self) {
            _ = try OPMLDocumentIO.importDocument(
                #"{"json": "disguised as opml"}"#)
        }
    }
}
