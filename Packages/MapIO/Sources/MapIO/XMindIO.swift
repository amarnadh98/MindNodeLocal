import Foundation
import MapCore

/// XMind `.xmind` import (F-IO, SPEC §5.17): the archive's `content.json`
/// (Xmind 2020+) or `content.xml` (Xmind 8) is read with the in-house
/// `MiniZip` reader (ADR-0010 — no zip dependency). Sheets become roots,
/// `attached` children become node children, sheet relationships become
/// connections, `boundaries` become Arbor boundaries over the wrapped
/// child range, and summaries map to Arbor summaries (using the file's
/// summary topic when its id resolves, else a synthesized node).
/// Detached topics of a sheet root import as extra roots; callouts are
/// skipped. There is no XMind export.
///
/// Lossy fields (docs/io/format-matrix.md): everything XMind styling
/// carries (colors, borders, shapes, number stamps), topic ids, callout
/// topics, sheet titles, floating positions; the Xmind 8 XML path maps
/// topics, notes, labels, task markers and relationships only — its
/// boundaries and summaries are dropped (documented).
public enum XMindIO {
    /// Reads a `.xmind` archive (the raw zip bytes) into a validated
    /// `MapModel`. Throws `DocumentIOError` — not a zip, no content entry,
    /// or unparseable content.
    public static func importDocument(archive: Data) throws -> MapModel {
        let entries: [MiniZip.Entry]
        do {
            entries = try MiniZip.entries(of: archive)
        } catch {
            throw DocumentIOError.malformed(
                format: id, reason: "the file is not a readable zip archive")
        }
        if let json = entries.first(where: { $0.name == "content.json" }) {
            return try importJSON(json.data)
        }
        if let xml = entries.first(where: { $0.name == "content.xml" }) {
            return try importXML(xml.data)
        }
        throw DocumentIOError.malformed(
            format: id, reason: "the archive has no content.json or content.xml entry")
    }

    private static let id = DocumentFormats.xmind.id

    // MARK: content.json (Xmind 2020+)

    private static func importJSON(_ data: Data) throws -> MapModel {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DocumentIOError.malformed(format: id, reason: "content.json is not valid JSON")
        }
        guard let sheets = json as? [[String: Any]] else {
            throw DocumentIOError.malformed(
                format: id, reason: "content.json is not an array of sheets")
        }
        guard !sheets.isEmpty else {
            throw DocumentIOError.emptyDocument(format: id)
        }
        let assembler = DocumentAssembler(title: nil)
        let ranges = RangeContext()
        var relationships: [[String: Any]] = []
        var parsedRoots = 0
        for sheet in sheets {
            if let sheetLinks = sheet["relationships"] as? [[String: Any]] {
                relationships.append(contentsOf: sheetLinks)
            }
            guard let rootTopic = sheet["rootTopic"] as? [String: Any] else { continue }
            assembler.addRoot(parseTopic(rootTopic, into: ranges))
            // Detached topics float around the sheet root; Arbor has no
            // floating nodes, so they land as their own roots.
            for detached in childTopics(rootTopic, kind: "detached") {
                assembler.addRoot(parseTopic(detached, into: ranges))
            }
            parsedRoots += 1
        }
        guard parsedRoots > 0 else {
            throw DocumentIOError.emptyDocument(format: id)
        }
        for relationship in relationships {
            guard
                let end1 = relationship["end1Id"] as? String,
                let end2 = relationship["end2Id"] as? String,
                let from = assembler.arborID(forExternal: end1),
                let to = assembler.arborID(forExternal: end2)
            else { continue }
            assembler.addConnection(from: from, to: to, label: relationship["title"] as? String)
        }
        ranges.apply(to: assembler)
        return assembler.result
    }

    /// Parses one JSON topic into a `DocumentBox`, recursing into
    /// attached children and recording ranges for the post-assembly
    /// boundary/summary pass.
    private static func parseTopic(_ topic: [String: Any], into ranges: RangeContext) -> DocumentBox {
        let box = DocumentBox(title: NodeTitle(text: (topic["title"] as? String) ?? ""))
        box.externalID = topic["id"] as? String
        box.note = note(from: topic)
        box.structure = mappedStructure(fromClass: topic["structureClass"] as? String)
        if let labels = topic["labels"] as? [String] {
            box.tagNames = labels
        }
        box.task = task(fromMarkers: topic["markers"] as? [[String: Any]])
        if let boundaries = topic["boundaries"] as? [[String: Any]] {
            ranges.boundaries.append(RangeEntry(parentExternalID: box.externalID, dicts: boundaries))
        }
        if let summaries = topic["summaries"] as? [[String: Any]] {
            ranges.summaries.append(RangeEntry(parentExternalID: box.externalID, dicts: summaries))
        }
        box.children = childTopics(topic, kind: "attached").map { parseTopic($0, into: ranges) }
        return box
    }

    private static func childTopics(_ topic: [String: Any], kind: String) -> [[String: Any]] {
        guard let children = topic["children"] as? [String: Any] else { return [] }
        return (children[kind] as? [[String: Any]]) ?? []
    }

    /// `notes: { plain: { content } }`.
    private static func note(from topic: [String: Any]) -> String? {
        guard let notes = topic["notes"] as? [String: Any],
            let plain = notes["plain"] as? [String: Any],
            let content = plain["content"] as? String, !content.isEmpty
        else { return nil }
        return content
    }

    /// Xmind task markers: a `task-done*` marker marks a done task, any
    /// other `task-*` marker an open one.
    private static func task(fromMarkers markers: [[String: Any]]?) -> NodeTask? {
        guard let markers, !markers.isEmpty else { return nil }
        for marker in markers {
            let markerID = (marker["markerId"] as? String) ?? (marker["id"] as? String) ?? ""
            if markerID.hasPrefix("task") {
                return NodeTask(done: markerID.contains("task-done"))
            }
        }
        return nil
    }

    /// Xmind structure classes onto Arbor's §8.2 structure strings.
    static func mappedStructure(fromClass structureClass: String?) -> String? {
        guard let structureClass else { return nil }
        if structureClass.contains("logic.right") { return "mindmap.right" }
        if structureClass.contains("logic.left") { return "mindmap.left" }
        if structureClass.contains("org-chart.down") { return "orgchart.down" }
        if structureClass.contains("org-chart.up") { return "orgchart.up" }
        if structureClass.contains("map") { return "mindmap.balanced" }
        return nil
    }

    // MARK: content.xml (Xmind 8)

    private static func importXML(_ data: Data) throws -> MapModel {
        let parser = XMLParser(data: data)
        let delegate = XMind8Parser()
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil else {
            throw DocumentIOError.malformed(
                format: id, reason: parser.parserError?.localizedDescription ?? "invalid XML")
        }
        guard !delegate.roots.isEmpty else {
            throw DocumentIOError.emptyDocument(format: id)
        }
        let assembler = DocumentAssembler(title: nil)
        for root in delegate.roots {
            assembler.addRoot(root)
        }
        for link in delegate.pendingLinks {
            guard
                let from = assembler.arborID(forExternal: link.from),
                let to = assembler.arborID(forExternal: link.to)
            else { continue }
            assembler.addConnection(from: from, to: to, label: link.label)
        }
        return assembler.result
    }
}

/// A topic's `boundaries` or `summaries` array with its parent's
/// format-native id, applied after assembly when the Arbor child ids
/// exist.
private struct RangeEntry {
    let parentExternalID: String?
    let dicts: [[String: Any]]
}

/// Local, per-import collection of the JSON path's boundary and summary
/// ranges. No static state: import runs on any executor.
private final class RangeContext {
    var boundaries: [RangeEntry] = []
    var summaries: [RangeEntry] = []

    /// Xmind ranges are inclusive child indices `{"begin": n, "end": m}`.
    private func childSlice(_ range: [String: Any], of children: [String]) -> [String]? {
        guard
            let begin = range["begin"] as? Int,
            let end = range["end"] as? Int,
            begin >= 0, end >= begin, end < children.count
        else { return nil }
        return Array(children[begin...end])
    }

    fileprivate func apply(to assembler: DocumentAssembler) {
        for entry in boundaries {
            applyBoundaries(entry, to: assembler)
        }
        for entry in summaries {
            applySummaries(entry, to: assembler)
        }
    }

    private func applyBoundaries(_ entry: RangeEntry, to assembler: DocumentAssembler) {
        guard let parentExternalID = entry.parentExternalID else { return }
        let children = assembler.arborChildren(ofExternal: parentExternalID)
        for boundary in entry.dicts {
            guard let range = boundary["range"] as? [String: Any],
                let nodes = childSlice(range, of: children)
            else { continue }
            assembler.addBoundary(nodes: nodes, title: boundary["title"] as? String)
        }
    }

    private func applySummaries(_ entry: RangeEntry, to assembler: DocumentAssembler) {
        guard
            let parentExternalID = entry.parentExternalID,
            let parentID = assembler.arborID(forExternal: parentExternalID)
        else { return }
        let children = assembler.arborChildren(ofExternal: parentExternalID)
        for summary in entry.dicts {
            guard
                let range = summary["range"] as? [String: Any],
                let nodes = childSlice(range, of: children),
                let firstNode = nodes.first,
                let lastNode = nodes.last
            else { continue }
            // The summary topic: XMind names it via `topicId` when it
            // exists as a real topic; otherwise Arbor synthesizes one.
            let nodeID: String
            if let topicID = summary["topicId"] as? String,
                let resolved = assembler.arborID(forExternal: topicID)
            {
                nodeID = resolved
            } else {
                nodeID = assembler.addSummaryNode(
                    parent: parentID, title: (summary["title"] as? String) ?? "Summary")
            }
            assembler.addSummary(parent: parentID, range: [firstNode, lastNode], node: nodeID)
        }
    }
}

/// Collects an Xmind 8 `content.xml`: `<sheet>` topics (the first topic
/// of a sheet is its root), titles, notes, labels, task markers and
/// sheet-level `<relationship>` elements.
private final class XMind8Parser: NSObject, XMLParserDelegate {
    var roots: [DocumentBox] = []
    var pendingLinks: [PendingXMindLink] = []

    private var stack: [DocumentBox] = []
    private var titleTarget: DocumentBox?
    private var titleText = ""
    private var noteTarget: DocumentBox?
    private var noteText = ""
    private var pendingRelationship: PendingXMindLink?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "topic":
            let box = DocumentBox(title: NodeTitle(text: ""))
            box.externalID = attributeDict["id"]
            box.structure = XMindIO.mappedStructure(
                fromClass: attributeDict["structure-class"] ?? attributeDict["structure-id"])
            if let parent = stack.last {
                parent.children.append(box)
            } else {
                roots.append(box)
            }
            stack.append(box)
        case "title":
            if pendingRelationship != nil {
                titleText = ""
            } else {
                titleTarget = stack.last
                titleText = ""
            }
        case "notes":
            noteTarget = stack.last
            noteText = ""
        case "label":
            if let name = attributeDict["name"], !name.isEmpty {
                stack.last?.tagNames.append(name)
            }
        case "marker-ref":
            if let task = markerTask(attributeDict["marker-id"]) {
                stack.last?.task = stack.last?.task ?? task
            }
        case "relationship":
            pendingRelationship = PendingXMindLink(
                from: attributeDict["end1"] ?? "", to: attributeDict["end2"] ?? "", label: nil)
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        if titleTarget != nil || pendingRelationship != nil {
            titleText += string
        }
        if noteTarget != nil {
            noteText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName.lowercased() {
        case "title":
            let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if var relationship = pendingRelationship {
                relationship.label = trimmed.isEmpty ? nil : trimmed
                pendingRelationship = relationship
            } else if let target = titleTarget {
                target.title = NodeTitle(text: trimmed)
                titleTarget = nil
            }
        case "notes":
            if let target = noteTarget {
                let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                target.note = trimmed.isEmpty ? nil : trimmed
                noteTarget = nil
            }
        case "topic":
            if !stack.isEmpty {
                stack.removeLast()
            }
        case "relationship":
            if let relationship = pendingRelationship {
                pendingLinks.append(relationship)
                pendingRelationship = nil
            }
        default:
            break
        }
    }

    /// Same marker rule as the JSON path: `task-done*` is done.
    private func markerTask(_ markerID: String?) -> NodeTask? {
        guard let markerID, markerID.hasPrefix("task") else { return nil }
        return NodeTask(done: markerID.contains("task-done"))
    }
}

private struct PendingXMindLink {
    var from: String
    var to: String
    var label: String?
}
