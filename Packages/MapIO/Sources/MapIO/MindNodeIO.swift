import Foundation
import MapCore

/// MindNode `.mindnode` import (F-IO, SPEC §5.17). Two layouts, chosen
/// by what the bytes turn out to be:
///
/// - **Legacy (MindNode 1-2):** a directory package whose
///   `contents.xml` is a *binary property list* (`importDocument(contentsXML:)`,
///   kept for packages and for callers that extracted the entry).
/// - **Current (MindNode 2026+, file format 1):** a stored ZIP with a
///   protobuf `Contents.data`, `Metadata.json` and preview images —
///   reverse-engineered in ADR-0035 and decoded by
///   `MindNodeCurrentFormat` (no third-party protobuf dependency).
///
/// `importDocument(archive:)` sniffs which: a readable zip with a
/// `Contents.data` entry goes down the current path (gated on
/// `Metadata.json`'s `minFileFormatVersionForReading`), a zip with
/// `contents.xml` down the legacy path, and anything that is not a
/// zip at all falls back to the legacy contract (the bytes *are* a
/// `contents.xml`). Importers never crash on malformed input: every
/// failure is a thrown `DocumentIOError` with the reason the error
/// sheet shows. There is no MindNode export.
///
/// Lossy fields (docs/io/format-matrix.md): node uuids, images,
/// per-node style overrides, MindNode-only layout state, tag colors,
/// task due-date precision beyond the ISO day, connection styles; the
/// current format's unmapped fields are listed in ADR-0035.
public enum MindNodeIO {
    /// The versions this importer understands (SPEC §14 mentions the v9
    /// binary-plist layout). Other versions get the OPML-fallback error.
    private static let supportedVersions: Set<String> = ["9"]

    private static let id = DocumentFormats.mindnode.id

    /// The current format's zip entries.
    private static let contentsEntry = "Contents.data"
    private static let metadataEntry = "Metadata.json"
    private static let legacyContentsEntry = "contents.xml"

    /// Imports a whole `.mindnode` file: the current format's zip
    /// archive, or — for the legacy package layout — the extracted
    /// `contents.xml` bytes (a non-zip input is that legacy contract).
    public static func importDocument(archive: Data) throws -> MapModel {
        if let entries = try? MiniZip.entries(of: archive) {
            let entry = { (name: String) -> Data? in
                entries.first { $0.name == name }?.data
            }
            if let contents = entry(contentsEntry) {
                return try importCurrentFormat(contents: contents, metadata: entry(metadataEntry))
            }
            if let legacy = entry(legacyContentsEntry) {
                return try importDocument(contentsXML: legacy)
            }
            throw DocumentIOError.malformed(
                format: id,
                reason: "the archive has neither \(contentsEntry) nor \(legacyContentsEntry) "
                    + "— it is not a MindNode document Arbor recognizes")
        }
        // Not a zip: the legacy contract — the bytes are the package's
        // `contents.xml` property list.
        return try importDocument(contentsXML: archive)
    }

    /// The current-format path: gate on `Metadata.json`, then decode
    /// the protobuf contents.
    private static func importCurrentFormat(contents: Data, metadata: Data?) throws -> MapModel {
        guard let metadata else {
            throw DocumentIOError.malformed(
                format: id,
                reason: "the package has \(contentsEntry) but no \(metadataEntry)")
        }
        let meta = try MindNodeCurrentFormat.parseMetadata(metadata)
        if let required = meta.minFileFormatVersionForReading,
            required > MindNodeCurrentFormat.supportedMinFileFormatVersionForReading
        {
            throw DocumentIOError.unsupportedVersion(
                format: id, found: String(required),
                hint: "This MindNode file uses a format Arbor can't read yet"
                    + " (it needs file format version \(required); Arbor understands version "
                    + "\(MindNodeCurrentFormat.supportedMinFileFormatVersionForReading))"
                    + " and MindNode "
                    + (meta.exportAppVersion.map { "version \($0) " } ?? "")
                    + "wrote it. Open it in MindNode and export it as OPML, "
                    + "then import the OPML file instead.")
        }
        return try MindNodeCurrentFormat.importContents(contents)
    }

    /// Parses the `contents.xml` bytes of a legacy `.mindnode` package into a
    /// validated `MapModel`. Throws `DocumentIOError` — unreadable
    /// plist, unknown version, no recognizable node tree.
    public static func importDocument(contentsXML plistData: Data) throws -> MapModel {
        let top: Any
        do {
            top = try PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil)
        } catch {
            throw DocumentIOError.malformed(
                format: id, reason: "contents.xml is not a readable property list")
        }
        guard let root = top as? [String: Any] else {
            throw DocumentIOError.malformed(
                format: id, reason: "contents.xml is not a property-list dictionary")
        }
        let version = stringify(root["formatVersion"] ?? root["version"])
        guard let version else {
            throw DocumentIOError.malformed(
                format: id, reason: "the property list has no version field")
        }
        guard supportedVersions.contains(version) else {
            throw DocumentIOError.unsupportedVersion(
                format: id, found: version,
                hint: "Open the document in MindNode and export it as OPML, then import the OPML file instead.")
        }
        let document = firstDictionary(root, keys: ["mindmapDocument", "document"]) ?? root
        let nodeDicts = firstArray(document, keys: ["rootNodes", "rootNode", "nodes"])
        guard let nodeDicts, !nodeDicts.isEmpty else {
            throw DocumentIOError.malformed(
                format: id,
                reason: "no root nodes found — the plist layout is not one Arbor recognizes")
        }
        let assembler = DocumentAssembler(title: documentTitle(document))
        for entry in nodeDicts {
            guard let nodeDict = entry as? [String: Any] else { continue }
            assembler.addRoot(parseNode(nodeDict))
        }
        for connection in firstArray(document, keys: ["crossConnections", "connections"]) ?? [] {
            guard let connectionDict = connection as? [String: Any] else { continue }
            guard
                let start = stringify(
                    connectionDict["startNodeID"] ?? connectionDict["fromNodeID"]
                        ?? connectionDict["sourceNodeID"]),
                let end = stringify(
                    connectionDict["endNodeID"] ?? connectionDict["toNodeID"]
                        ?? connectionDict["targetNodeID"]),
                let from = assembler.arborID(forExternal: start),
                let to = assembler.arborID(forExternal: end)
            else { continue }
            assembler.addConnection(
                from: from, to: to,
                label: firstString(connectionDict, keys: ["title", "label"]))
        }
        return assembler.result
    }

    private static func documentTitle(_ document: [String: Any]) -> String? {
        firstString(document, keys: ["documentTitle", "mindmapTitle", "title"])
    }

    /// One MindNode node dictionary: several spellings per field, so the
    /// importer survives small layout drift across MindNode releases.
    private static func parseNode(_ dict: [String: Any]) -> DocumentBox {
        let box = DocumentBox(
            title: NodeTitle(text: firstString(dict, keys: ["nodeTitle", "title", "text"]) ?? ""))
        box.externalID = stringify(dict["uuid"] ?? dict["ID"] ?? dict["id"])
        box.note = firstString(dict, keys: ["nodeNote", "note", "notes"])
        box.structure = firstString(dict, keys: ["structureID", "layoutID", "structure"])
        box.folded = firstBool(dict, keys: ["isFolded", "folded"]) ?? false
        if let tagList = dict["tags"] as? [Any] {
            box.tagNames = tagList.compactMap { entry in
                if let name = entry as? String { return name }
                guard let tagDict = entry as? [String: Any] else { return nil }
                return firstString(tagDict, keys: ["name", "title"])
            }
        }
        if let taskDict = firstDictionary(dict, keys: ["nodeTask", "task"]) {
            var task = NodeTask(done: firstBool(taskDict, keys: ["isDone", "done", "completed"]) ?? false)
            task.due = firstString(taskDict, keys: ["dueDate", "due"])
            box.task = task
        }
        for child in firstArray(dict, keys: ["subnodes", "children", "childNodes"]) ?? [] {
            guard let childDict = child as? [String: Any] else { continue }
            box.children.append(parseNode(childDict))
        }
        return box
    }

    // MARK: tolerant value extraction

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringify(dict[key]), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstBool(_ dict: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let flag = dict[key] as? Bool { return flag }
            if let number = dict[key] as? NSNumber { return number.boolValue }
        }
        return nil
    }

    private static func firstDictionary(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func firstArray(_ dict: [String: Any], keys: [String]) -> [Any]? {
        for key in keys {
            if let value = dict[key] as? [Any] { return value }
        }
        return nil
    }

    /// MindNode plists store uuids as UUIDs and dates as Dates; both are
    /// stringified for id and due-date comparisons.
    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case nil:
            return nil
        case let string as String:
            return string
        case let uuid as UUID:
            return uuid.uuidString
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
