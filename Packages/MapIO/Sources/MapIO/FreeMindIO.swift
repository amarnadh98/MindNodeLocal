import Foundation
import MapCore

/// FreeMind / Freeplane `.mm` whole-document exchange (F-IO, SPEC
/// §5.17): the `<node>` tree becomes Arbor roots/children, `FOLDED`,
/// `POSITION` (level-1 side pins) and `LINK` map directly, notes are
/// read from `<richcontent TYPE="NOTE">` (HTML is flattened to plain
/// text paragraphs), `<arrowlink DEST>` becomes a connection, and the
/// `button_ok` icon marks a done task. Structure, tags and task extras
/// ride on Freeplane `<attribute>`s (`arbor-structure`, `arbor-tags`,
/// `arbor-task-due`, `arbor-task-priority`), so Arbor → .mm → Arbor
/// round-trips them.
///
/// Lossy fields (docs/io/format-matrix.md): inline title runs (titles
/// export flat `TEXT`), connection labels (arrowlinks carry none),
/// rich HTML beyond plain paragraphs in imported notes, FreeMind icons
/// and edge/folder styling, plus the usual format gaps (images,
/// attachments, style overrides, study state).
public enum FreeMindIO {
    /// Parses a `.mm` document into a validated `MapModel`. Throws
    /// `DocumentIOError` — invalid XML, a root element other than
    /// `<map>`, or no `<node>` elements.
    public static func importDocument(_ text: String) throws -> MapModel {
        guard let data = text.data(using: .utf8) else {
            throw DocumentIOError.malformed(format: id, reason: "the input is not valid UTF-8")
        }
        let parser = XMLParser(data: data)
        let delegate = FreeMindParser()
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil else {
            throw DocumentIOError.malformed(
                format: id, reason: parser.parserError?.localizedDescription ?? "invalid XML")
        }
        guard delegate.sawMapRoot else {
            throw DocumentIOError.malformed(
                format: id, reason: "the root element is not <map>")
        }
        guard !delegate.roots.isEmpty else {
            throw DocumentIOError.emptyDocument(format: id)
        }
        let assembler = DocumentAssembler(title: nil)
        for root in delegate.roots {
            assembler.addRoot(root)
        }
        for link in delegate.pendingLinks {
            assembler.addConnection(
                from: assembler.arborID(forExternal: link.from) ?? "",
                to: assembler.arborID(forExternal: link.to) ?? "",
                label: link.label)
        }
        return assembler.result
    }

    /// Renders the whole document as FreeMind 1.0.1 XML. Deterministic:
    /// node ids are `ID_` + the Arbor id, no timestamps.
    public static func exportDocument(_ model: MapModel) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<map version="1.0.1">"#,
        ]
        for rootID in model.roots {
            renderNode(rootID, in: model, depth: 1, isLevelOne: false, into: &lines)
        }
        lines.append("</map>")
        return lines.joined(separator: "\n")
    }

    private static let id = DocumentFormats.freemind.id

    private static func renderNode(
        _ nodeID: String, in model: MapModel, depth: Int, isLevelOne: Bool,
        into lines: inout [String]
    ) {
        guard let node = model.nodes[nodeID] else { return }
        let indent = String(repeating: "  ", count: depth)
        var attributes = #"ID="ID_\#(nodeID)""#
        attributes += #" TEXT="\#(OPMLDocument.escape(MarkdownInline.flatTitle(node.title)))""#
        if node.folded {
            attributes += " FOLDED=\"true\""
        }
        if isLevelOne, let side = node.side {
            attributes += " POSITION=\"\(side.rawValue)\""
        }
        if let link = node.link {
            attributes += #" LINK="\#(OPMLDocument.escape(link))""#
        }
        lines.append("\(indent)<node \(attributes)>")
        if let task = node.task {
            if task.done {
                lines.append("\(indent)  <icon BUILTIN=\"button_ok\"/>")
            }
            if let due = task.due {
                lines.append("\(indent)  <attribute NAME=\"arbor-task-due\" VALUE=\"\(OPMLDocument.escape(due))\"/>")
            }
            if let priority = task.priority {
                lines.append("\(indent)  <attribute NAME=\"arbor-task-priority\" VALUE=\"\(priority)\"/>")
            }
        }
        if let structure = node.structure, !structure.isEmpty {
            lines.append(
                "\(indent)  <attribute NAME=\"arbor-structure\" VALUE=\"\(OPMLDocument.escape(structure))\"/>")
        }
        if let tags = node.tags, !tags.isEmpty {
            let names = tags.compactMap { tagID in model.tags?.first { $0.id == tagID }?.name }
            if !names.isEmpty {
                lines.append(
                    "\(indent)  <attribute NAME=\"arbor-tags\" VALUE=\"\(OPMLDocument.escape(names.joined(separator: ",")))\"/>"
                )
            }
        }
        if let note = node.note, !note.isEmpty {
            appendNote(note, indent: indent + "  ", into: &lines)
        }
        for connection in model.connections ?? [] where connection.from == nodeID {
            if let toID = model.nodes[connection.to] {
                lines.append("\(indent)  <arrowlink DEST=\"ID_\(toID.id)\"/>")
            }
        }
        for childID in node.children {
            renderNode(childID, in: model, depth: depth + 1, isLevelOne: depth == 1, into: &lines)
        }
        lines.append("\(indent)</node>")
    }

    /// A note as one `<richcontent TYPE="NOTE">` block, one `<p>` per
    /// note line, XML-escaped.
    private static func appendNote(_ note: String, indent: String, into lines: inout [String]) {
        lines.append(#"\#(indent)<richcontent TYPE="NOTE">"#)
        lines.append("\(indent)<html>")
        lines.append("\(indent)  <head/>")
        lines.append("\(indent)  <body>")
        for noteLine in note.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = noteLine.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append("\(indent)    <p>\(OPMLDocument.escape(trimmed))</p>")
            }
        }
        lines.append("\(indent)  </body>")
        lines.append("\(indent)</html>")
        lines.append("\(indent)</richcontent>")
    }
}

/// One `<arrowlink>` seen on a node that has not been assembled yet:
/// both endpoints are FreeMind node ids, resolved after the tree build.
private struct PendingArrowLink {
    let from: String
    let to: String
    let label: String?
}

/// Collects a FreeMind `<map>`: the `<node>` tree, note/`NODE`
/// `richcontent` blocks, `<attribute>`s, icons and arrowlinks.
private final class FreeMindParser: NSObject, XMLParserDelegate {
    var roots: [DocumentBox] = []
    var pendingLinks: [PendingArrowLink] = []
    private(set) var sawMapRoot = false

    private var sawRootElement = false
    private var stack: [DocumentBox] = []
    private var collector: RichCollector?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if !sawRootElement {
            sawRootElement = true
            sawMapRoot = name == "map"
            return
        }
        if let active = collector {
            active.openElement(name)
            return
        }
        switch name {
        case "node":
            let box = DocumentBox(title: NodeTitle(text: attributeDict["TEXT"] ?? ""))
            box.externalID = attributeDict["ID"]
            box.folded = attributeDict["FOLDED"]?.lowercased() == "true"
            if let position = attributeDict["POSITION"]?.lowercased() {
                box.side = position == "left" ? .left : (position == "right" ? .right : nil)
            }
            box.link = attributeDict["LINK"]
            if let parent = stack.last {
                parent.children.append(box)
            } else {
                roots.append(box)
            }
            stack.append(box)
        case "richcontent":
            let type = (attributeDict["TYPE"] ?? "").uppercased()
            collector = RichCollector(type: type == "NOTE" ? .note : (type == "NODE" ? .nodeTitle : .ignored))
        case "attribute":
            apply(attributeDict["NAME"], value: attributeDict["VALUE"])
        case "icon":
            if attributeDict["BUILTIN"] == "button_ok" {
                stack.last?.task =
                    stack.last?.task.map { taskDone($0, done: true) }
                    ?? NodeTask(done: true)
            }
        case "arrowlink":
            guard let currentID = stack.last?.externalID, let dest = attributeDict["DEST"] else {
                return
            }
            pendingLinks.append(PendingArrowLink(from: currentID, to: dest, label: attributeDict["label"]))
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        collector?.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if let active = collector {
            active.closeElement(name)
            if name == "richcontent" {
                finish(active)
                collector = nil
            }
            return
        }
        if name == "node", !stack.isEmpty {
            stack.removeLast()
        }
    }

    private func finish(_ active: RichCollector) {
        guard let text = active.collectedText(), let box = stack.last else { return }
        switch active.type {
        case .note:
            box.note = text
        case .nodeTitle:
            if box.title.text.isEmpty {
                box.title = NodeTitle(text: text)
            }
        case .ignored:
            break
        }
    }

    private func apply(_ name: String?, value: String?) {
        guard let name, let value, let box = stack.last else { return }
        switch name {
        case "arbor-structure":
            box.structure = value
        case "arbor-tags":
            box.tagNames =
                value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case "arbor-task-done":
            if value.lowercased() == "true" {
                box.task = taskDone(box.task ?? NodeTask(done: false), done: true)
            }
        case "arbor-task-due":
            box.task = taskDone(box.task ?? NodeTask(done: false), due: value)
        case "arbor-task-priority":
            box.task = taskDone(box.task ?? NodeTask(done: false), priority: Int(value))
        default:
            break
        }
    }

    private func taskDone(
        _ task: NodeTask, done: Bool? = nil, due: String? = nil, priority: Int? = nil
    ) -> NodeTask {
        var updated = task
        if let done { updated.done = done }
        if let due { updated.due = due }
        if let priority { updated.priority = priority }
        return updated
    }
}

/// Flattens the HTML inside a FreeMind `richcontent` block: text after
/// `<body>` is collected, `<p>`/`<br>`/`<li>` and friends mark line
/// breaks, `<head>` content is skipped, entities are decoded by
/// `XMLParser` itself.
private final class RichCollector {
    enum Kind {
        case note
        case nodeTitle
        case ignored
    }

    let type: Kind
    private var inBody = false
    private var chunks: [String] = []

    init(type: Kind) {
        self.type = type
    }

    func openElement(_ name: String) {
        if name == "body" {
            inBody = true
        } else if inBody, Self.lineBreakElements.contains(name) {
            chunks.append("\n")
        }
    }

    func append(_ string: String) {
        guard inBody, type != .ignored else { return }
        chunks.append(string)
    }

    func closeElement(_ name: String) {
        // Line breaks were already inserted on open; nothing to do.
    }

    /// The collected text as trimmed, non-empty lines joined with "\n".
    func collectedText() -> String? {
        let lines = chunks.joined()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static let lineBreakElements: Set<String> = [
        "p", "br", "li", "div", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
    ]
}
