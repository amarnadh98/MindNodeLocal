import Foundation
import MapCore

/// MindNode `.mindnode` import (F-IO, SPEC §5.17): a MindNode package is
/// a directory whose `contents.xml` is a *binary property list*; the App
/// layer opens the package and hands this importer that entry's bytes.
/// `PropertyListSerialization` reads them; titles, notes, structure,
/// tasks, tags and cross connections map onto the Arbor model. The plist
/// key names are read tolerantly (several plausible spellings per field,
/// string/UUID/Date-tolerant values), because the importer is written
/// from MindNode's publicly documented structure without access to real
/// files; a document whose version is not "9" fails with a clear error
/// suggesting the documented fallback: **export OPML from MindNode** and
/// import that instead. There is no MindNode export.
///
/// Lossy fields (docs/io/format-matrix.md): node uuids, images,
/// per-node style overrides, MindNode-only layout state, tag colors,
/// task due-date precision beyond the ISO day, connection styles.
public enum MindNodeIO {
    /// The versions this importer understands (SPEC §14 mentions the v9
    /// binary-plist layout). Other versions get the OPML-fallback error.
    private static let supportedVersions: Set<String> = ["9"]

    private static let id = DocumentFormats.mindnode.id

    /// Parses the `contents.xml` bytes of a `.mindnode` package into a
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
