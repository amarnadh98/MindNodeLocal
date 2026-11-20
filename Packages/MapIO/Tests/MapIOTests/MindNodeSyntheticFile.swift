import Foundation

@testable import MapIO

/// Builds **synthetic** MindNode current-format documents in the exact
/// wire shape reverse-engineered from a real file (ADR-0035) — the
/// same field numbers, the same nested containers, wrapped in a
/// stored zip with `Metadata.json`. No personal file is ever copied
/// into the repo; every fixture the tests use is generated from this
/// helper.
///
/// Mirrors `scripts/generate_mindnode_fixture.swift`, which produced
/// the one committed binary fixture
/// (`Fixtures/mindnode/synthetic-current.mindnode`) the hosted app
/// test opens — the golden test reading that file guards the two
/// against drift.
enum MindNodeSyntheticFile {
    /// One node: title, an optional note, whether it rides the tree's
    /// detached list, and ordered children.
    struct Node {
        var title: String
        var note: String? = nil
        var detached: Bool = false
        var children: [Node] = []

        init(
            _ title: String, note: String? = nil, detached: Bool = false,
            children: [Node] = []
        ) {
            self.title = title
            self.note = note
            self.detached = detached
            self.children = children
        }
    }

    /// One walked node: its wire uuid, parent uuid and spec.
    private struct Entry {
        let uuid: [UInt8]
        let parent: [UInt8]?
        let node: Node
        let childUUIDs: [[UInt8]]
    }

    /// The committed golden fixture's map: a root with two ordered
    /// branches, an empty node, a titled "floating text" node, and a
    /// detached empty node MindNode's own outline would not show.
    static let goldenMap = Node(
        "Golden Root",
        children: [
            .init(
                "First branch",
                children: [
                    .init("Child one", note: "a note rides along"),
                    .init(""),
                ]),
            .init(
                "Second branch",
                children: [
                    .init("Floating text"),
                    .init("", detached: true),
                ]),
        ])

    private static let documentUUID: [UInt8] = Array(repeating: 0xAB, count: 16)
    private static let styleUUID: [UInt8] = Array(repeating: 0x5A, count: 16)

    /// Serializes `root` as the current format's `Contents.data`:
    /// field 1 → document message (1: document uuid, 2: content
    /// wrapper → 1: node store) — the exact shape the real files use.
    static func contentsData(root: Node) -> Data {
        let entries = walk(root)
        let records =
            entries
            .sorted { $0.uuid.lexicographicallyPrecedes($1.uuid) }
            .map { entry in
                PB.message(2, PB.bytes(1, entry.uuid) + PB.message(2, nodeData(entry.node)))
            }
        let store = records + [PB.message(3, tree(entries: entries))]
        let wrapper = PB.message(1, store.reduce([], +))
        let document = PB.message(1, PB.bytes(1, documentUUID) + PB.message(2, wrapper))
        return Data(document)
    }

    /// `Metadata.json` bytes.
    static func metadata(
        minVersion: Int = MindNodeCurrentFormat.supportedMinFileFormatVersionForReading,
        appVersion: String = "2026.7.2-test"
    ) -> Data {
        let json = """
            {
              "exportAppVersion" : "\(appVersion)",
              "fileFormatVersion" : 1,
              "minFileFormatVersionForReading" : \(minVersion),
              "originalDocumentID" : "0A0B0C0D-0000-4000-8000-000000000001"
            }
            """
        return Data(json.utf8)
    }

    /// A whole synthetic `.mindnode`: a stored zip with
    /// `Contents.data` + `Metadata.json` (+ a stub preview entry,
    /// like the real files).
    static func archive(
        root: Node = goldenMap,
        minVersion: Int = MindNodeCurrentFormat.supportedMinFileFormatVersionForReading
    ) -> Data {
        TestZip.archive(entries: [
            ("Metadata.json", metadata(minVersion: minVersion)),
            ("Contents.data", contentsData(root: root)),
            ("Preview_thumbnail_light.jpeg", Data([0xFF, 0xD8, 0xFF])),
        ])
    }

    // MARK: - wire serialization (the schema under test)

    /// Walks the tree in pre-order, assigning a deterministic
    /// 16-byte uuid counter to every node (the root is always
    /// `entries.first`).
    private static func walk(_ root: Node) -> [Entry] {
        final class Info {
            let node: Node
            let parent: [UInt8]?
            var childUUIDs: [[UInt8]] = []
            init(node: Node, parent: [UInt8]?) {
                self.node = node
                self.parent = parent
            }
        }
        var counter = 1
        func nextUUID() -> [UInt8] {
            defer { counter += 1 }
            return (0..<16).map { position in
                UInt8((counter >> (8 * position)) & 0xFF)
            }
        }
        var infos: [[UInt8]: Info] = [:]
        var order: [[UInt8]] = []
        func visit(_ node: Node, parent: [UInt8]?) -> [UInt8] {
            let id = nextUUID()
            order.append(id)
            let info = Info(node: node, parent: parent)
            infos[id] = info
            info.childUUIDs = node.children.map { visit($0, parent: id) }
            return id
        }
        _ = visit(root, parent: nil)
        return order.map { id in
            let info = infos[id]!
            return Entry(
                uuid: id, parent: info.parent, node: info.node, childUUIDs: info.childUUIDs)
        }
    }

    /// One node's data message: the guessed note container (field 2),
    /// the title container (field 11) and the empty placeholders a
    /// real file carries (9/12 empty messages, 7/13 varints).
    private static func nodeData(_ node: Node) -> [UInt8] {
        var body: [UInt8] = []
        body += PB.message(2, node.note.map(attributedString(_:)) ?? [])
        body += PB.varint(7, 0)
        body += PB.message(9, [])
        if node.title.isEmpty {
            body += PB.message(11, [])
        } else {
            body += PB.message(11, attributedString(node.title) + PB.bytes(10, styleUUID))
        }
        body += PB.message(12, [])
        body += PB.varint(13, 0)
        return body
    }

    /// The tree container: the document's own record (children =
    /// roots, in order), one record per node with its parent and
    /// ordered children, the detached list, and the redundant
    /// top-level branch list.
    private static func tree(entries: [Entry]) -> [UInt8] {
        let rootUUID = entries.first?.uuid ?? []
        var body = PB.bytes(1, documentUUID)
        body += PB.message(2, PB.bytes(1, documentUUID) + PB.bytes(3, rootUUID))
        for entry in entries {
            var record = PB.bytes(1, entry.uuid)
            if let parent = entry.parent {
                record += PB.bytes(2, parent)
            }
            for child in entry.childUUIDs {
                record += PB.bytes(3, child)
            }
            body += PB.message(2, record)
        }
        for entry in entries where entry.node.detached {
            body += PB.bytes(3, entry.uuid)
        }
        body += PB.bytes(4, rootUUID)
        return body
    }

    /// An attributed string as the real files shape it: `1` → string
    /// value message → `1` → UTF-8 bytes, plus the 2/3 varints every
    /// title carries.
    private static func attributedString(_ text: String) -> [UInt8] {
        PB.message(
            1,
            PB.message(1, []) + PB.varint(2, 0) + PB.varint(3, 1)
                + PB.message(4, PB.bytes(1, Array(text.utf8))))
    }
}

/// The protobuf wire writer the fixture builder needs — the exact
/// inverse of `ProtobufWire`, with the field numbers supplied by the
/// caller.
enum PB {
    static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var out: [UInt8] = [UInt8(remaining & 0x7F)]
        remaining >>= 7
        while remaining != 0 {
            out[out.count - 1] |= 0x80
            out.append(UInt8(remaining & 0x7F))
            remaining >>= 7
        }
        return out
    }

    private static func key(_ field: Int, wireType: UInt8) -> [UInt8] {
        varint(UInt64(field << 3 | Int(wireType)))
    }

    static func varint(_ field: Int, _ value: UInt64) -> [UInt8] {
        key(field, wireType: 0) + varint(value)
    }

    static func double(_ field: Int, _ value: Double) -> [UInt8] {
        key(field, wireType: 1) + withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }

    static func bytes(_ field: Int, _ data: [UInt8]) -> [UInt8] {
        key(field, wireType: 2) + varint(UInt64(data.count)) + data
    }

    static func message(_ field: Int, _ body: [UInt8]) -> [UInt8] {
        bytes(field, body)
    }
}
