import Foundation
import MapCore
import Testing

@testable import MapIO

/// XMind import (F-IO): both content shapes (`content.json` 2020+ and
/// `content.xml` Xmind 8, read through the in-house `MiniZip`), the
/// relationship/boundary/summary mappings, and malformed archives —
/// the constructed fixtures are documented in docs/io/format-matrix.md.
@Suite
struct XMindIOTests {
    @Test func importsXmind2020ContentJSON() throws {
        let archive = try Fixtures.data("xmind", "sample", "xmind")
        let model = try XMindIO.importDocument(archive: archive)
        #expect(MapValidator.validate(model).isEmpty)

        // Sheets → roots; the detached floating topic became its own root.
        #expect(model.roots.count == 2)
        let root = try #require(model.nodes[model.roots[0]])
        #expect(root.title.text == "产品 Vision 🚀")
        #expect(root.note == "Root note 论文")
        #expect(root.structure == "mindmap.balanced")
        #expect(root.task?.done == false)
        #expect(root.tagNames(model) == ["alpha"])
        #expect(model.nodes[model.roots[1]]?.title.text == "Floating idea")

        // Attached children nest; markers carry task state; labels map to
        // tags; structure classes map to Arbor structures.
        let research = try #require(model.nodes[root.children[0]])
        #expect(research.title.text == "Research")
        let chinese = try #require(model.nodes[research.children[0]])
        #expect(chinese.title.text == "中文节点")
        #expect(chinese.tagNames(model) == ["高优先"])
        let doneTopic = try #require(model.nodes[research.children[1]])
        #expect(doneTopic.task?.done == true)
        let ship = try #require(model.nodes[root.children[1]])
        #expect(ship.title.text == "Ship")
        #expect(ship.structure == "mindmap.right")

        // The boundary wrapped Research's two children, in order.
        #expect(model.boundaries?.count == 1)
        let boundary = try #require(model.boundaries?.first)
        #expect(boundary.title == "Group 研究")
        #expect(boundary.nodes == [chinese.id, doneTopic.id])

        // The summary spans the same range and references a summary node.
        #expect(model.summaries?.count == 1)
        let summary = try #require(model.summaries?.first)
        #expect(summary.parent == research.id)
        #expect(Set(summary.range) == Set([chinese.id, doneTopic.id]))
        #expect(model.nodes[summary.node]?.parent == research.id)

        // The relationship became a labeled connection.
        #expect(model.connections?.count == 1)
        let connection = try #require(model.connections?.first)
        #expect(model.nodes[connection.from]?.title.text == "产品 Vision 🚀")
        #expect(model.nodes[connection.to]?.title.text == "Ship")
        #expect(connection.label == "blocks")
    }

    @Test func summarySynthesizesANodeWhenTopicIDDoesNotResolve() throws {
        // Build an archive whose summary has no resolvable topicId.
        let content = """
            [{
              "id": "s1", "class": "sheet", "rootTopic": {
                "id": "root", "class": "topic", "title": "Root",
                "children": {"attached": [
                  {"id": "c1", "class": "topic", "title": "One"},
                  {"id": "c2", "class": "topic", "title": "Two"}
                ]},
                "summaries": [{"id": "sum", "class": "summary", "title": "Wrap", "range": {"begin": 0, "end": 1}}]
              }
            }]
            """
        let archive = TestZip.archive(entries: [
            (name: "content.json", data: Data(content.utf8))
        ])
        let model = try XMindIO.importDocument(archive: archive)
        #expect(model.summaries?.count == 1)
        let summary = try #require(model.summaries?.first)
        let summaryNode = try #require(model.nodes[summary.node])
        #expect(summaryNode.title.text == "Wrap")
        #expect(summaryNode.parent != nil)
        #expect(MapValidator.validate(model).isEmpty)
    }

    @Test func importsXmind8ContentXML() throws {
        let archive = try Fixtures.data("xmind", "legacy", "xmind")
        let model = try XMindIO.importDocument(archive: archive)
        #expect(MapValidator.validate(model).isEmpty)

        let root = try #require(model.nodes[model.roots[0]])
        #expect(root.title.text == "产品 Vision 🚀")
        #expect(root.structure == "mindmap.balanced")

        let research = try #require(model.nodes[root.children[0]])
        #expect(research.title.text == "Research 论文")
        #expect(research.tagNames(model) == ["alpha"])

        let chinese = try #require(model.nodes[research.children[0]])
        #expect(chinese.title.text == "中文节点")
        let doneTopic = try #require(model.nodes[research.children[1]])
        #expect(doneTopic.task?.done == true)

        let ship = try #require(model.nodes[root.children[1]])
        #expect(ship.title.text == "Ship")
        #expect(ship.note == "Ship note")

        #expect(model.connections?.count == 1)
        let connection = try #require(model.connections?.first)
        #expect(model.nodes[connection.from]?.title.text == "产品 Vision 🚀")
        #expect(model.nodes[connection.to]?.title.text == "Ship")
        #expect(connection.label == "blocks")
    }

    @Test func prefersContentJSONOverContentXML() throws {
        let archive = TestZip.archive(entries: [
            (name: "content.json", data: Data("[{\"rootTopic\": {\"title\": \"JSON\"}}]".utf8)),
            (name: "content.xml", data: Data("<xmap-content/>".utf8)),
        ])
        let model = try XMindIO.importDocument(archive: archive)
        #expect(model.nodes[model.roots[0]]?.title.text == "JSON")
    }

    @Test func malformedArchivesThrowNeverCrash() throws {
        #expect(throws: DocumentIOError.self) {
            _ = try XMindIO.importDocument(archive: Data("not a zip at all".utf8))
        }
        #expect(throws: DocumentIOError.self) {
            _ = try XMindIO.importDocument(archive: Data([0x50, 0x4b, 0x03, 0x04, 0x00]))
        }
        // A valid zip with no content entries.
        #expect(throws: DocumentIOError.self) {
            _ = try XMindIO.importDocument(
                archive: TestZip.archive(
                    entries: [(name: "metadata.json", data: Data("{}".utf8))]))
        }
        // A valid zip whose content.json is broken JSON.
        #expect(throws: DocumentIOError.self) {
            _ = try XMindIO.importDocument(
                archive: TestZip.archive(
                    entries: [(name: "content.json", data: Data("[not json".utf8))]))
        }
        // A valid zip whose content.json is not a sheet array.
        #expect(throws: DocumentIOError.self) {
            _ = try XMindIO.importDocument(
                archive: TestZip.archive(
                    entries: [(name: "content.json", data: Data(#"{"sheets": []}"#.utf8))]))
        }
    }
}

/// The in-house zip reader (ADR-0010): stored and DEFLATE entries, CRC
/// verification, structural damage → throws, never crashes.
@Suite
struct MiniZipTests {
    @Test func readsStoredEntriesBuiltInMemory() throws {
        let entries: [(name: String, data: Data)] = [
            (name: "content.json", data: Data("{\"a\":1}".utf8)),
            (name: "notes/研究.txt", data: Data("中文内容 🈶".utf8)),
        ]
        let archive = TestZip.archive(entries: entries)
        let read = try MiniZip.entries(of: archive)
        #expect(read.map(\.name) == ["content.json", "notes/研究.txt"])
        #expect(read.map(\.data) == entries.map(\.data))
    }

    @Test func readsDeflateEntriesFromTheFixtureArchive() throws {
        let archive = try Fixtures.data("xmind", "sample", "xmind")
        let entries = try MiniZip.entries(of: archive)
        let names = Set(entries.map(\.name))
        #expect(names.contains("content.json"))
        #expect(names.contains("metadata.json"))
        // The deflated entry decoded back to readable JSON.
        let content = try #require(entries.first { $0.name == "content.json" }?.data)
        let json = try #require(
            try JSONSerialization.jsonObject(with: content) as? [[String: Any]])
        #expect(json.first?["class"] as? String == "sheet")
    }

    @Test func rejectsStructuralDamage() throws {
        #expect(throws: MiniZip.ZipError.self) {
            _ = try MiniZip.entries(of: Data("short".utf8))
        }
        #expect(throws: MiniZip.ZipError.self) {
            // Valid EOCD signature lost to truncation.
            _ = try MiniZip.entries(of: Data([0x50, 0x4b, 0x05, 0x06]))
        }
        let archive = TestZip.archive(entries: [(name: "a.txt", data: Data("hello".utf8))])
        #expect(throws: MiniZip.ZipError.self) {
            _ = try MiniZip.entries(of: archive.prefix(archive.count - 10))
        }
    }

    @Test func verifiesCRC32() throws {
        var archive = TestZip.archive(entries: [(name: "a.txt", data: Data("hello".utf8))])
        // Corrupt the stored payload ("hello" → "jello") without touching
        // headers: find the payload after the 30+5-byte local header.
        archive[35] = UInt8(ascii: "j")
        #expect(throws: MiniZip.ZipError.self) {
            _ = try MiniZip.entries(of: archive)
        }
    }
}
