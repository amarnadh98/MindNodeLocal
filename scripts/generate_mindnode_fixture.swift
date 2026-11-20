#!/usr/bin/env swift
// Generates the committed synthetic MindNode current-format fixture
// (ADR-0035): Packages/MapIO/Tests/MapIOTests/Fixtures/mindnode/
// synthetic-current.mindnode — a stored zip wrapping a hand-serialized
// protobuf message tree with the field numbers reverse-engineered
// from a real MindNode 2026 file. No personal document is ever
// committed; this map is Arbor's own.
//
// Usage: swift scripts/generate_mindnode_fixture.swift [output.mindnode]
//
// Mirrors MindNodeSyntheticFile in the MapIO test target — the golden
// test that reads the committed file guards the two against drift.

import Foundation

// MARK: protobuf wire writer

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

    static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] {
        key(field, wireType: 0) + varint(value)
    }

    static func bytesField(_ field: Int, _ data: [UInt8]) -> [UInt8] {
        key(field, wireType: 2) + varint(UInt64(data.count)) + data
    }

    static func messageField(_ field: Int, _ body: [UInt8]) -> [UInt8] {
        bytesField(field, body)
    }
}

// MARK: the synthetic map (same tree as MindNodeSyntheticFile.goldenMap)

struct Node {
    let title: String
    let note: String?
    let detached: Bool
    let children: [Node]

    init(_ title: String, note: String? = nil, detached: Bool = false, children: [Node] = []) {
        self.title = title
        self.note = note
        self.detached = detached
        self.children = children
    }
}

let goldenMap = Node(
    "Golden Root", children: [
        .init("First branch", children: [
            .init("Child one", note: "a note rides along"),
            .init(""),
        ]),
        .init("Second branch", children: [
            .init("Floating text"),
            .init("", detached: true),
        ]),
    ])

let documentUUID = [UInt8](repeating: 0xAB, count: 16)
let styleUUID = [UInt8](repeating: 0x5A, count: 16)

struct Entry {
    let uuid: [UInt8]
    let parent: [UInt8]?
    let node: Node
    let childUUIDs: [[UInt8]]
    /// The record's `4 → 1 → 2` varint: MindNode's display-order key
    /// (default 200, ×2 insert-after, ÷2 insert-before; 50 for
    /// detached, as in the real file). ADR-0035.
    let position: UInt64
}

func walk(_ root: Node) -> [Entry] {
    final class Info {
        let node: Node
        let parent: [UInt8]?
        let position: UInt64
        var childUUIDs: [[UInt8]] = []
        init(node: Node, parent: [UInt8]?, position: UInt64) {
            self.node = node
            self.parent = parent
            self.position = position
        }
    }
    var infos: [[UInt8]: Info] = [:]
    var order: [[UInt8]] = []
    var counter = 1
    func nextUUID() -> [UInt8] {
        defer { counter += 1 }
        return (0..<16).map { UInt8((counter >> (8 * $0)) & 0xFF) }
    }
    // UUIDs are handed out with children visited in REVERSE visual
    // order, so the wire's protobuf map order differs from the
    // display order — the exact property the real file has, and the
    // trap the importer must see through.
    func visit(_ node: Node, parent: [UInt8]?, siblingIndex: Int) -> [UInt8] {
        let id = nextUUID()
        order.append(id)
        let position = node.detached ? 50 : UInt64(200 << siblingIndex)
        let info = Info(node: node, parent: parent, position: position)
        infos[id] = info
        let reversedChildren = node.children.enumerated().reversed().map { pair in
            visit(pair.element, parent: id, siblingIndex: pair.offset)
        }
        info.childUUIDs = Array(reversedChildren.reversed())
        return id
    }
    _ = visit(root, parent: nil, siblingIndex: 0)
    return order.map { id in
        let info = infos[id]!
        return Entry(
            uuid: id, parent: info.parent, node: info.node,
            childUUIDs: info.childUUIDs, position: info.position)
    }
}

func attributedString(_ text: String) -> [UInt8] {
    PB.messageField(
        1,
        PB.messageField(1, []) + PB.varintField(2, 0) + PB.varintField(3, 1)
            + PB.messageField(4, PB.bytesField(1, Array(text.utf8))))
}

func nodeData(_ node: Node) -> [UInt8] {
    var body: [UInt8] = []
    body += PB.messageField(2, node.note.map(attributedString) ?? [])
    body += PB.varintField(7, 0)
    body += PB.messageField(9, [])
    if node.title.isEmpty {
        body += PB.messageField(11, [])
    } else {
        body += PB.messageField(11, attributedString(node.title) + PB.bytesField(10, styleUUID))
    }
    body += PB.messageField(12, [])
    body += PB.varintField(13, 0)
    return body
}

func tree(_ entries: [Entry]) -> [UInt8] {
    let rootUUID = entries[0].uuid
    var body = PB.bytesField(1, documentUUID)
    body += PB.messageField(2, PB.bytesField(1, documentUUID) + PB.bytesField(3, rootUUID))
    // Records in UUID (protobuf map) order, like the real file — NOT
    // display order; the `4 → 1 → 2` position key orders siblings.
    for entry in entries.sorted(by: { $0.uuid.lexicographicallyPrecedes($1.uuid) }) {
        var record = PB.bytesField(1, entry.uuid)
        if let parent = entry.parent {
            record += PB.bytesField(2, parent)
        }
        for child in entry.childUUIDs.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            record += PB.bytesField(3, child)
        }
        record += PB.messageField(
            4, PB.messageField(1, PB.bytesField(1, styleUUID) + PB.varintField(2, entry.position)))
        body += PB.messageField(2, record)
    }
    for entry in entries where entry.node.detached {
        body += PB.bytesField(3, entry.uuid)
    }
    body += PB.bytesField(4, rootUUID)
    return body
}

func contentsData(_ root: Node) -> Data {
    let entries = walk(root)
    let records = entries
        .sorted { $0.uuid.lexicographicallyPrecedes($1.uuid) }
        .map { PB.messageField(2, PB.bytesField(1, $0.uuid) + PB.messageField(2, nodeData($0.node))) }
    let store = records + [PB.messageField(3, tree(entries))]
    let wrapper = PB.messageField(1, store.reduce([], +))
    // Field 1 → document message (1: uuid, 2: wrapper) — the exact
    // shape the real files use.
    let document = PB.messageField(1, PB.bytesField(1, documentUUID) + PB.messageField(2, wrapper))
    return Data(document)
}

let metadata = """
    {
      "exportAppVersion" : "2026.7.2-fixture",
      "fileFormatVersion" : 1,
      "minFileFormatVersionForReading" : 1,
      "originalDocumentID" : "ABABABAB-ABAB-4ABA-8ABA-ABABABABABAB"
    }
    """

// MARK: stored-zip writer (local header + central directory + EOCD)

func crc32(_ data: Data) -> UInt32 {
    let table: [UInt32] = (0..<256).map { value in
        var cell = UInt32(value)
        for _ in 0..<8 {
            cell = (cell & 1) != 0 ? (cell >> 1) ^ 0xEDB8_8320 : cell >> 1
        }
        return cell
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
    }
    return crc ^ 0xFFFF_FFFF
}

func little16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
}

func little32(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8((value >> UInt32(8 * $0)) & 0xFF) }
}

func zip(entries: [(name: String, data: Data)]) -> Data {
    var bytes: [UInt8] = []
    var central: [UInt8] = []
    var offsets: [Int] = []
    for entry in entries {
        let nameBytes = Array(entry.name.utf8)
        offsets.append(bytes.count)
        bytes += little32(0x0403_4b50) + little16(20) + little16(0) + little16(0)
        bytes += little16(0) + little16(0x5BC0)
        bytes += little32(crc32(entry.data))
        bytes += little32(UInt32(entry.data.count)) + little32(UInt32(entry.data.count))
        bytes += little16(UInt16(nameBytes.count)) + little16(0)
        bytes += nameBytes
        bytes += Array(entry.data)
    }
    let directoryStart = bytes.count
    for (index, entry) in entries.enumerated() {
        let nameBytes = Array(entry.name.utf8)
        central += little32(0x0201_4b50) + little16(20) + little16(20) + little16(0)
        central += little16(0)  // method: stored
        central += little16(0) + little16(0x5BC0)
        central += little32(crc32(entry.data))
        central += little32(UInt32(entry.data.count)) + little32(UInt32(entry.data.count))
        central += little16(UInt16(nameBytes.count)) + little16(0) + little16(0)
        central += little16(0) + little16(0) + little32(0)
        central += little32(UInt32(offsets[index]))
        central += nameBytes
    }
    bytes += central
    bytes += little32(0x0605_4b50) + little16(0) + little16(0)
    bytes += little16(UInt16(entries.count)) + little16(UInt16(entries.count))
    bytes += little32(UInt32(central.count)) + little32(UInt32(directoryStart)) + little16(0)
    return Data(bytes)
}

// MARK: write the fixture

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Packages/MapIO/Tests/MapIOTests/Fixtures/mindnode/synthetic-current.mindnode")

let archive = zip(entries: [
    ("Metadata.json", Data(metadata.utf8)),
    ("Contents.data", contentsData(goldenMap)),
    ("Preview_thumbnail_light.jpeg", Data([0xFF, 0xD8, 0xFF])),
])
try archive.write(to: output)
print("Wrote \(output.path) (\(archive.count) bytes)")
