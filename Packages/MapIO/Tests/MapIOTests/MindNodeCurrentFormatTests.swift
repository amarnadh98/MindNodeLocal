import Foundation
import MapCore
import Testing

@testable import MapIO

/// MindNode current-format import (ADR-0035): the synthetic wire
/// fixture, the metadata version gate, entry dispatch, robustness on
/// truncated and fuzzed bytes, an `.arbor` package round trip, and —
/// when `ARBOR_REAL_MINDNODE` points at a real file — an end-to-end
/// import of it (skipped otherwise, so CI never depends on personal
/// data).
@Suite
struct MindNodeCurrentFormatTests {
    // MARK: the synthetic document

    private func importArchive(_ archive: Data) throws -> MapModel {
        try MindNodeIO.importDocument(archive: archive)
    }

    /// The outline of an imported model, for assertions and the
    /// report: (title, note) pairs, depth-indented.
    private func outline(_ model: MapModel) -> String {
        var lines: [String] = []
        func walk(_ id: String, depth: Int) {
            guard let node = model.nodes[id] else { return }
            let title = node.title.text.isEmpty ? "«empty»" : node.title.text
            lines.append(String(repeating: "  ", count: depth) + title)
            for child in node.children {
                walk(child, depth: depth + 1)
            }
        }
        for root in model.roots {
            walk(root, depth: 0)
        }
        return lines.joined(separator: "\n")
    }

    @Test func importsTheSyntheticCurrentFormatDocument() throws {
        let model = try importArchive(MindNodeSyntheticFile.archive())

        // The builder writes the child lists in UUID (protobuf map)
        // order — root children appear in the WIRE as
        // [Second, First] — while the `4 → 1 → 2` position keys say
        // [First(200), Second(400)]. Display order must win, together
        // with the empty node, the floating-text node and the
        // detached empty's exclusion (as in MindNode's own outline).
        #expect(
            outline(model) == """
                Golden Root
                  First branch
                    Child one
                    «empty»
                  Second branch
                    Floating text
                """)
        #expect(MapValidator.validate(model).isEmpty)

        let root = try #require(model.nodes[model.roots[0]])
        #expect(root.children.count == 2)
        let first = try #require(model.nodes[root.children[0]])
        #expect(first.title.text == "First branch")
        // The guessed note extraction rides along when present.
        let childOne = try #require(model.nodes[first.children[0]])
        #expect(childOne.title.text == "Child one")
        #expect(childOne.note == "a note rides along")
        // The detached empty node never became a child.
        let second = try #require(model.nodes[root.children[1]])
        #expect(second.children.count == 1)
        #expect(model.nodes[second.children[0]]?.title.text == "Floating text")
        // Exactly one empty-titled node — the attached one.
        #expect(model.nodes.values.filter { $0.title.text.isEmpty }.count == 1)
    }

    /// The real file's ordering trap, distilled: MindNode stores child
    /// lists in map order and the DISPLAY order in each record's
    /// `4 → 1 → 2` varint (a fractional index — 100 / 200 / 400 in the
    /// sample). A file whose wire order is [X, Y, Z] but whose keys say
    /// [Y, Z, X] must import as [Y, Z, X]; a tie or a missing key
    /// falls back to the wire order.
    @Test func ordersSiblingsByThePositionKeyNotTheWireOrder() throws {
        let doc = [UInt8](repeating: 0xAB, count: 16)
        func uuid(_ tag: UInt8) -> [UInt8] {
            [tag] + [UInt8](repeating: 0, count: 15)
        }
        let root = uuid(0x01)
        let x = uuid(0x02)
        let y = uuid(0x03)
        let z = uuid(0x04)
        let tieOne = uuid(0x05)
        let tieTwo = uuid(0x06)
        let style = [UInt8](repeating: 0x5A, count: 16)

        func nodeRecord(_ subject: [UInt8], title: String) -> [UInt8] {
            let attributed =
                PB.message(1, PB.message(4, PB.bytes(1, Array(title.utf8))))
            return PB.message(
                2, PB.bytes(1, subject) + PB.message(2, PB.message(11, attributed)))
        }
        func treeRecord(
            _ subject: [UInt8], parent: [UInt8]? = nil, children: [[UInt8]] = [],
            position: UInt64? = nil
        ) -> [UInt8] {
            var record = PB.bytes(1, subject)
            if let parent {
                record += PB.bytes(2, parent)
            }
            for child in children {
                record += PB.bytes(3, child)
            }
            if let position {
                record += PB.message(4, PB.message(1, PB.bytes(1, style) + PB.varint(2, position)))
            }
            return PB.message(2, record)
        }

        // Wire order [X, Y, Z, tieOne, tieTwo]; keys X=400, Y=100,
        // Z=200, ties absent → display [Y, Z, X, tieOne, tieTwo].
        let tree =
            PB.bytes(1, doc)
            + treeRecord(doc, children: [root])
            + treeRecord(root, parent: doc, children: [x, y, z, tieOne, tieTwo], position: 200)
            + treeRecord(x, parent: root, position: 400)
            + treeRecord(y, parent: root, position: 100)
            + treeRecord(z, parent: root, position: 200)
            + treeRecord(tieOne, parent: root)
            + treeRecord(tieTwo, parent: root)
        let store: [[UInt8]] = [
            nodeRecord(root, title: "R"),
            nodeRecord(x, title: "X"),
            nodeRecord(y, title: "Y"),
            nodeRecord(z, title: "Z"),
            nodeRecord(tieOne, title: "tie one"),
            nodeRecord(tieTwo, title: "tie two"),
            PB.message(3, tree),
        ]
        let document =
            PB.message(
                1, PB.bytes(1, doc) + PB.message(2, PB.message(1, store.reduce([], +))))
        let archive = TestZip.archive(entries: [
            ("Metadata.json", MindNodeSyntheticFile.metadata()),
            ("Contents.data", Data(document)),
        ])

        let model = try importArchive(archive)
        #expect(
            outline(model) == """
                R
                  Y
                  Z
                  X
                  tie one
                  tie two
                """)
    }

    @Test func importsTheCommittedGoldenFixture() throws {
        // The binary fixture the hosted app test opens (generated by
        // scripts/generate_mindnode_fixture.swift): keeps the script
        // and this suite from drifting apart.
        let data = try Fixtures.data("mindnode", "synthetic-current", "mindnode")
        let model = try importArchive(data)
        #expect(outline(model).hasPrefix("Golden Root"))
        #expect(MapValidator.validate(model).isEmpty)
    }

    @Test func roundTripsThroughAnArborPackage() throws {
        // F-IO: an imported map is an ordinary model — saving and
        // reopening it as `.arbor` must preserve the whole outline.
        let imported = try importArchive(MindNodeSyntheticFile.archive())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mindnode-import-\(UUID().uuidString).arbor")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArborPackage.write(
            imported,
            meta: PackageMeta(appVersion: "test", docID: imported.docID),
            to: url)
        let reopened = try ArborPackage.read(at: url).model

        func tree(_ model: MapModel, _ id: String) -> String {
            guard let node = model.nodes[id] else { return "" }
            let childText = node.children.map { tree(model, $0) }.joined()
            return node.title.text + childText
        }
        #expect(
            tree(imported, imported.roots[0]) == tree(reopened, reopened.roots[0]))
        #expect(outline(reopened) == outline(imported))
    }

    // MARK: the metadata gate

    @Test func refusesFormatsNewerThanVersionOne() throws {
        let newer = MindNodeSyntheticFile.archive(minVersion: 2)
        do {
            _ = try importArchive(newer)
            Issue.record("expected unsupportedVersion")
        } catch let error as DocumentIOError {
            guard case .unsupportedVersion(let format, let found, let hint) = error else {
                Issue.record("expected unsupportedVersion, got \(error)")
                return
            }
            #expect(format == "mindnode")
            #expect(found == "2")
            #expect(hint.contains("Arbor can't read yet"))
            #expect(hint.contains("OPML"))
            // The localized message the import sheet shows.
            #expect(
                (error as LocalizedError).errorDescription?.contains("can't read yet") == true)
        }
    }

    @Test func metadataProvenanceIsQuotedInTheHint() throws {
        let newer = MindNodeSyntheticFile.archive(minVersion: 7)
        do {
            _ = try importArchive(newer)
        } catch let error as DocumentIOError {
            guard case .unsupportedVersion(_, _, let hint) = error else { return }
            #expect(hint.contains("2026.7.2-test"))
        }
    }

    @Test func missingMetadataJSONIsAMalformedFile() throws {
        let entries = TestZip.archive(entries: [
            ("Contents.data", MindNodeSyntheticFile.contentsData(root: .init("R")))
        ])
        #expect(throws: DocumentIOError.self) {
            _ = try importArchive(entries)
        }
    }

    // MARK: entry dispatch

    @Test func dispatchesByZipEntryName() throws {
        // A zip carrying the legacy entry still imports the old way.
        let legacy = try Fixtures.data("mindnode", "contents-v9", "plist")
        let zippedLegacy = TestZip.archive(entries: [("contents.xml", legacy)])
        let model = try importArchive(zippedLegacy)
        #expect(model.nodes[model.roots[0]]?.title.text == "产品 Vision 🚀")

        // A zip with neither entry is not a MindNode document.
        let foreign = TestZip.archive(entries: [("whatever.txt", Data("x".utf8))])
        do {
            _ = try importArchive(foreign)
            Issue.record("expected malformed")
        } catch let error as DocumentIOError {
            guard case .malformed(_, let reason) = error else {
                Issue.record("expected malformed, got \(error)")
                return
            }
            #expect(reason.contains("neither Contents.data nor contents.xml"))
        }

        // Bytes that are not a zip at all keep the legacy contract:
        // they are a raw `contents.xml`.
        let model2 = try importArchive(legacy)
        #expect(model2.nodes[model2.roots[0]]?.title.text == "产品 Vision 🚀")
    }

    // MARK: robustness

    @Test func truncatedContentsNeverCrash() throws {
        let whole = MindNodeSyntheticFile.contentsData(root: MindNodeSyntheticFile.goldenMap)
        for cut in stride(from: 0, to: whole.count, by: 3) {
            let archive = TestZip.archive(entries: [
                ("Metadata.json", MindNodeSyntheticFile.metadata()),
                ("Contents.data", whole.prefix(cut)),
            ])
            // Every truncation either throws or yields a valid (if
            // partial) model — never a crash, never a hang.
            if let model = try? importArchive(archive) {
                #expect(MapValidator.validate(model).isEmpty)
            }
        }
    }

    @Test func fuzzedArchivesNeverCrash() throws {
        var seed: UInt64 = 0xDEAD_BEEF
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        for _ in 0..<300 {
            let count = Int(next() % 700)
            var contents = Data()
            for _ in 0..<count {
                contents.append(UInt8(next() % 256))
            }
            let archive = TestZip.archive(entries: [
                ("Metadata.json", MindNodeSyntheticFile.metadata()),
                ("Contents.data", contents),
            ])
            if let model = try? importArchive(archive) {
                #expect(MapValidator.validate(model).isEmpty)
            }
        }
    }

    @Test func cyclicTreeRecordsAreHarmless() throws {
        // Two nodes claiming each other as children: the visited set
        // defuses the cycle instead of looping forever.
        let doc = [UInt8](repeating: 0xAB, count: 16)
        let uuidA = [UInt8](repeating: 0x01, count: 16)
        let uuidB = [UInt8](repeating: 0x02, count: 16)
        let tree =
            PB.bytes(1, doc)
            + PB.message(2, PB.bytes(1, doc) + PB.bytes(3, uuidA))
            + PB.message(
                2, PB.bytes(1, uuidA) + PB.bytes(2, doc) + PB.bytes(3, uuidB))
            + PB.message(
                2, PB.bytes(1, uuidB) + PB.bytes(2, uuidA) + PB.bytes(3, uuidA))
        let emptyTitle = PB.message(2, PB.message(11, []))
        let store: [[UInt8]] = [
            PB.message(2, PB.bytes(1, uuidA) + emptyTitle),
            PB.message(2, PB.bytes(1, uuidB) + emptyTitle),
            PB.message(3, tree),
        ]
        let document =
            PB.message(
                1, PB.bytes(1, doc) + PB.message(2, PB.message(1, store.reduce([], +))))
        let archive = TestZip.archive(entries: [
            ("Metadata.json", MindNodeSyntheticFile.metadata()),
            ("Contents.data", Data(document)),
        ])
        // The cycle collapses to two nodes; the point is the import
        // terminates at all.
        let model = try importArchive(archive)
        #expect(model.nodes.count == 2)
        #expect(MapValidator.validate(model).isEmpty)
    }

    // MARK: the real file (opt-in)

    @Test func realMindNodeFileImportsWhenProvided() throws {
        guard
            let path = ProcessInfo.processInfo.environment["ARBOR_REAL_MINDNODE"]
        else {
            print("ARBOR_REAL_MINDNODE not set — skipping the real-file import")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let model = try importArchive(data)
        #expect(!model.roots.isEmpty)
        #expect(MapValidator.validate(model).isEmpty)
        // The exact outline MindNode displays for this document (its
        // screenshot): root children [4th, 2nd, 3rd] top to bottom,
        // '2nd' children [(empty), 2b, 2c], '2c' carrying the floating
        // text '3t6782t2', '3rd' carrying '3a' — reproduced by sorting
        // each sibling list on the record's position key.
        let printed = outline(model)
        print("Real-file import outline:\n\(printed)")
        #expect(
            printed == """
                My own thought 1
                  4th thought
                  2nd thought
                    «empty»
                    2b
                    2c
                      3t6782t2
                  3rd thought
                    3a
                """)
    }
}
