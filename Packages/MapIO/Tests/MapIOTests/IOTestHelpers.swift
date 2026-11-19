import Foundation
import MapCore
import Testing

@testable import MapIO

/// The canonical projection used by every round-trip test: the tree of
/// fields, with format-native ids stripped — an export→import result
/// must equal the source modulo exactly the lossy fields each format
/// documents (docs/io/format-matrix.md), applied by the per-format
/// `for…` transforms below.
struct CanonicalNode: Equatable, Sendable {
    var title: String
    var note: String?
    var task: NodeTask?
    var tagNames: [String]
    var structure: String?
    var folded: Bool
    var side: SidePin?
    var link: String?
    var children: [CanonicalNode] = []
}

struct CanonicalConnection: Equatable, Sendable {
    var from: String
    var to: String
    var label: String?
}

struct CanonicalDoc: Equatable, Sendable {
    var title: String?
    var roots: [CanonicalNode]
    var connections: [CanonicalConnection]
}

/// Builds the canonical projection of a `MapModel`. Connections are
/// resolved through node *titles* (unique in every sample here).
func canonicalDoc(_ model: MapModel) -> CanonicalDoc {
    func node(_ id: String) -> CanonicalNode? {
        guard let source = model.nodes[id] else { return nil }
        return CanonicalNode(
            title: source.title.text,
            note: source.note,
            task: source.task,
            tagNames: (source.tags ?? []).compactMap { tagID in
                model.tags?.first { $0.id == tagID }?.name
            },
            structure: source.structure,
            folded: source.folded,
            side: source.side,
            link: source.link,
            children: source.children.compactMap(node))
    }
    let connections = (model.connections ?? []).compactMap { connection -> CanonicalConnection? in
        guard
            let from = model.nodes[connection.from]?.title.text,
            let to = model.nodes[connection.to]?.title.text
        else { return nil }
        return CanonicalConnection(from: from, to: to, label: connection.label)
    }
    return CanonicalDoc(
        title: model.title, roots: model.roots.compactMap(node), connections: connections)
}

extension CanonicalDoc {
    /// Applies `transform` to every node, keeping the tree shape.
    private func mappingNodes(_ transform: (CanonicalNode) -> CanonicalNode) -> CanonicalDoc {
        func walk(_ node: CanonicalNode) -> CanonicalNode {
            var copy = transform(node)
            copy.children = node.children.map(walk)
            return copy
        }
        return CanonicalDoc(title: title, roots: roots.map(walk), connections: connections)
    }

    /// OPML keeps tasks (done/due/priority), tags by name, structure and
    /// folded; it carries no side pins, links or connections.
    func forOPML() -> CanonicalDoc {
        mappingNodes { node in
            var copy = node
            copy.side = nil
            copy.link = nil
            return copy
        }
        .withoutConnections()
    }

    /// Markdown keeps titles (with the §8.3 inline allow-list), notes and
    /// task doneness; it carries no document title, tags, structure,
    /// folded, side, links, connections or task extras.
    func forMarkdown() -> CanonicalDoc {
        mappingNodes { node in
            var copy = node
            copy.task = node.task.map { NodeTask(done: $0.done) }
            copy.tagNames = []
            copy.structure = nil
            copy.folded = false
            copy.side = nil
            copy.link = nil
            return copy
        }
        .withoutConnections(title: false)
    }

    /// Plain indented text keeps only the hierarchy and flat titles.
    func forPlainText() -> CanonicalDoc {
        mappingNodes { node in
            var copy = node
            copy.note = nil
            copy.task = nil
            copy.tagNames = []
            copy.structure = nil
            copy.folded = false
            copy.side = nil
            copy.link = nil
            return copy
        }
        .withoutConnections(title: false)
    }

    /// FreeMind keeps the OPML field set plus side pins, links and
    /// (unlabeled) connections; it carries no document title.
    func forFreeMind() -> CanonicalDoc {
        CanonicalDoc(
            title: nil, roots: roots,
            connections: connections.map { connection in
                var copy = connection
                copy.label = nil
                return copy
            })
    }

    private func withoutConnections(title keepTitle: Bool = true) -> CanonicalDoc {
        CanonicalDoc(title: keepTitle ? title : nil, roots: roots, connections: [])
    }
}

// MARK: - Shared sample document

/// The sample document every golden export and round trip uses: two
/// roots, CJK + emoji titles, multi-line notes, inline runs, tasks,
/// tags, structure, folded state, a side pin, a link and a connection.
enum IOSamples {
    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    static func richSample() -> MapModel {
        var model = MapModel.emptyDocument(docID: "sample-doc")
        model.title = "Roadmap 研究"
        model.tags = [
            Tag(id: "tag-alpha", name: "alpha", color: "#E5484D"),
            Tag(id: "tag-urgent", name: "高优先", color: "#30A46C"),
        ]
        add(
            &model, "r1", parent: nil, title: "产品 Vision 🚀", note: "Line one\nLine two",
            tagNames: ["alpha"])
        add(
            &model, "a1", parent: "r1", title: "Bold move",
            runs: [Run(range: [0, 4], bold: true)], task: NodeTask(done: true))
        add(
            &model, "a2", parent: "r1", title: "Ship docs", note: "Needs a home\nand a date",
            task: NodeTask(done: false, due: "2026-12-01", priority: 1), folded: true,
            tagNames: ["高优先", "alpha"], side: .left)
        add(&model, "a2a", parent: "a2", title: "中文节点 🈶")
        add(&model, "a2b", parent: "a2", title: "Second child")
        add(&model, "r2", parent: nil, title: "Research 📚")
        add(&model, "c1", parent: "r2", title: "Paper link", link: "https://example.com/paper")
        model.roots = ["r1", "r2"]
        model.nodes["r1"]?.structure = "mindmap.balanced"
        model.connections = [
            Connection(id: "conn-1", from: "r1", to: "c1", label: "blocks")
        ]
        return model
    }

    private static func add(
        _ model: inout MapModel, _ id: String, parent: String?, title: String,
        runs: [Run] = [], note: String? = nil, task: NodeTask? = nil, folded: Bool = false,
        tagNames: [String] = [], side: SidePin? = nil, link: String? = nil
    ) {
        let tagIDs = tagNames.compactMap { name in
            model.tags?.first { $0.name == name }?.id
        }
        model.nodes[id] = Node(
            id: id, parent: parent, title: NodeTitle(text: title, runs: runs), note: note,
            folded: folded, link: link,
            tags: tagIDs.isEmpty ? nil : tagIDs, task: task,
            created: fixedDate, modified: fixedDate)
        model.nodes[id]?.side = side
        if let parent {
            model.nodes[parent]?.children.append(id)
        }
    }

    /// A tree for the performance test: `count` nodes, fan-out 4,
    /// breadth-first.
    static func bigTree(nodeCount: Int) -> MapModel {
        var model = MapModel.emptyDocument(docID: "big-tree")
        var counter = 0
        var queue: [String] = []
        var roots: [String] = []

        func make(parent: String?) {
            counter += 1
            let id = "node-\(counter)"
            model.nodes[id] = Node(
                id: id, parent: parent, title: NodeTitle(text: "Node \(counter) 深度"),
                created: fixedDate, modified: fixedDate)
            if let parent {
                model.nodes[parent]?.children.append(id)
            } else {
                roots.append(id)
            }
            queue.append(id)
        }

        make(parent: nil)
        while counter < nodeCount, !queue.isEmpty {
            let parent = queue.removeFirst()
            for _ in 0..<4 where counter < nodeCount {
                make(parent: parent)
            }
        }
        model.roots = roots
        return model
    }
}

// MARK: - Fixture access

extension Node {
    /// The declared tag names referenced by this node.
    func tagNames(_ model: MapModel) -> [String] {
        (tags ?? []).compactMap { tagID in
            model.tags?.first { $0.id == tagID }?.name
        }
    }
}

extension String {
    /// Fixture files end with a trailing newline; exporters do not emit
    /// one, so golden comparisons trim it.
    var trimmingTrailingNewline: String {
        hasSuffix("\n") ? String(dropLast()) : self
    }

    /// The non-empty lines, for structural assertions on exported text.
    var lines: [Substring] {
        split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
    }
}

enum Fixtures {
    /// Reads `Fixtures/<subdirectory>/<name>.<fileExtension>` from the
    /// test bundle.
    static func data(_ subdirectory: String, _ name: String, _ fileExtension: String) throws
        -> Data
    {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: fileExtension,
                subdirectory: "Fixtures/\(subdirectory)"))
        return try Data(contentsOf: url)
    }

    /// `data` as UTF-8 text.
    static func text(_ subdirectory: String, _ name: String, _ fileExtension: String) throws
        -> String
    {
        let rawData = try self.data(subdirectory, name, fileExtension)
        return try #require(String(data: rawData, encoding: .utf8))
    }
}

// MARK: - Hand-built zip bytes (MiniZip tests)

/// Builds a minimal STORED-method zip in memory, so malformed-archive
/// tests need no binary fixtures.
enum TestZip {
    static func archive(entries: [(name: String, data: Data)]) -> Data {
        var bytes: [UInt8] = []
        var central: [UInt8] = []
        var offsets: [Int] = []

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            offsets.append(bytes.count)
            bytes.append(
                contentsOf: localHeader(
                    crc: crc32(entry.data), size: UInt32(entry.data.count),
                    nameLength: UInt16(nameBytes.count)))
            bytes.append(contentsOf: nameBytes)
            bytes.append(contentsOf: entry.data)
        }
        let directoryStart = bytes.count
        for (index, entry) in entries.enumerated() {
            let nameBytes = Array(entry.name.utf8)
            central.append(
                contentsOf: centralHeader(
                    crc: crc32(entry.data), size: UInt32(entry.data.count),
                    nameLength: UInt16(nameBytes.count), offset: UInt32(offsets[index])))
            central.append(contentsOf: nameBytes)
        }
        bytes.append(contentsOf: central)
        bytes.append(
            contentsOf: endRecord(
                entries: UInt16(entries.count), directorySize: UInt32(central.count),
                directoryOffset: UInt32(directoryStart)))
        return Data(bytes)
    }

    private static func localHeader(crc: UInt32, size: UInt32, nameLength: UInt16) -> [UInt8] {
        var header = little32(0x0403_4b50)
        header += little16(20)  // version needed
        header += little16(0)  // flags
        header += little16(0)  // method: stored
        header += little16(0) + little16(0x5bc0)  // fixed DOS time/date
        header += little32(crc)
        header += little32(size)  // compressed size
        header += little32(size)  // uncompressed size
        header += little16(nameLength)
        header += little16(0)  // extra length
        return header
    }

    private static func centralHeader(
        crc: UInt32, size: UInt32, nameLength: UInt16, offset: UInt32
    ) -> [UInt8] {
        var header = little32(0x0201_4b50)
        header += little16(20)  // version made by
        header += little16(20)  // version needed
        header += little16(0)  // flags
        header += little16(0)  // method: stored
        header += little16(0) + little16(0x5bc0)  // fixed DOS time/date
        header += little32(crc)
        header += little32(size)
        header += little32(size)
        header += little16(nameLength)
        header += little16(0)  // extra
        header += little16(0)  // comment
        header += little16(0)  // disk number
        header += little16(0)  // internal attributes
        header += little32(0)  // external attributes
        header += little32(offset)
        return header
    }

    private static func endRecord(
        entries: UInt16, directorySize: UInt32, directoryOffset: UInt32
    ) -> [UInt8] {
        var record = little32(0x0605_4b50)
        record += little16(0) + little16(0)  // disk numbers
        record += little16(entries) + little16(entries)
        record += little32(directorySize)
        record += little32(directoryOffset)
        record += little16(0)  // comment length
        return record
    }

    private static func little32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { shift in
            UInt8((value >> UInt32(8 * shift)) & 0xFF)
        }
    }

    private static func little16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    /// CRC-32 (IEEE, reflected 0xEDB88320), matching what MiniZip checks.
    static func crc32(_ data: Data) -> UInt32 {
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
}
