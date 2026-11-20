import Foundation
import MapCore

/// Decodes the **current MindNode format** (MindNode 2026, file format
/// version 1): a stored zip whose `Contents.data` entry is an
/// *undocumented* Protocol Buffers stream, reverse-engineered from a
/// real file (ADR-0035 — every field below is labelled confirmed or
/// guessed there; the format has no public specification, and MindNode
/// may change it in any release).
///
/// The observed layout, with the field paths this decoder reads:
///
/// - `1` → document: `1` = 16-byte document UUID (matches
///   `Metadata.json`'s `originalDocumentID` — confirmed);
///   `2` → content wrapper → `1` → node store.
/// - node store: repeated `2` = one record per node, a protobuf map
///   keyed by UUID: `1` = 16-byte node UUID, `2` = node data.
/// - node data: `11` → title container → `1` → attributed string →
///   `4` → string value → `1` = the UTF-8 title (confirmed; an empty
///   container is an untitled node — MindNode keeps such nodes).
///   Field `2` is *guessed* to be the note's attributed string in one
///   of the two shapes the title can take — the sample's copies are
///   all empty, so the note is extracted defensively and simply yields
///   nothing if the guess is wrong.
/// - node store `3` → tree container: `1` = the document UUID;
///   repeated `2` = one record per subject (protobuf map, UUID-keyed):
///   `1` = subject UUID, `2` = parent UUID (the root's parent is the
///   document itself; a record without `2` is the document's own
///   record), repeated `3` = the subject's children **in order**
///   (confirmed — order is data), `4` = branch style (ignored);
///   repeated `3` at container level = detached node UUIDs (below);
///   repeated `4` = top-level branch list (mirrors the root's
///   children; redundant, ignored).
///
/// Nodes whose UUID appears in the tree container's detached list are
/// *excluded* from the assembled tree: in the reverse-engineered
/// sample they are exactly the nodes MindNode's own outline does not
/// show, and excluding them reproduces that outline. The field's exact
/// semantics are unconfirmed — ADR-0035 records the evidence.
///
/// Fields present in the sample but unmapped (safely ignored): node
/// data `5` (two doubles — a position or size override), `6`/`10` (a
/// width), `7` (a small enum), `9`, `12`, `13`; the sticker container
/// (node store `5` — an "Important" sticker with an RGBA color,
/// attached to no node in the sample); the node store `4` varint; and
/// the 32-byte digest plus timestamped session block wrapped around
/// the content. Notes, tasks, tags, folding and connections could not
/// be confirmed from the sample and are not extracted from this
/// format (the legacy-plist importer keeps supporting them for
/// MindNode 1-2 files).
///
/// Pure logic: `Foundation` + `MapCore`, no AppKit (SPEC §11.2).
enum MindNodeCurrentFormat {
    /// The highest `minFileFormatVersionForReading` this decoder
    /// understands; `Metadata.json` declares what a reader must
    /// support. Bump (and re-verify against a real file) when a newer
    /// MindNode format is reverse-engineered.
    static let supportedMinFileFormatVersionForReading = 1

    /// `Metadata.json`: the reader-facing version gate plus the
    /// provenance Arbor's error messages can quote.
    struct Metadata: Sendable, Equatable {
        var exportAppVersion: String?
        var fileFormatVersion: Int?
        var minFileFormatVersionForReading: Int?
    }

    static func parseMetadata(_ data: Data) throws -> Metadata {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentIOError.malformed(
                format: Self.id, reason: "Metadata.json is not readable JSON")
        }
        return Metadata(
            exportAppVersion: top["exportAppVersion"] as? String,
            fileFormatVersion: (top["fileFormatVersion"] as? NSNumber)?.intValue,
            minFileFormatVersionForReading: (top["minFileFormatVersionForReading"] as? NSNumber)?.intValue)
    }

    /// Decodes `Contents.data` into a validated `MapModel`. Throws
    /// `DocumentIOError` — never traps, whatever the bytes.
    static func importContents(_ data: Data) throws -> MapModel {
        do {
            return try decode(data)
        } catch is ProtobufWire.ProtobufError {
            // Any wire-level failure anywhere in the walk — the
            // schema decode only descends fields it expects, so this
            // means the bytes are not the layout this decoder knows.
            throw DocumentIOError.malformed(
                format: Self.id, reason: "Contents.data is not decodable protobuf")
        }
    }

    private static func decode(_ data: Data) throws -> MapModel {
        let fields: [ProtobufWire.Field]
        do {
            fields = try ProtobufWire.parse(data)
        } catch {
            throw DocumentIOError.malformed(
                format: Self.id, reason: "Contents.data is not decodable protobuf")
        }
        // document → content wrapper → node store
        guard
            let document = try fields.message(1),
            let content = try document.message(2),
            let store = try content.message(1)
        else {
            throw DocumentIOError.malformed(
                format: Self.id, reason: "Contents.data has no MindNode content structure")
        }

        // 1. Node records: a UUID-keyed map of titles (and the
        //    guessed note extraction).
        var nodes: [String: DocumentBox] = [:]
        for record in store.all(2) {
            guard let entry = try Self.fields(of: record) else { continue }
            guard
                case .delimited(let key, _)? = entry.first(1)?.value,
                let data = try entry.message(2),
                let id = Self.uuidString(key)
            else { continue }
            let box = DocumentBox(
                title: NodeTitle(text: (try? Self.text(in: data, field: 11)) ?? ""))
            box.externalID = id
            box.note = try? Self.text(in: data, field: 2)
            nodes[id] = box
        }
        guard !nodes.isEmpty else {
            throw DocumentIOError.malformed(
                format: Self.id, reason: "the document carries no nodes")
        }

        // 2. Tree records: subject → ordered children.
        guard let tree = try store.message(3) else {
            throw DocumentIOError.malformed(
                format: Self.id, reason: "the document carries no node tree")
        }
        let documentID = tree.bytes(1).flatMap(Self.uuidString(_:))
        var parents: [String: String] = [:]
        var children: [String: [String]] = [:]
        var roots: [String] = []
        var documentChildren: [String]? = nil
        for record in tree.all(2) {
            guard
                let recordFields = try Self.fields(of: record),
                let subject = recordFields.bytes(1).flatMap(Self.uuidString(_:))
            else {
                continue
            }
            children[subject] = recordFields.all(3).compactMap { field in
                guard case .delimited(let id, _) = field.value else { return nil }
                return Self.uuidString(id)
            }
            if let parent = recordFields.bytes(2).flatMap(Self.uuidString(_:)) {
                parents[subject] = parent
            } else if nodes[subject] != nil, subject != documentID {
                // A node record without a parent is its own root.
                roots.append(subject)
            } else {
                // The document's own record: no parent, no node data;
                // its children are the map's roots, in order.
                documentChildren = children[subject]
            }
        }
        // Root order prefers the document record's child list, then
        // the parent-of-document set, then the no-parent fallback.
        if let listed = documentChildren, !listed.isEmpty {
            roots = listed
        } else if roots.isEmpty, let documentID {
            roots = parents.filter { $0.value == documentID }.keys.map { $0 }
        }
        // Detached nodes (container-level repeated field 3): excluded
        // from the tree, exactly as MindNode's outline excludes them.
        let detached = Set(
            tree.all(3).compactMap { field -> String? in
                guard case .delimited(let id, _) = field.value else { return nil }
                return Self.uuidString(id)
            })

        // 3. Assemble. The visited set makes a cyclic or duplicated
        //    tree record harmless — this is untrusted input.
        let assembler = DocumentAssembler(title: nil)
        var visited = Set<String>()
        func assemble(_ id: String) -> DocumentBox? {
            guard !visited.contains(id) else { return nil }
            visited.insert(id)
            let box = nodes[id] ?? DocumentBox(title: NodeTitle(text: ""))
            box.externalID = id
            for child in children[id] ?? [] where !detached.contains(child) {
                if let childBox = assemble(child) {
                    box.children.append(childBox)
                }
            }
            return box
        }
        var assembledRoots = 0
        for root in roots where !detached.contains(root) {
            if let box = assemble(root) {
                assembler.addRoot(box)
                assembledRoots += 1
            }
        }
        guard assembledRoots > 0 else {
            throw DocumentIOError.emptyDocument(format: Self.id)
        }
        return assembler.result
    }

    // MARK: schema helpers

    private static let id = DocumentFormats.mindnode.id

    /// The plain text of a MindNode string container: the container
    /// message (`field`) wraps an attributed string (`1`), whose
    /// string value rides in `4` → `1` as UTF-8 bytes. For the note
    /// the attributed string is also accepted bare (the field itself
    /// being the attributed string), because the sample cannot confirm
    /// which shape a note actually takes — both parse, everything else
    /// yields nil.
    private static func text(in data: [ProtobufWire.Field], field: Int) throws -> String? {
        guard let container = try data.message(field) else { return nil }
        if let attributed = try container.message(1),
            let value = try attributed.message(4),
            let wrapped = value.text(1)
        {
            return wrapped
        }
        if let value = try container.message(4), let bare = value.text(1) {
            return bare
        }
        return nil
    }

    /// Renders 16 UUID bytes in the canonical 8-4-4-4-12 form. A
    /// non-16-byte payload becomes a stable hex string, so even a
    /// damaged id never aliases a real one silently.
    private static func uuidString(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count == 16 else {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let raw = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: raw).uuidString
    }

    /// The fields *inside* a map-entry record (the entry's `1` = key,
    /// `2` = value…), from the auto-parsed nesting when present and a
    /// fresh parse otherwise.
    private static func fields(of record: ProtobufWire.Field) throws -> [ProtobufWire.Field]? {
        guard case .delimited(let data, let nested) = record.value else { return nil }
        if let nested { return nested }
        return try? ProtobufWire.parse(data)
    }
}
