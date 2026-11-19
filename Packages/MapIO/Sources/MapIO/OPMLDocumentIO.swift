import Foundation
import MapCore

/// Attribute names of the Arbor OPML extension: `text` and `_note` are
/// standard OPML 2.0; the `arbor:`-prefixed ones are ours.
private enum Attribute {
    static let text = "text"
    static let note = "_note"
    static let taskDone = "arbor:task-done"
    static let taskDue = "arbor:task-due"
    static let taskPriority = "arbor:task-priority"
    static let tags = "arbor:tags"
    static let structure = "arbor:structure"
    static let folded = "arbor:folded"
}

/// OPML 2.0 whole-document exchange (F-IO, SPEC §5.17): the `<body>`
/// outline forest becomes Arbor roots, `_note` carries notes, and custom
/// `arbor:`-namespaced attributes round-trip task state, tags, structure
/// and folded, so Arbor → OPML → Arbor is lossless for those fields.
///
/// Lossy fields (docs/io/format-matrix.md): inline title runs (titles
/// export flat), task `repeat`/`reminderID`, tag colors, connections,
/// boundaries, summaries, images, attachments, style overrides, offsets,
/// study state, and everything else `map.json` carries that the OPML
/// attribute set does not name.
public enum OPMLDocumentIO {
    /// Parses an OPML 2.0 document into a validated `MapModel`. Throws
    /// `DocumentIOError` — malformed XML, a root element other than
    /// `<opml>`, or a `<body>` with no outlines.
    public static func importDocument(_ text: String) throws -> MapModel {
        guard let data = text.data(using: .utf8) else {
            throw DocumentIOError.malformed(format: id, reason: "the input is not valid UTF-8")
        }
        let parser = XMLParser(data: data)
        let delegate = OPMLDocumentParser()
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil else {
            throw DocumentIOError.malformed(
                format: id, reason: parser.parserError?.localizedDescription ?? "invalid XML")
        }
        guard delegate.sawOpmlRoot else {
            throw DocumentIOError.malformed(
                format: id, reason: "the root element is not <opml>")
        }
        guard !delegate.roots.isEmpty else {
            throw DocumentIOError.emptyDocument(format: id)
        }
        let assembler = DocumentAssembler(title: delegate.headTitle)
        for root in delegate.roots {
            assembler.addRoot(root)
        }
        return assembler.result
    }

    /// Renders the whole document (all roots) as an OPML 2.0 document.
    /// Deterministic: no timestamps, attributes in a fixed order.
    public static func exportDocument(_ model: MapModel) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(OPMLDocument.escape(headTitle(of: model)))</title>",
            "  </head>",
            "  <body>",
        ]
        for rootID in model.roots {
            renderOutline(rootID, in: model, depth: 2, into: &lines)
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n")
    }

    private static let id = DocumentFormats.opml.id

    private static func headTitle(of model: MapModel) -> String {
        if let title = model.title, !title.isEmpty { return title }
        let first = model.roots.compactMap { model.nodes[$0]?.title.text }.first
        return first ?? "Arbor"
    }

    private static func renderOutline(
        _ nodeID: String, in model: MapModel, depth: Int, into lines: inout [String]
    ) {
        guard let node = model.nodes[nodeID] else { return }
        let indent = String(repeating: "  ", count: depth)
        var attributes = #"text="\#(OPMLDocument.escape(MarkdownInline.flatTitle(node.title)))""#
        if let note = node.note, !note.isEmpty {
            attributes += " _note=\"\(OPMLDocument.escape(note))\""
        }
        if let task = node.task {
            attributes += " \(Attribute.taskDone)=\"\(task.done)\""
            if let due = task.due {
                attributes += " \(Attribute.taskDue)=\"\(OPMLDocument.escape(due))\""
            }
            if let priority = task.priority {
                attributes += " \(Attribute.taskPriority)=\"\(priority)\""
            }
        }
        if let tags = node.tags, !tags.isEmpty {
            let names = tags.compactMap { tagID in model.tags?.first { $0.id == tagID }?.name }
            if !names.isEmpty {
                attributes += " \(Attribute.tags)=\"\(OPMLDocument.escape(names.joined(separator: ",")))\""
            }
        }
        if let structure = node.structure, !structure.isEmpty {
            attributes += " \(Attribute.structure)=\"\(OPMLDocument.escape(structure))\""
        }
        if node.folded {
            attributes += " \(Attribute.folded)=\"true\""
        }
        if node.children.isEmpty {
            lines.append("\(indent)<outline \(attributes)/>")
            return
        }
        lines.append("\(indent)<outline \(attributes)>")
        for childID in node.children {
            renderOutline(childID, in: model, depth: depth + 1, into: &lines)
        }
        lines.append("\(indent)</outline>")
    }
}

/// Collects an OPML document: the `<head><title>`, and the `<body>`
/// outline tree as `DocumentBox`es with the `arbor:` attributes applied.
/// Attribute matching on the qualified name is case-insensitive, so
/// producers that capitalize differently still parse; unknown attributes
/// are ignored (they may belong to another producer's extension).
private final class OPMLDocumentParser: NSObject, XMLParserDelegate {
    var roots: [DocumentBox] = []
    var headTitle: String?
    private(set) var sawOpmlRoot = false

    private var sawRootElement = false
    private var stack: [DocumentBox] = []
    private var inHead = false
    private var inTitleElement = false
    private var titleText: String = ""

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
            sawOpmlRoot = name == "opml"
            return
        }
        if name == "head" {
            inHead = true
        } else if name == "title", inHead {
            inTitleElement = true
            titleText = ""
        } else if name == "outline" {
            let box = outlineBox(attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(box)
            } else {
                roots.append(box)
            }
            stack.append(box)
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        if inTitleElement {
            titleText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        if name == "outline", !stack.isEmpty {
            stack.removeLast()
        } else if name == "title", inTitleElement {
            headTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            inTitleElement = false
        } else if name == "head" {
            inHead = false
        }
    }

    private func outlineBox(attributes: [String: String]) -> DocumentBox {
        let box = DocumentBox(
            title: NodeTitle(text: exact(Attribute.text, in: attributes) ?? ""))
        if let note = exact(Attribute.note, in: attributes), !note.isEmpty {
            box.note = note
        }
        if let done = exact(Attribute.taskDone, in: attributes), isTrue(done) {
            box.task = task(afterDone: true, attributes: attributes)
        } else if exact(Attribute.taskDue, in: attributes) != nil
            || exact(Attribute.taskPriority, in: attributes) != nil
        {
            box.task = task(afterDone: false, attributes: attributes)
        }
        if let tags = exact(Attribute.tags, in: attributes) {
            box.tagNames =
                tags
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        box.structure = exact(Attribute.structure, in: attributes)
        box.folded = exact(Attribute.folded, in: attributes).map(isTrue) ?? false
        return box
    }

    private func task(afterDone done: Bool, attributes: [String: String]) -> NodeTask {
        var task = NodeTask(done: done)
        task.due = exact(Attribute.taskDue, in: attributes)
        task.priority = exact(Attribute.taskPriority, in: attributes).flatMap(Int.init)
        return task
    }

    /// Exact (case-insensitive) attribute lookup.
    private func exact(_ name: String, in attributes: [String: String]) -> String? {
        let lowered = name.lowercased()
        for (key, value) in attributes where key.lowercased() == lowered {
            return value
        }
        return nil
    }

    private func isTrue(_ value: String) -> Bool {
        ["true", "yes", "1"].contains(value.lowercased())
    }
}
