import Foundation
import MapCore
import Testing

@testable import MapIO

/// MindNode `.mindnode` import (F-IO): the binary-plist `contents.xml`
/// fixture (constructed from the publicly documented structure — no
/// real files were available), tolerant key handling, the
/// version-gate error with the OPML fallback hint, and malformed input.
@Suite
struct MindNodeIOTests {
    @Test func importsBinaryPlistFixture() throws {
        let data = try Fixtures.data("mindnode", "contents-v9", "plist")
        #expect(data.starts(with: [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]))  // "bplist00"
        let model = try MindNodeIO.importDocument(contentsXML: data)
        #expect(model.title == "研究 Roadmap")
        #expect(MapValidator.validate(model).isEmpty)

        let root = try #require(model.nodes[model.roots[0]])
        #expect(root.title.text == "产品 Vision 🚀")
        #expect(root.note == "Root note")
        #expect(root.folded)
        #expect(root.structure == "mindmap.balanced")

        let research = try #require(model.nodes[root.children[0]])
        #expect(research.title.text == "Research 论文")
        #expect(research.tagNames(model) == ["alpha"])
        #expect(research.task?.done == true)
        #expect(research.task?.due == "2026-12-01")

        let connection = try #require(model.connections?.first)
        #expect(model.nodes[connection.from]?.title.text == "产品 Vision 🚀")
        #expect(model.nodes[connection.to]?.title.text == "Research 论文")
        #expect(connection.label == "blocks")
    }

    @Test func readsTheXMLPlistSpellingToo() throws {
        // PropertyListSerialization reads either encoding; the importer
        // must accept the same fixture saved as plain XML.
        let data = try Fixtures.data("mindnode", "contents-v9", "xml")
        let model = try MindNodeIO.importDocument(contentsXML: data)
        #expect(model.nodes[model.roots[0]]?.title.text == "产品 Vision 🚀")
        #expect(MapValidator.validate(model).isEmpty)
    }

    @Test func unknownVersionFailsWithOPMLFallbackHint() throws {
        let unsupported = try plist([
            ("formatVersion", .string("12")),
            ("mindmapDocument", .dict([("rootNodes", .array)])),
        ])
        do {
            _ = try MindNodeIO.importDocument(contentsXML: unsupported)
            Issue.record("expected unsupportedVersion")
        } catch let error as DocumentIOError {
            guard case .unsupportedVersion(let format, let found, let hint) = error else {
                Issue.record("expected unsupportedVersion, got \(error)")
                return
            }
            #expect(format == "mindnode")
            #expect(found == "12")
            #expect(hint.contains("OPML"))
        }
    }

    @Test func malformedInputThrowsNeverCrashes() throws {
        #expect(throws: DocumentIOError.self) {
            _ = try MindNodeIO.importDocument(contentsXML: Data("garbage".utf8))
        }
        #expect(throws: DocumentIOError.self) {
            _ = try MindNodeIO.importDocument(contentsXML: Data())
        }
        // A well-formed plist with no version field.
        let versionless = try plist([("mindmapDocument", .dict([("rootNodes", .array)]))])
        #expect(throws: DocumentIOError.self) {
            _ = try MindNodeIO.importDocument(contentsXML: versionless)
        }
        // Version 9 but no recognizable node tree.
        let empty = try plist([
            ("formatVersion", .string("9")),
            ("mindmapDocument", .dict([("somethingElse", .string("x"))])),
        ])
        #expect(throws: DocumentIOError.self) {
            _ = try MindNodeIO.importDocument(contentsXML: empty)
        }
    }

    // MARK: tiny plist builder

    private enum PlistValue {
        case string(String)
        case dict([(String, PlistValue)])
        case array

        var value: Any {
            switch self {
            case .string(let string): return string
            case .dict(let entries):
                return Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.1.value) })
            case .array: return [Any]()
            }
        }
    }

    private func plist(_ entries: [(String, PlistValue)]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.1.value) }),
            format: .binary,
            options: 0)
    }
}
